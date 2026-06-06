/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
View for displaying extension runtime logs for a specific SMB connection.
*/

import SwiftUI
import OSLog

/// Displays real-time logs from the extension for a given connection.
struct LogViewer: View {
    let connectionID: UUID

    @EnvironmentObject var connectionManager: SMBConnectionManager
    @State private var logContent: String = ""
    @State private var autoScroll = true
    @State private var refreshTimer: Timer?

    private static let logLimit = 10_000  // max characters to display

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
                    clearExtensionLog()
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
            refreshLog()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshLog()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refreshLog() {
        let raw = connectionManager.readLog(for: connectionID)
        if raw.count > Self.logLimit {
            logContent = "... [日志截断] ...\n" + String(raw.suffix(Self.logLimit))
        } else {
            logContent = raw
        }
    }

    private func clearExtensionLog() {
        guard let url = connectionManager.logFileURL(for: connectionID) else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        logContent = ""
    }
}
