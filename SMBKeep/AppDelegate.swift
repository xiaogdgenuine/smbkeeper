/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
检测 App 是否作为登录项被系统自动启动，并据此决定挂载行为：
· 登录项启动：后台静默挂载已保存的卷、不显示 UI，挂载完成后自动退出。
· 普通启动（含「下次登录重新打开窗口」的系统恢复、用户手动打开）：同样把尚未挂载的
  自动挂载连接补挂上，但保留 UI、不退出。
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

        if AppDelegate.launchedAsLoginItem {
            logger.debug("Launched as login item; running silent auto-mount then quitting")

            // 确保 SwiftUI 场景留下的窗口不会残留。
            for window in NSApp.windows {
                window.close()
            }

            Task { @MainActor in
                await AutoMountService.mountSavedConnections()
                // FSKit 扩展持有活跃挂载，App 现在可以退出了。
                NSApp.terminate(nil)
            }
        } else {
            // 普通启动（含「下次登录重新打开窗口」的系统恢复、用户手动打开）：
            // 同样把尚未挂载的自动挂载连接补挂上，但保留 UI、不退出。
            logger.debug("Normal launch; auto-mounting any pending saved connections")

            Task { @MainActor in
                await AutoMountService.mountSavedConnections()
            }
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
//        return true
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
