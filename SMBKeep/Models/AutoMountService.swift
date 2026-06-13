/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Performs unattended mounting of previously-mounted connections when the app is
launched at login. Passwords are read from the Keychain by the app itself, so
no sensitive data is stored in any startup script or launch agent.
*/

import Foundation
import OSLog

@MainActor
enum AutoMountService {
    private static let logger = Logger(subsystem: "com.example.smbkeep.automount", category: "AutoMountService")

    /// Mount every connection the user had mounted last (tracked in
    /// `autoMountUUIDs`). Runs silently when `silent` is true (no admin prompt).
    static func mountSavedConnections(silent: Bool = true) async {
        let manager = SMBConnectionManager()
        let mounter = MountManager(manager: manager)

        let targets = manager.connections.filter {
            !$0.isMounted
        }

        logger.info("Login auto-mount: \(targets.count) target(s)")

        for connection in targets {
            let ok = await mounter.mount(connection: connection, silent: silent)
            logger.info("Auto-mount \(connection.displayName, privacy: .public): \(ok ? "ok" : "failed")")
        }
    }
}
