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

    static let appGroupIdentifier = "group.com.example.apple-samplecode.Passthrough"
}
