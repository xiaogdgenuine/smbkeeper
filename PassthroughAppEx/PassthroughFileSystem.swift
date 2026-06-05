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

/// Load SMB config from the shared App Group container.
/// Cached after first load to avoid repeated I/O during the volume's lifetime.
private var _cachedConfig: SMBConfiguration?
func currentSMBConfig() -> SMBConfiguration {
    if let cached = _cachedConfig { return cached }
    let config = SMBConfiguration.loadFromSharedContainer()
    _cachedConfig = config
    return config
}

func createVolumeNameFromSMB() -> FSFileName {
    let config = currentSMBConfig()
    return FSFileName(string: config.displayName + config.volumeNameSuffix)
}

/// A file system that exposes an SMB share through FSKit.
@objc
class PassthroughFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var loadedVolume: PassthroughFSVolume?
    let smbConfig: SMBConfiguration

    public override init() {
        self.smbConfig = currentSMBConfig()
        Logger.passthroughfs.debug("\(#function): init with config \(self.smbConfig.displayName)")
        super.init()
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        for opt in options.taskOptions where opt.contains("-f") {
            return replyHandler(nil, POSIXError(.ENOTSUP))
        }

        do {
            // Use the config loaded at init time
            let smbConfig = self.smbConfig

            // Initialize the SMB backend with the config from shared container
            let backend = try SMBBackend(config: smbConfig)
            let volumeName = FSFileName(string: smbConfig.displayName + smbConfig.volumeNameSuffix)
            let volume = try PassthroughFSVolume(backend: backend,
                                                  volumeName: volumeName,
                                                  smbConfig: smbConfig)
            self.containerStatus = .ready
            self.loadedVolume = volume

            // Write a startup log entry
            volume.log("Volume mounted: \(smbConfig.displayName) at \(smbConfig.serverURL)/\(smbConfig.shareName)")

            return replyHandler(volume, nil)
        } catch {
            Logger.passthroughfs.error("\(#function): SMB setup failed: \(error)")
            return replyHandler(nil, error)
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions,
                               replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let volume = self.loadedVolume {
            volume.log("Volume unmounted: \(volume.volumeLabel)")
            volume.smb.disconnect()
        }
        self.loadedVolume = nil
        _cachedConfig = nil
        return reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        let config = currentSMBConfig()
        let name = config.displayName + config.volumeNameSuffix
        let containerID = FSContainerIdentifier(uuid: UUID())
        let probeResult = FSProbeResult.usable(name: name, containerID: containerID)
        return replyHandler(probeResult, nil)
    }
}
