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

    /// 自动挂载的总时间预算。开机瞬间网卡/路由常常还没就绪，
    /// 首次连接会以 “No route to host” 失败；在这个预算内对失败项反复重试，
    /// 超过预算还挂不上就放弃，避免无谓地一直占用进程。
    private static let retryBudget: TimeInterval = 60

//    /// 两轮重试之间的等待间隔。
//    private static let retryInterval: TimeInterval = 3

    /// 挂载用户上次挂载过的所有连接（记录在 `autoMountUUIDs` 中）。
    /// 当 `silent` 为 true 时静默运行（不弹出管理员授权）。
    ///
    /// 对挂载失败的连接会在 `retryBudget`（默认 30s）内带间隔重试：
    /// 开机时网络往往要过几秒才通，单次尝试很容易撞上网络未就绪的窗口。
    static func mountSavedConnections(silent: Bool = true) async {
        let manager = SMBConnectionManager()
        let mounter = MountManager(manager: manager)

        // 待挂载队列：只挑用户标记过自动挂载（记录在 autoMountUUIDs 中）且当前未挂载的连接。
        // autoMountUUIDs 在用户成功挂载时写入、显式卸载时移除，因此这里不会无脑挂载全部连接。
        // 失败的会留在队列里等下一轮重试。
        var pending = manager.connections.filter {
            manager.autoMountUUIDs.contains($0.id) && !$0.isMounted
        }

        logger.debug("Login auto-mount: \(pending.count) target(s) of \(manager.autoMountUUIDs.count) saved, budget \(Int(retryBudget))s")

        let deadline = Date().addingTimeInterval(retryBudget)
        var round = 0

        while !pending.isEmpty {
            round += 1
            var stillFailing: [SMBConnection] = []

            for connection in pending {
                let ok = await mounter.mount(connection: connection, silent: silent)
                try? await Task.sleep(for: .seconds(3))
                logger.debug("Auto-mount \(connection.displayName) [round \(round)]: \(ok ? "ok" : "failed")")
                if !ok {
                    stillFailing.append(connection)
                }
            }

            pending = stillFailing
            if pending.isEmpty { break }

            // 还有失败项：只要时间预算没用完就睡一小会儿再重试一轮。
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                logger.error("Auto-mount giving up after \(Int(retryBudget))s; \(pending.count) connection(s) still unmounted")
                break
            }

//            let sleepSeconds = min(retryInterval, remaining)
//            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }
}
