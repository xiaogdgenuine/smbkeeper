/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Registers the app as a macOS login item via SMAppService so volumes can be
auto-mounted at login without reopening the app or storing credentials in a
startup script.
*/

import Foundation
import ServiceManagement
import OSLog

/// Wraps `SMAppService.mainApp` to expose a simple "launch at login" toggle.
///
/// Credentials never touch this layer: the login-launched app reads the
/// password from the Keychain at mount time, so nothing sensitive lives in any
/// launch agent, plist, or script.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    private let logger = Logger(subsystem: "com.example.smbkeep.loginitem", category: "LoginItemManager")

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            logger.error("Login item toggle failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }
}
