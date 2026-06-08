/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Model representing an SMB server connection configuration.
*/

import Foundation

/// Represents a single SMB share connection configuration.
struct SMBConnection: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var displayName: String
    var serverURL: String
    var shareName: String
    var startingPath: String
    var username: String
    var password: String

    /// Custom mount path (optional). If empty, the system chooses.
    var mountPath: String = ""

    /// Per-operation timeout in seconds (0 = disabled).
    var operationTimeout: TimeInterval = 120

    /// Whether this connection is currently mounted.
    var isMounted: Bool = false

    /// The volume UUID assigned when mounted.
    var volumeUUID: String = ""

    var displayServer: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayShare: String {
        shareName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var summary: String {
        "\(displayServer)/\(displayShare) (\(username))"
    }

    static let appGroupIdentifier = "xiaogd.com.SMBKeep"

    init(id: UUID = UUID(), displayName: String, serverURL: String, shareName: String,
         startingPath: String = "", username: String = "", password: String = "",
         mountPath: String = "", operationTimeout: TimeInterval = 120,
         isMounted: Bool = false, volumeUUID: String = "") {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.shareName = shareName
        self.startingPath = startingPath
        self.username = username
        self.password = password
        self.mountPath = mountPath
        self.operationTimeout = operationTimeout
        self.isMounted = isMounted
        self.volumeUUID = volumeUUID
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, displayName, serverURL, shareName, startingPath, username
        case password
        case mountPath, operationTimeout, isMounted, volumeUUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        shareName = try container.decode(String.self, forKey: .shareName)
        startingPath = try container.decodeIfPresent(String.self, forKey: .startingPath) ?? ""
        username = try container.decode(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        mountPath = try container.decodeIfPresent(String.self, forKey: .mountPath) ?? ""
        operationTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .operationTimeout) ?? 120
        isMounted = try container.decodeIfPresent(Bool.self, forKey: .isMounted) ?? false
        volumeUUID = try container.decodeIfPresent(String.self, forKey: .volumeUUID) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(shareName, forKey: .shareName)
        try container.encode(startingPath, forKey: .startingPath)
        try container.encode(username, forKey: .username)
        try container.encode(mountPath, forKey: .mountPath)
        try container.encode(operationTimeout, forKey: .operationTimeout)
        try container.encode(isMounted, forKey: .isMounted)
        try container.encode(volumeUUID, forKey: .volumeUUID)
    }
}
