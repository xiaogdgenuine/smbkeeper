/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
SMB server settings for the passthrough file system extension,
 read from the shared App Group container written by the main app.
*/

import Foundation
import OSLog

/// Connection parameters for the backing SMB share.
///
/// FSKit extensions cannot read the App Group container (the sandbox profile
/// doesn't expose it), so the main app instead writes a per-connection
/// `mount-config.json` into a directory it owns and passes that directory as the
/// *source* argument to `mount`. FSKit hands that directory to the extension as
/// an `FSPathURLResource` with security-scoped access, and we read the config
/// from there in `loadResource`. Each mount has its own source directory, so
/// multiple connections can be mounted at once without clobbering each other.
struct SMBConfiguration {
    /// File name written by the main app inside the mount source directory.
    static let configFileName = "mount-config.json"

    let serverURL: URL
    let shareName: String
    let username: String
    let password: String
    let volumeNameSuffix: String
    let operationTimeout: TimeInterval
    let connectionID: String
    let displayName: String
    let localUID: uid_t
    let localGID: gid_t

    static let defaultVolumeNameSuffix = "_skp"

    var credential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// Load configuration from a mount source directory delivered by FSKit as an
    /// `FSPathURLResource`. The caller is responsible for starting/stopping
    /// security-scoped access on `directory` around this call.
    static func load(fromSourceDirectory directory: URL) -> SMBConfiguration? {
        let configURL = directory.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: configURL) else {
            Logger.smbkeepfs.warning("No \(configFileName) at \(configURL.path)")
            return nil
        }
        return parse(data: data)
    }

    /// Parse a `mount-config.json` payload into a configuration.
    static func parse(data: Data) -> SMBConfiguration? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String], let url = json["serverURL"], let serverURL = URL(string: url) else {
                return nil
            }
            let config = SMBConfiguration(
                serverURL: serverURL,
                shareName: json["shareName"] ?? "",
                username: json["username"] ?? "",
                password: json["password"] ?? "",
                volumeNameSuffix: defaultVolumeNameSuffix,
                operationTimeout: TimeInterval(json["operationTimeout"] ?? "120") ?? 120,
                connectionID: json["connectionID"] ?? UUID().uuidString,
                displayName: json["displayName"] ?? json["shareName"] ?? "SMB Share",
                localUID: uid_t(json["localUID"] ?? "\(getuid())") ?? getuid(),
                localGID: gid_t(json["localGID"] ?? "\(getgid())") ?? getgid()
            )
            Logger.smbkeepfs.info("Loaded config for \(config.displayName) (\(config.serverURL)/\(config.shareName))")
            return config
        } catch {
            Logger.smbkeepfs.error("Failed to parse config: \(error)")
            return nil
        }
    }
}
