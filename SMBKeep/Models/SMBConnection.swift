/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
表示一条 SMB 服务器连接配置的模型。
*/

import Foundation

/// 表示一条 SMB 共享连接配置。
struct SMBConnection: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var displayName: String
    var serverURL: String
    var shareName: String
    var startingPath: String
    var username: String
    var password: String

    /// 自定义挂载路径（可选）。为空时由系统选择。
    var mountPath: String = ""

    /// 该连接当前是否已挂载。
    var isMounted: Bool = false

    /// 挂载时分配的卷 UUID。
    var volumeUUID: String = ""

    var displayServer: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayShare: String {
        shareName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var summary: String {
        "\(displayServer)/\(displayShare) (\(username))"
    }

    static let appGroupIdentifier = "xiaogd.com.SMBKeep"

    init(id: UUID = UUID(), displayName: String, serverURL: String, shareName: String,
         startingPath: String = "", username: String = "", password: String = "",
         mountPath: String = "", isMounted: Bool = false, volumeUUID: String = "") {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.shareName = shareName
        self.startingPath = startingPath
        self.username = username
        self.password = password
        self.mountPath = mountPath
        self.isMounted = isMounted
        self.volumeUUID = volumeUUID
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, displayName, serverURL, shareName, startingPath, username
        case password
        case mountPath, isMounted, volumeUUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        shareName = try container.decode(String.self, forKey: .shareName)
        startingPath = try container.decodeIfPresent(String.self, forKey: .startingPath) ?? ""
        username = try container.decode(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        mountPath = try container.decodeIfPresent(String.self, forKey: .mountPath) ?? ""
        isMounted = try container.decodeIfPresent(Bool.self, forKey: .isMounted) ?? false
        volumeUUID = try container.decodeIfPresent(String.self, forKey: .volumeUUID) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(shareName, forKey: .shareName)
        try container.encode(startingPath, forKey: .startingPath)
        try container.encode(username, forKey: .username)
        try container.encode(mountPath, forKey: .mountPath)
        try container.encode(isMounted, forKey: .isMounted)
        try container.encode(volumeUUID, forKey: .volumeUUID)
    }
}
