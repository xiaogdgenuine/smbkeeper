/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The custom class that implements a simplified file system backed by SMB (AMSMB2).
*/

import Foundation
import FSKit

extension Logger {
    static let passthroughfs = Logger(subsystem: "com.apple.fskit.PassthroughFS", category: "default")
}

/// Returns the current `errno` value as a `POSIXError`.
var posixErrno: POSIXError {
    POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
}

/// Returns the result of the given block, or throws an error if `errno` is nonzero.
func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    let ret = try block()
    guard ret >= 0 else {
        guard errno != 0 else {
            Logger.passthroughfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

func createVolumeNameFromSMB() -> FSFileName {
    FSFileName(string: SMBConfiguration.shareName + SMBConfiguration.volumeNameSuffix)
}

/// A file system that exposes an SMB share through FSKit using [AMSMB2](https://github.com/amosavian/AMSMB2).
@objc
class PassthroughFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var loadedVolume: PassthroughFSVolume?

    public override init() {
        Logger.passthroughfs.debug("\(#function): init")
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        for opt in options.taskOptions where opt.contains("-f") {
            return replyHandler(nil, POSIXError(.ENOTSUP))
        }

        do {
            let backend = try SMBBackend()
            let volume = try PassthroughFSVolume(backend: backend, volumeName: createVolumeNameFromSMB())
            self.containerStatus = .ready
            self.loadedVolume = volume
            return replyHandler(volume, nil)
        } catch {
            Logger.passthroughfs.error("\(#function): SMB setup failed: \(error)")
            return replyHandler(nil, error)
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions,
                               replyHandler reply: @escaping ((any Error)?) -> Void) {
        self.loadedVolume?.smb.disconnect()
        self.loadedVolume = nil
        return reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        let name = createVolumeNameFromSMB().string ?? "smb_passthrough"
        let containerID = FSContainerIdentifier(uuid: UUID())
        let probeResult = FSProbeResult.usable(name: name, containerID: containerID)
        return replyHandler(probeResult, nil)
    }
}
