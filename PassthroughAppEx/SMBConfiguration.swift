/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Hard-coded SMB server settings for the passthrough file system extension.
*/

import Foundation

/// Connection parameters for the backing SMB share.
///
/// Edit these constants to match your server before building or mounting the file system.
enum SMBConfiguration {
    /// SMB server URL, e.g. `smb://192.168.1.10` or `smb://nas.local`.
    static let serverURL = URL(string: "smb://192.168.1.4")!

    /// Share name on the server (not a subfolder path).
    static let shareName = "2T"

    static let username = "test"
    static let password = "1Ailovetest"

    /// Display name suffix for the FSKit volume.
    static let volumeNameSuffix = "_可达增强版"

    static var credential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// Per-operation timeout in seconds (`0` disables).
    static let operationTimeout: TimeInterval = 120
}
