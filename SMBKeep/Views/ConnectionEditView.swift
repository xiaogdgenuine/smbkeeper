/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
用于添加或编辑 SMB 连接的 Sheet 视图。
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
    @State private var displayName: String = ""
    @FocusState private var addressFieldFocused: Bool

    private var isEditing: Bool { connection != nil }

    private var parsedServer: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        guard let first = components.first else { return "" }
        return String(first).trimmingCharacters(in: .whitespaces)
    }

    private var parsedShare: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let rest = String(components[1]).trimmingCharacters(in: .whitespaces)
            let shareComponents = rest.split(separator: "/", maxSplits: 1)
            if let first = shareComponents.first {
                return String(first)
            }
        }
        // 只填了服务器、没填共享名时返回空。
        // 绝不能兜底成服务器名：那样 tree connect 会连到不存在的 \\server\server，
        // 服务器返回 STATUS_BAD_NETWORK_NAME。
        return ""
    }

    private var parsedStartingPath: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let rest = String(components[1]).trimmingCharacters(in: .whitespaces)
            let shareComponents = rest.split(separator: "/", maxSplits: 1)
            if shareComponents.count > 1 {
                let subpath = String(shareComponents[1]).trimmingCharacters(in: .whitespaces)
                return subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            }
        }
        return ""
    }

    private var parsedFullPath: String {
        let components = connectionPath.split(separator: "/", maxSplits: 1)
        if components.count > 1 {
            let path = String(components[1]).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return path }
        }
        return parsedServer
    }

    private var autoDisplayName: String {
        parsedFullPath.components(separatedBy: "/").compactMap { $0 == "" ? nil : $0 }.last ?? ""
    }

    /// 除当前连接外，其它连接已占用的显示名称。
    private var otherDisplayNames: [String] {
        existingConnections
            .filter { isEditing ? $0.id != connection?.id : true }
            .map { $0.displayName }
    }

    /// 根据路径自动生成、并避开已占用名称的显示名（留空时采用）。
    private var deduplicatedDisplayName: String {
        let name = autoDisplayName
        guard !name.isEmpty else { return "" }
        let existingNames = otherDisplayNames
        if !existingNames.contains(name) { return name }
        var i = 2
        while existingNames.contains("\(name) \(i)") { i += 1 }
        return "\(name) \(i)"
    }

    /// 用户在输入框里填写的名称（去除首尾空白）。
    private var trimmedCustomName: String {
        displayName.trimmingCharacters(in: .whitespaces)
    }

    /// 最终采用的名称：填了就用自定义名称，留空则用自动生成且去重的名称。
    private var effectiveDisplayName: String {
        trimmedCustomName.isEmpty ? deduplicatedDisplayName : trimmedCustomName
    }

    /// 用户填写的自定义名称是否与其它连接重复（留空时走自动去重，不算重复）。
    private var isCustomNameDuplicate: Bool {
        guard !trimmedCustomName.isEmpty else { return false }
        return otherDisplayNames.contains(trimmedCustomName)
    }

    /// 名称输入框为空时的占位提示：展示将要自动生成的名称。
    private var namePrompt: Text {
        let auto = deduplicatedDisplayName
        return auto.isEmpty ? Text("留空将根据路径自动生成") : Text(verbatim: auto)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("名称", text: $displayName, prompt: namePrompt)
                        .help("自定义此连接在 Finder 中显示的名称。留空将根据路径自动生成；名称不能与其它连接重复。")
                    if isCustomNameDuplicate {
                        Text("已存在同名连接，请换一个名称")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField("smb://", text: $connectionPath)
                        .focused($addressFieldFocused)
                        .help("格式：服务器/共享名，例如 192.168.1.4/share。共享名后的子目录路径仅用于生成显示名称")
                    HStack {
                        Spacer()
                        Text("示例：192.168.1.4/share")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }

                Section("认证信息（可选）") {
                    TextField("用户名（留空则匿名访问）", text: $username)
                    SecureField("密码", text: $password)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? LocalizedStringKey("编辑连接") : LocalizedStringKey("新建连接"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? LocalizedStringKey("保存") : LocalizedStringKey("添加")) {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                if let conn = connection {
                    if conn.shareName == conn.serverURL.replacingOccurrences(of: "smb://", with: "") {
                        connectionPath = conn.serverURL.replacingOccurrences(of: "smb://", with: "")
                    } else {
                        var path = "\(conn.serverURL.replacingOccurrences(of: "smb://", with: ""))/\(conn.shareName)"
                        if !conn.startingPath.isEmpty {
                            path += "/\(conn.startingPath)"
                        }
                        connectionPath = path
                    }
                    username = conn.username
                    password = conn.password
                    displayName = conn.displayName
                } else {
                    // 新建连接时，焦点先落到地址输入框，方便直接输入。
                    addressFieldFocused = true
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var isValid: Bool {
        !parsedServer.isEmpty && !parsedShare.isEmpty && !isCustomNameDuplicate
    }

    private func save() {
        let server = parsedServer
        let serverURL = server.hasPrefix("smb://") ? server : "smb://\(server)"

        let conn = SMBConnection(
            id: connection?.id ?? UUID(),
            displayName: effectiveDisplayName,
            serverURL: serverURL,
            shareName: parsedShare,
            startingPath: parsedStartingPath,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            mountPath: connection?.mountPath ?? "",
            isMounted: connection?.isMounted ?? false,
            volumeUUID: connection?.volumeUUID ?? ""
        )
        onSave(conn)
        dismiss()
    }
}
