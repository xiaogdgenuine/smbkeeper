/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
带挂载/卸载控制的 SMB 连接主列表视图。
*/

import AppKit
import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject var connectionManager: SMBConnectionManager
    @EnvironmentObject var mountManager: MountManager
    @EnvironmentObject var loginItemManager: LoginItemManager
    @EnvironmentObject var localizationManager: LocalizationManager
    @State private var showingAddSheet = false
    @State private var selectedConnectionID: UUID?

    var body: some View {
        NavigationSplitView {
            listContent
                .navigationTitle("SMB Keeper")
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                .safeAreaInset(edge: .bottom) {
                    sidebarFooter
                }
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showingAddSheet) {
            ConnectionEditView(connection: .constant(nil),
                               existingConnections: connectionManager.connections) { newConn in
                connectionManager.addConnection(newConn)
            }
            // sheet 是独立的弹出宿主，不会继承根视图设置的 \.locale 覆盖，
            // 需在此重新注入所选语言，否则会回退到系统语言。
            .environment(\.locale, localizationManager.locale)
        }
    }

    // MARK: - 列表

    private var listContent: some View {
        Group {
            if connectionManager.connections.isEmpty {
                emptyListPlaceholder
            } else {
                List(selection: $selectedConnectionID) {
                    ForEach(connectionManager.connections) { conn in
                        ConnectionRow(connection: conn)
                            .tag(conn.id as UUID?)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let conn = connectionManager.connections[index]
                            if !conn.isMounted {
                                connectionManager.deleteConnection(conn.id)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 没有任何连接时显示的引导视图，提供醒目的「添加服务器」入口。
    private var emptyListPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有 SMB 服务器")
                .font(.headline)
            Text("添加一个服务器即可开始挂载共享文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { showingAddSheet = true }) {
                Label("添加服务器", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 侧边栏底部常驻区

    /// 把「添加服务器」与「开机自动挂载」放到侧边栏底部，常驻可见，避免藏在菜单里。
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button(action: { showingAddSheet = true }) {
                    Label("添加服务器", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("添加一个新的 SMB 服务器连接")

                Toggle(isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动挂载")
                        Text("登录时在后台自动挂载上次已挂载的连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .help("登录时在后台自动挂载上次已挂载的连接。密码保存在钥匙串中，不会写入任何启动脚本。")

                if let error = loginItemManager.lastError {
                    Text("登录项设置失败：\(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                    Picker("语言", selection: $localizationManager.language) {
                        ForEach(AppLanguage.allCases) { language in
                            if let native = language.nativeName {
                                Text(verbatim: native).tag(language)
                            } else {
                                Text("跟随系统").tag(language)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("切换 App 界面语言")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: - 详情

    private var detailContent: some View {
        Group {
            if let id = selectedConnectionID,
               let conn = connectionManager.connections.first(where: { $0.id == id }) {
                ConnectionDetailView(connection: conn)
                    .id(conn.id)
            } else {
                ContentUnavailableView(
                    "选择 SMB 连接",
                    systemImage: "externaldrive.badge.wifi",
                    description: Text("从左侧列表选择一个连接来管理")
                )
            }
        }
    }
}

// MARK: - 连接行

struct ConnectionRow: View {
    let connection: SMBConnection
    @EnvironmentObject var connectionManager: SMBConnectionManager
    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.headline)
                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if connection.isMounted {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !connection.isMounted {
                Button("删除", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .confirmationDialog("删除连接", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                connectionManager.deleteConnection(connection.id)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除连接「\(connection.displayName)」吗？此操作不可撤销。")
        }
    }
}

// MARK: - 连接详情视图

struct ConnectionDetailView: View {
    @EnvironmentObject var connectionManager: SMBConnectionManager
    @EnvironmentObject var mountManager: MountManager
    @EnvironmentObject var localizationManager: LocalizationManager
    let connection: SMBConnection
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirmation = false
    private var liveConnection: SMBConnection {
        connectionManager.connections.first(where: { $0.id == connection.id }) ?? connection
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionHeader
                .padding()
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            infoTab
                .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showingEditSheet) {
            ConnectionEditView(connection: .constant(liveConnection),
                               existingConnections: connectionManager.connections) { updatedConn in
                connectionManager.updateConnection(updatedConn)
                if updatedConn.isMounted {
                    Task {
                        let unmounted = await mountManager.unmount(connection: updatedConn)
                        if unmounted {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await mountManager.mount(connection: updatedConn)
                        }
                    }
                }
            }
            // sheet 不会继承根视图的 \.locale 覆盖，需在此重新注入所选语言。
            .environment(\.locale, localizationManager.locale)
        }
        .confirmationDialog("删除连接", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                connectionManager.deleteConnection(connection.id)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除连接「\(liveConnection.displayName)」吗？此操作不可撤销。")
        }
    }

    // MARK: - 页头

    private var connectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(liveConnection.displayName)
                    .font(.title2)
                    .bold()

                HStack(spacing: 16) {
                    Label(liveConnection.displayServer, systemImage: "server.rack")
                    Label(liveConnection.displayShare, systemImage: "externaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(liveConnection.username, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    StatusBadge(isMounted: liveConnection.isMounted)
                }
            }

            Spacer()

            VStack(spacing: 8) {
                if liveConnection.isMounted {
                    Button(role: .destructive) {
                        Task { await mountManager.unmount(connection: liveConnection) }
                    } label: {
                        Label("卸载", systemImage: "eject")
                            .frame(minWidth: 80)
                    }
                    .disabled(mountManager.isBusy)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task { await mountManager.mount(connection: liveConnection) }
                    } label: {
                        Label("挂载", systemImage: "externaldrive.badge.checkmark")
                            .frame(minWidth: 80)
                    }
                    .disabled(mountManager.isBusy)
                    .buttonStyle(.borderedProminent)
                }

                Button("编辑") {
                    showingEditSheet = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    // MARK: - 信息标签页

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = mountManager.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("错误", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                if let restartCommand = mountManager.fskitRestartCommand {
                    FSKitRestartHint(command: restartCommand)
                }

                if !mountManager.mountOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("命令输出", systemImage: "terminal")
                            .font(.headline)
                        ScrollView(.horizontal) {
                            Text(mountManager.mountOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                }

                if mountManager.isBusy {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("操作中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(label: "服务器", value: liveConnection.serverURL)
                        DetailRow(label: "共享名", value: liveConnection.shareName)
                        DetailRow(label: "用户名", value: liveConnection.username)
                        DetailRow(label: "UUID", value: liveConnection.id.uuidString)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("连接详情", systemImage: "info.circle")
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.green)
                        Text("挂载完成后可以放心退出 App：已挂载的卷宗由系统的文件系统扩展维持，关闭本 App 不会卸载它们。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("提示", systemImage: "info.circle")
                }
            }
            .padding()
        }
    }
}

// MARK: - 辅助视图

/// 挂载失败疑似源于 FSKit 守护进程陈旧状态时显示：给出可一键复制的重启命令，由用户自行在终端执行。
struct FSKitRestartHint: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("可能需要重启 FSKit", systemImage: "arrow.clockwise.circle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("挂载失败疑似由 FSKit 守护进程状态陈旧导致。请在「终端」中执行下方命令重启后重新挂载（多数情况下并不需要这一步）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )

                Button {
                    copyCommand()
                } label: {
                    Label(copied ? LocalizedStringKey("已复制") : LocalizedStringKey("复制"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

struct StatusBadge: View {
    let isMounted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isMounted ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(isMounted ? LocalizedStringKey("已挂载") : LocalizedStringKey("未挂载"))
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(isMounted ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
        )
    }
}

struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            (Text(label) + Text(verbatim: ":"))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
    }
}
