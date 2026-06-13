/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Detects whether the app was launched automatically as a login item and, if so,
mounts the saved volumes in the background without showing any UI, then quits.
*/

import AppKit
import CoreServices
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when this process was started by the system as a login item
    /// (as opposed to being opened manually by the user).
    static var launchedAsLoginItem = false

    private let logger = Logger(subsystem: "com.example.smbkeep.app", category: "AppDelegate")

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.detectLoginItemLaunch() {
            Self.enterLoginItemMode()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // On some launches the Apple Event is not current until the app is
        // finishing launch, so do the definitive check here as well.
        if Self.detectLoginItemLaunch() {
            Self.enterLoginItemMode()
        }

        guard AppDelegate.launchedAsLoginItem else { return }
        logger.info("Launched as login item; running silent auto-mount")

        // Make sure no window from the SwiftUI scene lingers.
        for window in NSApp.windows {
            window.close()
        }

        Task { @MainActor in
            await AutoMountService.mountSavedConnections()
            // The FSKit extension owns the live mount, so the app can exit now.
            NSApp.terminate(nil)
        }
    }

    private static func enterLoginItemMode() {
        AppDelegate.launchedAsLoginItem = true
        // No Dock icon / no menu bar for the unattended mount pass.
        NSApp.setActivationPolicy(.accessory)
    }

    /// A login-item launch arrives as a `kAEOpenApplication` Apple event whose
    /// property data is `keyAELaunchedAsLogInItem`.
    private static func detectLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
