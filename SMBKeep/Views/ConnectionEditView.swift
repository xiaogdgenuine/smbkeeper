/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Sheet view for adding or editing an SMB connection.
*/

import SwiftUI

struct ConnectionEditView: View {
    @Binding var connection: SMBConnection?
    let onSave: (SMBConnection) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var serverURL: String = "smb://"
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var operationTimeout: Double = 120

    private var isEditing: Bool { connection != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("显示名称", text: $displayName)
                        .help("例如：我的共享文件夹")

                    HStack {
                        TextField("服务器地址", text: $serverURL)
                            .help("例如：smb://192.168.1.100")
                        Button("清除") {
                            serverURL = "smb://"
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }

                    TextField("共享名称", text: $shareName)
                        .help("SMB 服务器上的共享名")
                }

                Section("认证信息") {
                    TextField("用户名", text: $username)
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

                Section {
                    Text("注意：密码以明文存储在本地的共享容器中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    displayName = conn.displayName
                    serverURL = conn.serverURL
                    shareName = conn.shareName
                    username = conn.username
                    password = conn.password
                    operationTimeout = conn.operationTimeout
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let conn = SMBConnection(
            id: connection?.id ?? UUID(),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            serverURL: serverURL.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
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
