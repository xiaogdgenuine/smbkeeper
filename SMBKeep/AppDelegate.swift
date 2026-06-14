/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
检测 App 是否作为登录项被系统自动启动；若是，则在后台挂载已保存的卷且不显示 UI，然后退出。
*/

import AppKit
import CoreServices
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 当本进程由系统作为登录项启动时为 true（而非用户手动打开）。
    static var launchedAsLoginItem = false

    private let logger = TimestampedLogger(subsystem: "com.example.smbkeep.app", category: "AppDelegate")

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.detectLoginItemLaunch() {
            Self.enterLoginItemMode()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 有些启动场景下，Apple Event 要到 App 即将完成启动时才变为 current，
        // 因此这里也做一次最终判定。
        if Self.detectLoginItemLaunch() {
            Self.enterLoginItemMode()
        }

        guard AppDelegate.launchedAsLoginItem else { return }
        logger.debug("Launched as login item; running silent auto-mount")

        // 确保 SwiftUI 场景留下的窗口不会残留。
        for window in NSApp.windows {
            window.close()
        }

        Task { @MainActor in
            await AutoMountService.mountSavedConnections()
            // FSKit 扩展持有活跃挂载，App 现在可以退出了。
            NSApp.terminate(nil)
        }
    }

    private static func enterLoginItemMode() {
        AppDelegate.launchedAsLoginItem = true
        // 无人值守的挂载流程不显示 Dock 图标 / 菜单栏。
        NSApp.setActivationPolicy(.accessory)
    }

    /// 登录项启动会以 `kAEOpenApplication` Apple Event 到达，
    /// 其属性数据为 `keyAELaunchedAsLogInItem`。
    private static func detectLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
