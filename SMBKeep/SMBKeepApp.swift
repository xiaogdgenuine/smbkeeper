/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
App 的顶层 SwiftUI 入口。
*/

import SwiftUI
import AppKit

@main
struct SMBKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionManager: SMBConnectionManager
    @StateObject private var mountManager: MountManager
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var localizationManager = LocalizationManager.shared

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
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
        }
    }
}
