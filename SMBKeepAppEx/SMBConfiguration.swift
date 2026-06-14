/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
透传文件系统扩展所用的 SMB 服务器设置，
从主 App 写入的共享 App Group 容器中读取。
*/

import Foundation
import OSLog

/// 后端 SMB 共享的连接参数。
///
/// FSKit 扩展无法读取 App Group 容器（沙盒配置不暴露它），因此主 App 改为把一个每连接独立的
/// `mount-config.json` 写入它自己拥有的目录，并把该目录作为 `mount` 的 *source* 参数传入。
/// FSKit 会以带安全作用域访问权限的 `FSPathURLResource` 把该目录交给扩展，
/// 我们在 `loadResource` 中从那里读取配置。每次挂载都有各自独立的 source 目录，
/// 因此多个连接可以同时挂载而互不干扰。
struct SMBConfiguration {
    /// 主 App 写入挂载 source 目录中的文件名。
    static let configFileName = "mount-config.json"

    let serverURL: URL
    let shareName: String
    let startingPath: String
    let username: String
    let password: String
    let volumeNameSuffix: String
    let connectionID: String
    let displayName: String
    let localUID: uid_t
    let localGID: gid_t

    static let defaultVolumeNameSuffix = "_skp"

    var credential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// 从 FSKit 以 `FSPathURLResource` 形式交付的挂载 source 目录中加载配置。
    /// 调用方需负责在此调用前后对 `directory` 启动/停止安全作用域访问。
    static func load(fromSourceDirectory directory: URL) -> SMBConfiguration? {
        let configURL = directory.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: configURL) else {
            TimestampedLogger.smbkeepfs.warning("No \(configFileName) at \(configURL.path)")
            return nil
        }
        return parse(data: data)
    }

    /// 把 `mount-config.json` 的内容解析为一个配置对象。
    static func parse(data: Data) -> SMBConfiguration? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String], let url = json["serverURL"], let serverURL = URL(string: url) else {
                return nil
            }
            let config = SMBConfiguration(
                serverURL: serverURL,
                shareName: json["shareName"] ?? "",
                startingPath: (json["startingPath"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/\\")),
                username: json["username"] ?? "",
                password: json["password"] ?? "",
                volumeNameSuffix: defaultVolumeNameSuffix,
                connectionID: json["connectionID"] ?? UUID().uuidString,
                displayName: json["displayName"] ?? json["shareName"] ?? "SMB Share",
                localUID: uid_t(json["localUID"] ?? "\(getuid())") ?? getuid(),
                localGID: gid_t(json["localGID"] ?? "\(getgid())") ?? getgid()
            )
            TimestampedLogger.smbkeepfs.info("Loaded config for \(config.displayName) (\(config.serverURL)/\(config.shareName))")
            return config
        } catch {
            TimestampedLogger.smbkeepfs.error("Failed to parse config: \(error)")
            return nil
        }
    }
}
