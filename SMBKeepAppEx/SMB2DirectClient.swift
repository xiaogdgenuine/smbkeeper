/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Direct libsmb2 client for the passthrough FSKit volume (no AMSMB2 wrapper).
*/

import Foundation
import Network
import SMB2
import OSLog

/// Thread-safe SMB2 client using libsmb2 synchronous APIs on a private serial queue.
final class SMB2DirectClient: @unchecked Sendable {

    private var context: UnsafeMutablePointer<smb2_context>?
    private let queue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.libsmb2.queue")
    private let connectionLock = NSLock()
    private var isConnected = false
    private let config: SMBConfiguration
    private let logger: Logger

    /// A cached open SMB file handle plus whether it was opened for writing.
    private struct CachedHandle {
        var fh: OpaquePointer
        /// True if opened `O_RDWR` (can serve both reads and writes); false if
        /// opened `O_RDONLY`.
        var writable: Bool
    }

    /// Open file handles keyed by SMB path, reused across `read`/`write` calls to
    /// avoid an open/close round trip per operation (critical for large
    /// sequential reads like video playback, and for writing large files).
    /// A single handle per path serves both reads and writes; it is upgraded to
    /// `O_RDWR` on first write. Only accessed on `queue`, so no extra locking.
    /// Bound to the current `smb2_context`; cleared whenever the context is torn
    /// down (reconnect/disconnect).
    private var handles: [String: CachedHandle] = [:]

    /// Periodic SMB2 ECHO keepalive so idle connections aren't dropped by the
    /// server/NAT before the next file operation.
    private let keepaliveQueue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.keepalive.queue")
    private let keepaliveInterval: TimeInterval = 30
    private var keepaliveTimer: DispatchSourceTimer?

    init(config: SMBConfiguration) throws {
        self.config = config
        self.logger = Logger(subsystem: "com.apple.fskit.SMBKeepFS", category: config.connectionID)
        try self.queue.sync {
            try self.connectOnQueue()
        }
        self.isConnected = true
        self.logger.info("libsmb2 connected to \(config.shareName) at \(config.serverURL)")
        self.startKeepalive()
    }

    func disconnect() {
        self.stopKeepalive()
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard isConnected else { return }
        let config = self.config
        self.logger.info("libsmb2 disconnecting from \(config.shareName)")
        queue.sync {
            guard let ctx = self.context else { return }
            // Connection is healthy here, so close cached handles gracefully to
            // flush writes and free the smb2fh structs (destroy_context does not
            // free them).
            self.closeAllHandlesOnQueue(ctx)
            smb2_disconnect_share(ctx)
            smb2_destroy_context(ctx)
            self.context = nil
        }
        isConnected = false
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveQueue.async { [weak self] in
            guard let self else { return }
            self.keepaliveTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.keepaliveQueue)
            timer.schedule(deadline: .now() + self.keepaliveInterval, repeating: self.keepaliveInterval)
            timer.setEventHandler { [weak self] in self?.sendKeepalive() }
            self.keepaliveTimer = timer
            timer.resume()
        }
    }

    private func stopKeepalive() {
        keepaliveQueue.sync {
            self.keepaliveTimer?.cancel()
            self.keepaliveTimer = nil
        }
    }

    /// Sends one ECHO on the libsmb2 serial queue; reconnects if it fails.
    /// The reconnect must run outside `queue.sync` to avoid deadlocking the serial queue.
    private func sendKeepalive() {
        let ok: Bool = queue.sync {
            guard let ctx = self.context else { return false }
            return smb2_echo(ctx) >= 0
        }
        guard !ok else { return }
        self.logger.info("libsmb2 keepalive echo failed, reconnecting proactively")
        self.reconnect()
    }

    @discardableResult
    func reconnect() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        let config = self.config
        self.logger.info("libsmb2 reconnecting to \(config.serverURL)/\(config.shareName)")
        do {
            try queue.sync {
                // Reconnect usually happens because the connection is dead;
                // closing handles would do I/O on a broken socket and could hang
                // until the operation timeout. So just drop the references — the
                // old context is destroyed and a fresh one is built below, and
                // read()/write() will lazily reopen handles on demand.
                self.closeAllHandlesOnQueue(nil)
                if let ctx = self.context {
                    smb2_disconnect_share(ctx)
                    smb2_destroy_context(ctx)
                    self.context = nil
                }
                try self.connectOnQueue()
            }
            isConnected = true
            self.logger.info("libsmb2 reconnect succeeded")
            return true
        } catch {
            self.logger.error("libsmb2 reconnect failed: \(error)")
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
        // libsmb2 reports the real cause only in the message string; the numeric
        // errno is unreliable (e.g. nil-returning opendir/open all map to EPERM).
        // So also classify connection loss by matching the libsmb2 error text.
        let message = (error as NSError).localizedDescription.lowercased()
        let markers = ["pollhup", "socket error", "connection reset", "connection refused",
                       "broken pipe", "timed out", "timeout", "not connected",
                       "disconnected", "connection closed", "session setup"]
        return markers.contains { message.contains($0) }
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
            self.closeHandleOnQueue(ctx, trimmed)
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
            self.closeHandleOnQueue(ctx, trimmed)
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
            // Old path's cached handle becomes invalid after rename; drop both
            // sides to be safe (a handle may also exist for the destination).
            self.closeHandleOnQueue(ctx, from)
            self.closeHandleOnQueue(ctx, to)
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
            // Reuse a cached handle if present; otherwise open O_RDONLY and cache.
            // The handle stays open until closeHandle / context teardown.
            let fh = try self.handleOnQueue(ctx, trimmed: trimmed,
                                            needWrite: false, createIfMissing: false)

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
            // Reuse/upgrade to a writable handle. The same handle also serves
            // subsequent reads, so reads stay coherent with what we just wrote.
            let fh = try self.handleOnQueue(ctx, trimmed: trimmed,
                                            needWrite: true, createIfMissing: offset == 0)

            let writeCount = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return smb2_pwrite(ctx, fh, base.assumingMemoryBound(to: UInt8.self), UInt32(data.count), offset)
            }
            try SMB2LibSupport.check(writeCount, context: ctx)
            return Int(writeCount)
        }
    }

    /// Flush all writable cached handles to the server (maps to FSKit's volume
    /// `synchronize`). pwrite already sends data to the server; fsync asks the
    /// server to commit it to stable storage.
    func flushAll() throws {
        try perform { ctx in
            for (_, cached) in self.handles where cached.writable {
                let rc = smb2_fsync(ctx, cached.fh)
                try SMB2LibSupport.check(rc, context: ctx)
            }
        }
    }

    /// Close the cached handle for a path, if any (closing a writable handle also
    /// flushes it server-side). Safe to call when the path has no open handle.
    /// Call on file close/reclaim, or before a mutation that should invalidate
    /// cached state (truncate/remove/move).
    func closeHandle(forPath path: String) {
        let trimmed = path.smbTrimmedPath
        queue.sync {
            self.closeHandleOnQueue(self.context, trimmed)
        }
    }

    /// Returns a cached handle for `trimmed` with the required capability,
    /// opening (or upgrading a read-only handle to read/write) as needed.
    /// Must be called on `queue` (e.g. inside `perform`).
    private func handleOnQueue(_ ctx: UnsafeMutablePointer<smb2_context>,
                               trimmed: String,
                               needWrite: Bool,
                               createIfMissing: Bool) throws -> OpaquePointer {
        if let cached = self.handles[trimmed] {
            if !needWrite || cached.writable {
                return cached.fh
            }
            // Need write but the cached handle is read-only: close and reopen RDWR.
            smb2_close(ctx, cached.fh)
            self.handles.removeValue(forKey: trimmed)
        }

        var flags = needWrite ? O_RDWR : O_RDONLY
        if needWrite && createIfMissing {
            flags |= O_CREAT
        }
        guard let fh = trimmed.withCString({ smb2_open(ctx, $0, flags) }) else {
            throw SMB2LibSupport.posixError(fromContext: ctx, code: -1)
        }
        self.handles[trimmed] = CachedHandle(fh: fh, writable: needWrite)
        return fh
    }

    /// Closes and removes a single cached handle. Must be called on `queue`.
    /// Passing a nil `ctx` just drops the reference (used when the context is
    /// already gone, to avoid I/O on a dead connection).
    private func closeHandleOnQueue(_ ctx: UnsafeMutablePointer<smb2_context>?, _ trimmed: String) {
        guard let cached = self.handles.removeValue(forKey: trimmed) else { return }
        if let ctx {
            smb2_close(ctx, cached.fh)
        }
    }

    /// Closes every cached handle. Must be called on `queue`. With a valid `ctx`
    /// it closes gracefully (flushing writes); with nil it only drops references.
    private func closeAllHandlesOnQueue(_ ctx: UnsafeMutablePointer<smb2_context>?) {
        if let ctx {
            for (_, cached) in self.handles {
                smb2_close(ctx, cached.fh)
            }
        }
        self.handles.removeAll(keepingCapacity: true)
    }

    // MARK: - Private

    private func connectOnQueue() throws {
        guard let ctx = smb2_init_context() else {
            self.logger.error("libsmb2 init_context failed")
            throw POSIXError(.ENOMEM)
        }
        let config = self.config
        self.logger.info("libsmb2 connecting to \(config.serverURL)/\(config.shareName) as \(config.username)")
        if config.operationTimeout > 0 {
            smb2_set_timeout(ctx, Int32(config.operationTimeout))
        }
        smb2_set_security_mode(ctx, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
        smb2_set_authentication(ctx, Int32(SMB2_SEC_NTLMSSP.rawValue))

        let user = config.username
        user.withCString { smb2_set_user(ctx, $0) }
        if config.password.isEmpty {
            smb2_set_password(ctx, nil)
        } else {
            config.password.withCString { smb2_set_password(ctx, $0) }
        }

        let server = SMB2LibSupport.serverAddress(from: config.serverURL)
        let share = config.shareName
        preflightNetworkPathOnQueue()
        let result = server.withCString { serverPtr in
            share.withCString { sharePtr in
                user.withCString { userPtr in
                    smb2_connect_share(ctx, serverPtr, sharePtr, userPtr)
                }
            }
        }
        if result < 0 {
            let error = SMB2LibSupport.posixError(fromContext: ctx, code: result)
            self.logger.error("libsmb2 connect failed: \(error)")
            smb2_destroy_context(ctx)
            throw error
        }
        self.logger.info("libsmb2 connected successfully")
        self.context = ctx
    }

    /// Warm up the Network.framework path inside the extension process before
    /// libsmb2 uses legacy BSD sockets. Developer ID FSKit extensions can get a
    /// different network policy attribution than the containing app, so doing
    /// this in-process gives us a useful diagnostic and avoids a cold path check.
    private func preflightNetworkPathOnQueue() {
        guard let host = config.serverURL.host,
              let port = NWEndpoint.Port(rawValue: UInt16(config.serverURL.port ?? 445)) else {
            logger.error("Network preflight skipped: invalid server URL")
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let networkQueue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.network-preflight")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var didFinish = false

        func finish() {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            lock.unlock()
            connection.cancel()
            semaphore.signal()
        }

        connection.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                logger.info("Network preflight ready for \(host, privacy: .public):\(port.rawValue, privacy: .public)")
                finish()
            case .waiting(let error):
                logger.error("Network preflight waiting for \(host, privacy: .public):\(port.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            case .failed(let error):
                logger.error("Network preflight failed for \(host, privacy: .public):\(port.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                finish()
            case .cancelled:
                finish()
            default:
                break
            }
        }

        connection.start(queue: networkQueue)
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            logger.error("Network preflight timed out for \(host, privacy: .public):\(port.rawValue, privacy: .public)")
            finish()
        }
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
