/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The app's top-level SwiftUI body.
*/

import SwiftUI
import AppKit

@main
struct SMBKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionManager: SMBConnectionManager
    @StateObject private var mountManager: MountManager
    @StateObject private var loginItemManager = LoginItemManager()

    init() {
        let cm = SMBConnectionManager()
        _connectionManager = StateObject(wrappedValue: cm)
        _mountManager = StateObject(wrappedValue: MountManager(manager: cm))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
                .environmentObject(mountManager)
                .environmentObject(loginItemManager)
        }
    }
}
