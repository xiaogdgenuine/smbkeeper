/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
View for displaying extension runtime logs for a specific SMB connection.
*/

import SwiftUI
import OSLog

/// Displays real-time logs from the extension, read live from the unified log store.
struct LogViewer: View {
    let connectionID: UUID

    @EnvironmentObject var connectionManager: SMBConnectionManager
    @State private var logContent: String = ""
    @State private var autoScroll = true
    @State private var refreshTimer: Timer?
    @State private var isRefreshing = false
    /// Only show entries at or after this instant; "清空" advances it to now.
    @State private var sinceDate = Date()

    private static let logLimit = 10_000          // max characters to display
    private static let windowSeconds: TimeInterval = 600  // bound the live query window

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button {
                    refreshLog()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Spacer()

                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button {
                    logContent = ""
                    sinceDate = Date()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logBottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logContent) { _ in
                    if autoScroll {
                        withAnimation {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear {
            sinceDate = Date().addingTimeInterval(-Self.windowSeconds)
            refreshLog()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                refreshLog()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refreshLog() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Bound the query window so a long-open viewer stays responsive.
        let effectiveSince = max(sinceDate, Date().addingTimeInterval(-Self.windowSeconds))
        let connectionID = self.connectionID
        let logLimit = Self.logLimit
        Task.detached(priority: .utility) {
            let lines = ExtensionLogReader.read(since: effectiveSince, connectionID: connectionID)
            let joined = lines.joined(separator: "\n")
            let text = joined.count > logLimit
                ? "... [日志截断] ...\n" + String(joined.suffix(logLimit))
                : joined
            await MainActor.run {
                self.logContent = text
                self.isRefreshing = false
            }
        }
    }
}
