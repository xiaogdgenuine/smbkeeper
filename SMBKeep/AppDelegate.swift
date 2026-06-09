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
    static private(set) var launchedAsLoginItem = false

    private let logger = Logger(subsystem: "com.example.smbkeep.app", category: "AppDelegate")

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.launchedAsLoginItem = Self.detectLoginItemLaunch()
        if AppDelegate.launchedAsLoginItem {
            // No Dock icon / no menu bar for the unattended mount pass.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    /// A login-item launch arrives as a `kAEOpenApplication` Apple event whose
    /// property data is `keyAELaunchedAsLogInItem`.
    private static func detectLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
