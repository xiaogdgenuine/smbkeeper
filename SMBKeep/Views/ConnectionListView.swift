/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Main list view of SMB connections with mount/unmount controls.
*/

import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject var connectionManager: SMBConnectionManager
    @EnvironmentObject var mountManager: MountManager
    @State private var showingAddSheet = false
    @State private var selectedConnectionID: UUID?

    var body: some View {
        NavigationSplitView {
            listContent
                .navigationTitle("SMB Keeper")
                .toolbar { toolbarContent }
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showingAddSheet) {
            ConnectionEditView(connection: .constant(nil),
                               existingConnections: connectionManager.connections) { newConn in
                connectionManager.addConnection(newConn)
            }
        }
    }

    // MARK: - List

    private var listContent: some View {
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showingAddSheet = true }) {
                Label("添加", systemImage: "plus")
            }
        }
    }

    // MARK: - Detail

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

// MARK: - Connection Row

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

// MARK: - Connection Detail View

struct ConnectionDetailView: View {
    @EnvironmentObject var connectionManager: SMBConnectionManager
    @EnvironmentObject var mountManager: MountManager
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

    // MARK: - Header

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

    // MARK: - Info Tab

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
                        DetailRow(label: "超时", value: "\(Int(liveConnection.operationTimeout))秒")
                        DetailRow(label: "UUID", value: liveConnection.id.uuidString)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Label("连接详情", systemImage: "info.circle")
                }
            }
            .padding()
        }
    }
}

// MARK: - Supporting Views

struct StatusBadge: View {
    let isMounted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isMounted ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(isMounted ? "已挂载" : "未挂载")
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
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
    }
}
