/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The custom class that implements a simplified file system backed by SMB (AMSMB2).
*/

import Foundation
import FSKit

extension Logger {
    static let smbkeepfs = Logger(subsystem: "com.apple.fskit.SMBKeepFS", category: "default")
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
            Logger.smbkeepfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

/// Read the SMB config for a mount from the `FSPathURLResource` that FSKit hands
/// the extension. The main app passes a per-connection directory (containing
/// `mount-config.json`) as the mount *source*, and FSKit grants security-scoped
/// access to it because `FSRequiresSecurityScopedPathURLResources` is set.
///
/// This is the only channel that works for FSKit extensions: the App Group
/// container is not exposed to the extension's sandbox, so reading shared files
/// from there fails. Reading from the resource also keeps each mount's config
/// independent, which is what lets multiple connections mount simultaneously.
private func loadConfig(from resource: FSResource) -> SMBConfiguration? {
    guard let urlResource = resource as? FSPathURLResource else {
        Logger.smbkeepfs.error("Resource is not an FSPathURLResource: \(type(of: resource))")
        return nil
    }
    let url = urlResource.url
    let didStart = url.startAccessingSecurityScopedResource()
    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
    return SMBConfiguration.load(fromSourceDirectory: url)
}

/// A file system that exposes an SMB share through FSKit.
@objc
class SMBKeepFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var loadedVolume: SMBKeepFSVolume?

    public override init() {
        super.init()
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {

        for opt in options.taskOptions where opt.contains("-f") {
            return replyHandler(nil, POSIXError(.ENOTSUP))
        }

        guard let smbConfig = loadConfig(from: resource) else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        do {
            // Initialize the SMB backend with the config read from the mount source.
            let backend = try SMBBackend(config: smbConfig)
            let volumeName = FSFileName(string: smbConfig.displayName + smbConfig.volumeNameSuffix)
            let volume = try SMBKeepFSVolume(backend: backend,
                                             volumeName: volumeName,
                                             smbConfig: smbConfig)
            self.containerStatus = .ready
            self.loadedVolume = volume

            // Write a startup log entry
            volume.log("Volume mounted: \(smbConfig.displayName) at \(smbConfig.serverURL)/\(smbConfig.shareName)")

            return replyHandler(volume, nil)
        } catch {
            Logger.smbkeepfs.error("\(#function): SMB setup failed: \(error)")
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
        return reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let config = loadConfig(from: resource) else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let name = config.displayName + config.volumeNameSuffix
        // Derive a stable container ID from the connection so each connection
        // gets a distinct container and multiple mounts don't collide.
        let containerUUID = UUID(uuidString: config.connectionID) ?? UUID()
        let containerID = FSContainerIdentifier(uuid: containerUUID)
        let probeResult = FSProbeResult.usable(name: name, containerID: containerID)
        return replyHandler(probeResult, nil)
    }
}
