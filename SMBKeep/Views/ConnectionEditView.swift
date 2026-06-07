/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Sheet view for adding or editing an SMB connection.
*/

import SwiftUI

struct ConnectionEditView: View {
    @Binding var connection: SMBConnection?
    let existingConnections: [SMBConnection]
    let onSave: (SMBConnection) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var connectionPath: String = "192.168.1."
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var operationTimeout: Double = 120

    private var isEditing: Bool { connection != nil }

    private var parsedServer: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        guard let first = components.first else { return "" }
        return String(first).trimmingCharacters(in: .whitespaces)
    }

    private var parsedShare: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let s = String(components[1]).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return parsedServer
    }

    private var autoDisplayName: String {
        parsedShare
    }

    private var deduplicatedDisplayName: String {
        let name = autoDisplayName
        guard !name.isEmpty else { return "" }
        let existingNames = existingConnections
            .filter { isEditing ? $0.id != connection?.id : true }
            .map { $0.displayName }
        if !existingNames.contains(name) { return name }
        var i = 2
        while existingNames.contains("\(name) \(i)") { i += 1 }
        return "\(name) \(i)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("服务器地址/共享名", text: $connectionPath)
                        .help("例如：192.168.1.4/Root")

                    if !autoDisplayName.isEmpty {
                        HStack {
                            Text("名称")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(deduplicatedDisplayName)
                        }
                        .font(.callout)
                    }
                }

                Section("认证信息（可选）") {
                    TextField("用户名（留空则匿名访问）", text: $username)
                    SecureField("密码", text: $password)
                }

                Section("高级设置") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("操作超时: \(Int(operationTimeout))秒")
                            Spacer()
                        }
                        Slider(value: $operationTimeout, in: 10...300, step: 10)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "编辑连接" : "新建连接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存" : "添加") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                if let conn = connection {
                    if conn.shareName == conn.serverURL {
                        connectionPath = conn.serverURL
                    } else {
                        connectionPath = "\(conn.serverURL)/\(conn.shareName)"
                    }
                    username = conn.username
                    password = conn.password
                    operationTimeout = conn.operationTimeout
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var isValid: Bool {
        !parsedServer.isEmpty
    }

    private func save() {
        let conn = SMBConnection(
            id: connection?.id ?? UUID(),
            displayName: deduplicatedDisplayName,
            serverURL: parsedServer,
            shareName: parsedShare,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            mountPath: connection?.mountPath ?? "",
            operationTimeout: operationTimeout,
            isMounted: connection?.isMounted ?? false,
            volumeUUID: connection?.volumeUUID ?? ""
        )
        onSave(conn)
        dismiss()
    }
}
