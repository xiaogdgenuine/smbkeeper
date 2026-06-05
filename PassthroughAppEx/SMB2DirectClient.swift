/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Direct libsmb2 client for the passthrough FSKit volume (no AMSMB2 wrapper).
*/

import Foundation
import SMB2
import OSLog

/// Thread-safe SMB2 client using libsmb2 synchronous APIs on a private serial queue.
final class SMB2DirectClient: @unchecked Sendable {

    private var context: UnsafeMutablePointer<smb2_context>?
    private let queue = DispatchQueue(label: "com.apple.fskit.passthroughfs.libsmb2.queue")
    private let connectionLock = NSLock()
    private var isConnected = false

    init() throws {
        try self.queue.sync {
            try self.connectOnQueue()
        }
        self.isConnected = true
        Logger.passthroughfs.info("libsmb2 connected to \(SMBConfiguration.shareName) at \(SMBConfiguration.serverURL)")
    }

    func disconnect() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard isConnected else { return }
        queue.sync {
            guard let ctx = self.context else { return }
            smb2_disconnect_share(ctx)
            smb2_destroy_context(ctx)
            self.context = nil
        }
        isConnected = false
    }

    @discardableResult
    func reconnect() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        do {
            try queue.sync {
                if let ctx = self.context {
                    smb2_disconnect_share(ctx)
                    smb2_destroy_context(ctx)
                    self.context = nil
                }
                try self.connectOnQueue()
            }
            isConnected = true
            return true
        } catch {
            Logger.passthroughfs.error("libsmb2 reconnect failed: \(error)")
            isConnected = false
            return false
        }
    }

    func isConnectionLost(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOTCONN, .ETIMEDOUT, .ESTALE, .ECONNRESET, .ECONNABORTED,
                 .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTDOWN, .EHOSTUNREACH,
                 .EPIPE, .ESHUTDOWN, .EIO, .EBADF:
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: - Metadata

    func attributesOfItem(atPath path: String) throws -> [URLResourceKey: any Sendable] {
        try perform { ctx in
            var st = smb2_stat_64()
            let trimmed = path.smbTrimmedPath
            let result = trimmed.withCString { cPath in
                smb2_stat(ctx, cPath, &st)
            }
            if result < 0, st.resourceType == .link || result == -Int32(POSIXErrorCode.ENOLINK.rawValue) {
                return try self.statViaSymlinkOpen(ctx, path: trimmed)
            }
            try SMB2LibSupport.check(result, context: ctx)
            let name = (path as NSString).lastPathComponent
            return st.resourceDictionary(path: parentPath(of: trimmed), name: name.isEmpty ? trimmed : name)
        }
    }

    func attributesOfFileSystem(forPath path: String = "") throws -> [FileAttributeKey: any Sendable] {
        try perform { ctx in
            var st = smb2_statvfs()
            let trimmed = path.smbTrimmedPath
            let result = trimmed.withCString { cPath in
                smb2_statvfs(ctx, cPath, &st)
            }
            try SMB2LibSupport.check(result, context: ctx)
            var attrs = [FileAttributeKey: any Sendable]()
            let blockSize = UInt64(st.f_bsize)
            attrs[.systemSize] = NSNumber(value: blockSize * UInt64(st.f_blocks))
            attrs[.systemFreeSize] = NSNumber(value: blockSize * UInt64(st.f_bavail))
            attrs[.systemNodes] = NSNumber(value: st.f_files)
            attrs[.systemFreeNodes] = NSNumber(value: st.f_ffree)
            return attrs
        }
    }

    func contentsOfDirectory(atPath path: String) throws -> [[URLResourceKey: any Sendable]] {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            guard let dir = trimmed.withCString({ smb2_opendir(ctx, $0) }) else {
                throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
            }
            defer { smb2_closedir(ctx, dir) }

            var entries = [[URLResourceKey: any Sendable]]()
            while let ent = smb2_readdir(ctx, dir) {
                let name = String(cString: ent.pointee.name)
                if name == "." || name == ".." { continue }
                let st = ent.pointee.st
                entries.append(st.resourceDictionary(path: trimmed, name: name))
            }
            return entries
        }
    }

    // MARK: - Mutations

    func setAttributes(_ attributes: [URLResourceKey: Any], atPath path: String) throws {
        // Date/flag changes via SMB2 set-info can be added later; size is handled by ``truncateFile``.
        _ = attributes
        _ = path
    }

    func truncateFile(atPath path: String, atOffset: UInt64) throws {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            let result = trimmed.withCString { smb2_truncate(ctx, $0, atOffset) }
            try SMB2LibSupport.check(result, context: ctx)
        }
    }

    func createDirectory(atPath path: String) throws {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            let result = trimmed.withCString { smb2_mkdir(ctx, $0) }
            try SMB2LibSupport.check(result, context: ctx)
        }
    }

    func createEmptyFile(atPath path: String) throws {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            guard let fh = trimmed.withCString({ smb2_open(ctx, $0, O_CREAT | O_EXCL | O_RDWR) }) else {
                throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
            }
            smb2_close(ctx, fh)
        }
    }

    func removeItem(atPath path: String) throws {
        try perform { ctx in
            var st = smb2_stat_64()
            let trimmed = path.smbTrimmedPath
            let statResult = trimmed.withCString { smb2_stat(ctx, $0, &st) }
            try SMB2LibSupport.check(statResult, context: ctx)
            let result: Int32
            if st.isDirectory {
                result = trimmed.withCString { smb2_rmdir(ctx, $0) }
            } else {
                result = trimmed.withCString { smb2_unlink(ctx, $0) }
            }
            try SMB2LibSupport.check(result, context: ctx)
        }
    }

    func moveItem(atPath path: String, toPath: String) throws {
        try perform { ctx in
            let from = path.smbTrimmedPath
            let to = toPath.smbTrimmedPath
            let result = from.withCString { fromPtr in
                to.withCString { toPtr in
                    smb2_rename(ctx, fromPtr, toPtr)
                }
            }
            try SMB2LibSupport.check(result, context: ctx)
        }
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            var buffer = [CChar](repeating: 0, count: maxSymlinkSize)
            let result = trimmed.withCString { cPath in
                smb2_readlink(ctx, cPath, &buffer, UInt32(buffer.count))
            }
            try SMB2LibSupport.check(result, context: ctx)
            return String(cString: buffer)
        }
    }

    func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
        throw POSIXError(.ENOTSUP)
    }

    // MARK: - I/O

    func read(path: String, offset: UInt64, length: Int) throws -> Data {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            guard let fh = trimmed.withCString({ smb2_open(ctx, $0, O_RDONLY) }) else {
                throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
            }
            defer { smb2_close(ctx, fh) }

            var data = Data(count: length)
            let readCount = data.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return smb2_pread(ctx, fh, base.assumingMemoryBound(to: UInt8.self), UInt32(length), offset)
            }
            try SMB2LibSupport.check(readCount, context: ctx)
            return data.prefix(Int(readCount))
        }
    }

    func write(path: String, data: Data, offset: UInt64) throws -> Int {
        try perform { ctx in
            let trimmed = path.smbTrimmedPath
            let flags = offset == 0 ? (O_RDWR | O_CREAT) : O_RDWR
            guard let fh = trimmed.withCString({ smb2_open(ctx, $0, flags) }) else {
                throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
            }
            defer { smb2_close(ctx, fh) }

            let writeCount = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return smb2_pwrite(ctx, fh, base.assumingMemoryBound(to: UInt8.self), UInt32(data.count), offset)
            }
            try SMB2LibSupport.check(writeCount, context: ctx)
            return Int(writeCount)
        }
    }

    // MARK: - Private

    private func connectOnQueue() throws {
        guard let ctx = smb2_init_context() else {
            throw POSIXError(.ENOMEM)
        }
        if SMBConfiguration.operationTimeout > 0 {
            smb2_set_timeout(ctx, Int32(SMBConfiguration.operationTimeout))
        }
        smb2_set_security_mode(ctx, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
        smb2_set_authentication(ctx, Int32(SMB2_SEC_NTLMSSP.rawValue))

        let user = SMBConfiguration.username
        user.withCString { smb2_set_user(ctx, $0) }
        if SMBConfiguration.password.isEmpty {
            smb2_set_password(ctx, nil)
        } else {
            SMBConfiguration.password.withCString { smb2_set_password(ctx, $0) }
        }

        let server = SMB2LibSupport.serverAddress(from: SMBConfiguration.serverURL)
        let share = SMBConfiguration.shareName
        let result = server.withCString { serverPtr in
            share.withCString { sharePtr in
                user.withCString { userPtr in
                    smb2_connect_share(ctx, serverPtr, sharePtr, userPtr)
                }
            }
        }
        if result < 0 {
            smb2_destroy_context(ctx)
            throw SMB2LibSupport.posixError(fromContext: ctx, code: result)
        }
        self.context = ctx
    }

    private func perform<T>(_ work: (UnsafeMutablePointer<smb2_context>) throws -> T) throws -> T {
        try queue.sync {
            let ctx = try SMB2LibSupport.requireContext(self.context)
            return try work(ctx)
        }
    }

    private func statViaSymlinkOpen(_ ctx: UnsafeMutablePointer<smb2_context>, path: String) throws
        -> [URLResourceKey: any Sendable] {
        guard let fh = path.withCString({ smb2_open(ctx, $0, O_RDONLY) }) else {
            throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
        }
        defer { smb2_close(ctx, fh) }
        var st = smb2_stat_64()
        let result = smb2_fstat(ctx, fh, &st)
        try SMB2LibSupport.check(result, context: ctx)
        let name = (path as NSString).lastPathComponent
        return st.resourceDictionary(path: parentPath(of: path), name: name)
    }

    private func parentPath(of path: String) -> String {
        let trimmed = path.smbTrimmedPath
        guard let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return ""
        }
        return String(trimmed[..<slash])
    }
}
