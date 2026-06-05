/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
SMB server settings for the passthrough file system extension,
 read from the shared App Group container written by the main app.
*/

import Foundation
import OSLog

/// Connection parameters for the backing SMB share, loaded from shared config.
///
/// The main app writes an `active_config.json` file to the App Group container
/// before triggering a mount. This struct reads that file and falls back to
/// hard-coded defaults if no config is found.
struct SMBConfiguration {
    let serverURL: URL
    let shareName: String
    let username: String
    let password: String
    let volumeNameSuffix: String
    let operationTimeout: TimeInterval
    let connectionID: String
    let displayName: String

    static let defaultVolumeNameSuffix = "_可达增强版"

    var credential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// Load configuration from the shared App Group container.
    static func loadFromSharedContainer() -> SMBConfiguration {
        let appGroupID = "group.com.example.apple-samplecode.Passthrough"
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            Logger.passthroughfs.warning("No shared container, using defaults")
            return defaultConfig
        }

        let configURL = containerURL.appendingPathComponent("active_config.json")
        guard let data = try? Data(contentsOf: configURL) else {
            Logger.passthroughfs.warning("No active_config.json, using defaults")
            return defaultConfig
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return defaultConfig
            }
            let config = SMBConfiguration(
                serverURL: URL(string: json["serverURL"] ?? "smb://192.168.1.4")!,
                shareName: json["shareName"] ?? "2T",
                username: json["username"] ?? "test",
                password: json["password"] ?? "1Ailovetest",
                volumeNameSuffix: defaultVolumeNameSuffix,
                operationTimeout: TimeInterval(json["operationTimeout"] ?? "120") ?? 120,
                connectionID: json["connectionID"] ?? UUID().uuidString,
                displayName: json["displayName"] ?? json["shareName"] ?? "SMB Share"
            )
            Logger.passthroughfs.info("Loaded config for \(config.displayName) (\(config.serverURL)/\(config.shareName))")
            return config
        } catch {
            Logger.passthroughfs.error("Failed to parse config: \(error)")
            return defaultConfig
        }
    }

    private static var defaultConfig: SMBConfiguration {
        SMBConfiguration(
            serverURL: URL(string: "smb://192.168.1.4")!,
            shareName: "2T",
            username: "test",
            password: "1Ailovetest",
            volumeNameSuffix: defaultVolumeNameSuffix,
            operationTimeout: 120,
            connectionID: UUID().uuidString,
            displayName: "默认共享"
        )
    }
}
