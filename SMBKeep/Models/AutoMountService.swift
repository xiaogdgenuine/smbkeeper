/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
当 App 在登录时启动时，对先前已挂载的连接执行无人值守挂载。
密码由 App 自己从 Keychain 读取，因此不会在启动脚本或 launch agent 中存储敏感数据。
*/

import Foundation
import OSLog

@MainActor
enum AutoMountService {
    private static let logger = TimestampedLogger(subsystem: "com.example.smbkeep.automount", category: "AutoMountService")

    /// 挂载用户上次挂载过的所有连接（记录在 `autoMountUUIDs` 中）。
    /// 当 `silent` 为 true 时静默运行（不弹出管理员授权）。
    static func mountSavedConnections(silent: Bool = true) async {
        let manager = SMBConnectionManager()
        let mounter = MountManager(manager: manager)

        let targets = manager.connections.filter {
            !$0.isMounted
        }

        logger.debug("Login auto-mount: \(targets.count) target(s)")

        for connection in targets {
            let ok = await mounter.mount(connection: connection, silent: silent)
            logger.debug("Auto-mount \(connection.displayName): \(ok ? "ok" : "failed")")
        }
    }
}
