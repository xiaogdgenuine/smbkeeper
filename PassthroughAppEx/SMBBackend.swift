/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
AMSMB2-backed storage for the passthrough FSKit volume.
*/

import Foundation
import AMSMB2
import OSLog

/// Bridges synchronous FSKit callbacks to `SMB2Manager` completion-handler APIs.
final class SMBBackend: @unchecked Sendable {

    private let manager: SMB2Manager
    /// Same serial queue for all blocking waits — avoids per-call `Task` allocation.
    private let queue = DispatchQueue(label: "com.apple.fskit.passthroughfs.smb.queue")
    private let connectionLock = NSLock()
    private var isConnected = false

    init() throws {
        guard let manager = SMB2Manager(url: SMBConfiguration.serverURL, credential: SMBConfiguration.credential) else {
            throw POSIXError(.EINVAL)
        }
        self.manager = manager
        manager.timeout = SMBConfiguration.operationTimeout
        try self.connectLocked()
    }

    func disconnect() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard isConnected else { return }
        do {
            try self.wait { done in
                self.manager.disconnectShare(completionHandler: done)
            }
        } catch {
            Logger.passthroughfs.error("SMB disconnect failed: \(error)")
        }
        isConnected = false
    }

    @discardableResult
    func reconnect() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        do {
            if isConnected {
                try? self.wait { done in
                    self.manager.disconnectShare(completionHandler: done)
                }
                isConnected = false
            }
            try connectLocked()
            return true
        } catch {
            Logger.passthroughfs.error("SMB reconnect failed: \(error)")
            return false
        }
    }

    func isConnectionLost(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOTCONN, .ETIMEDOUT, .ESTALE, .ECONNRESET, .ECONNABORTED,
                 .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTDOWN, .EHOSTUNREACH,
                 .EPIPE, .ESHUTDOWN, .EIO:
                return true
            default:
                break
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return true
        }
        return false
    }

    func attributesOfItem(atPath path: String) throws -> [URLResourceKey: any Sendable] {
        try wait { done in
            self.manager.attributesOfItem(atPath: path, completionHandler: done)
        }
    }

    func attributesOfFileSystem(forPath path: String = "") throws -> [FileAttributeKey: any Sendable] {
        let result: [FileAttributeKey: Any] = try wait { done in
            self.manager.attributesOfFileSystem(forPath: path, completionHandler: done)
        }
        return result as [FileAttributeKey: any Sendable]
    }

    func contentsOfDirectory(atPath path: String) throws -> [[URLResourceKey: any Sendable]] {
        let result: [[URLResourceKey: Any]] = try wait { done in
            self.manager.contentsOfDirectory(atPath: path, recursive: false, completionHandler: done)
        }
        return result as [[URLResourceKey: any Sendable]]
    }

    func setAttributes(_ attributes: [URLResourceKey: Any], atPath path: String) throws {
        try wait { done in
            self.manager.setAttributes(attributes: attributes, ofItemAtPath: path, completionHandler: done)
        }
    }

    func truncateFile(atPath path: String, atOffset: UInt64) throws {
        try wait { done in
            self.manager.truncateFile(atPath: path, atOffset: atOffset, completionHandler: done)
        }
    }

    func createDirectory(atPath path: String) throws {
        try wait { done in
            self.manager.createDirectory(atPath: path, completionHandler: done)
        }
    }

    func createEmptyFile(atPath path: String) throws {
        try wait { done in
            self.manager.write(data: Data(), toPath: path, progress: nil, completionHandler: done)
        }
    }

    func removeItem(atPath path: String) throws {
        try wait { done in
            self.manager.removeItem(atPath: path, completionHandler: done)
        }
    }

    func moveItem(atPath path: String, toPath: String) throws {
        try wait { done in
            self.manager.moveItem(atPath: path, toPath: toPath, completionHandler: done)
        }
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try wait { done in
            self.manager.destinationOfSymbolicLink(atPath: path, completionHandler: done)
        }
    }

    func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
        try wait { done in
            self.manager.createSymbolicLink(atPath: path, withDestinationPath: destination, completionHandler: done)
        }
    }

    func read(path: String, offset: UInt64, length: Int) throws -> Data {
        let end = offset + UInt64(length)
        return try wait { done in
            self.manager.contents(atPath: path, range: offset..<end, progress: nil, completionHandler: done)
        }
    }

    func write(path: String, data: Data, offset: UInt64) throws -> Int {
        try wait { done in
            self.manager.append(data: data, toPath: path, offset: Int64(offset), progress: nil, completionHandler: done)
        }
        return data.count
    }

    private func connectLocked() throws {
        try wait { done in
            self.manager.connectShare(name: SMBConfiguration.shareName, completionHandler: done)
        }
        isConnected = true
        Logger.passthroughfs.info("Connected to SMB share \(SMBConfiguration.shareName) at \(SMBConfiguration.serverURL)")
    }

    /// Blocks until the AMSMB2 completion handler fires.
    private func wait(_ invoke: @escaping (@escaping (Error?) -> Void) -> Void) throws {
        let _: Void = try waitResult { done in
            invoke { error in
                if let error {
                    done(.failure(error))
                } else {
                    done(.success(()))
                }
            }
        }
    }

    private func wait<T>(_ invoke: @escaping (@escaping (Result<T, any Error>) -> Void) -> Void) throws -> T {
        try waitResult(invoke)
    }

    private func waitResult<T>(_ invoke: @escaping (@escaping (Result<T, any Error>) -> Void) -> Void) throws -> T {
        var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            invoke { value in
                result = value
                semaphore.signal()
            }
        }
        semaphore.wait()
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw POSIXError(.EIO)
        }
    }
}
