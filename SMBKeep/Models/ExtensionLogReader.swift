/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
从统一日志系统实时读取 FSKit 扩展的运行时日志。

扩展通过 `Logger`（OSLog）写日志。宿主 App 未沙盒化，
因此可以用 `OSLogStore.local()` 打开本地日志存储并读取其它进程的条目——
无需额外的磁盘日志文件。
*/

import Foundation
import OSLog

enum ExtensionLogReader {

    /// 扩展的 `Logger.smbkeepfs` 使用的 subsystem。
    static let subsystem = "com.apple.fskit.SMBKeepFS"

    /// 读取某个连接在 `since` 之后（含）产生的扩展日志行。
    ///
    /// 这会阻塞地查询统一日志存储，因此请在主线程之外调用。
    /// 返回格式化后的行，或一条错误信息行。
    static func read(since: Date, connectionID: UUID, limit: Int = 2000) -> [String] {
        do {
            let store = try OSLogStore.local()
            let position = store.position(date: since)
            let predicate = NSPredicate(
                format: "subsystem == %@ AND category == %@",
                subsystem,
                connectionID.uuidString
            )
            let entries = try store.getEntries(at: position, matching: predicate)

            // 每条日志消息本身已带毫秒时间戳（见 TimestampedLogger），这里不再重复添加。
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                lines.append(entry.composedMessage)
            }
            if lines.count > limit {
                lines = Array(lines.suffix(limit))
            }
            return lines
        } catch {
            return ["无法读取统一日志（需非沙盒且以管理员账户运行）: \(error.localizedDescription)"]
        }
    }
}
