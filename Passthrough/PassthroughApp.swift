/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's top-level SwiftUI body.
*/

import SwiftUI

@main
struct PassthroughApp: App {
    @StateObject private var connectionManager: SMBConnectionManager
    @StateObject private var mountManager: MountManager

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
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}
