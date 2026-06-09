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
    /// `autoMountUUIDs`). Runs silently: no UI, no admin prompt.
    static func mountSavedConnections() async {
        let manager = SMBConnectionManager()
        let mounter = MountManager(manager: manager)

        let targets = manager.connections.filter {
            manager.autoMountUUIDs.contains($0.id) && !$0.isMounted
        }

        logger.info("Login auto-mount: \(targets.count) target(s)")

        for connection in targets {
            let ok = await mounter.mount(connection: connection, silent: true)
            logger.info("Auto-mount \(connection.displayName, privacy: .public): \(ok ? "ok" : "failed")")
        }
    }
}
