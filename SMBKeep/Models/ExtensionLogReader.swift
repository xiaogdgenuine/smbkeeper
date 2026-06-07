/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Reads the FSKit extension's runtime logs live from the unified logging system.

The extension logs via `Logger` (OSLog). Because the host app is not sandboxed,
it can open the local log store with `OSLogStore.local()` and read entries from
other processes — so no on-disk log file is needed.
*/

import Foundation
import OSLog

enum ExtensionLogReader {

    /// Subsystem used by the extension's `Logger.smbkeepfs`.
    static let subsystem = "com.apple.fskit.SMBKeepFS"

    /// Reads extension log lines for one connection emitted at or after `since`.
    ///
    /// This performs a blocking query against the unified log store, so call it
    /// off the main thread. Returns the formatted lines, or an error message line.
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

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"

            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                lines.append("[\(formatter.string(from: entry.date))] \(entry.composedMessage)")
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
