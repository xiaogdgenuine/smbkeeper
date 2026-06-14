/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
统一的日志包装：底层仍走 OSLog，但在每条消息前拼接精确到毫秒的本地时间戳。
*/

import Foundation
import OSLog

/// 给所有日志统一加上毫秒级时间戳的轻量包装。
///
/// - 内部仍使用 `os.Logger`，因此 Console / `log stream` / 宿主 App 的日志视图都能照常读取。
/// - 每条消息前会拼一个 `HH:mm:ss.SSS` 的本地时间戳，让日志文本本身就自带时间。
/// - 注意：整条消息以 `.public` 写入。一旦把“时间戳 + 消息”拼成一个动态字符串交给
///   OSLog，若不标 `.public`，整行都会被 redact 成 `<private>`。本工具是本地调试用途，
///   公开消息内容（路径、错误等）反而便于排查。
struct TimestampedLogger {
    private let logger: Logger

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func compose(_ message: String) -> String {
        "\(Self.timestampFormatter.string(from: Date())) \(message)"
    }

    func trace(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.trace("\(line, privacy: .public)")
    }

    func debug(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.debug("\(line, privacy: .public)")
    }

    func info(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.info("\(line, privacy: .public)")
    }

    func notice(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.notice("\(line, privacy: .public)")
    }

    func warning(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.warning("\(line, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.error("\(line, privacy: .public)")
    }

    func fault(_ message: @autoclosure () -> String) {
        let line = compose(message())
        logger.fault("\(line, privacy: .public)")
    }
}
