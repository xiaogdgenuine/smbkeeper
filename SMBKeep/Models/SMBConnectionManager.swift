/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
管理存储在共享 App Group 容器中的 SMB 连接配置。
*/

import AppKit
import Foundation
import OSLog

/// 管理对共享 App Group 容器中 SMB 连接配置的读写。
@MainActor
class SMBConnectionManager: ObservableObject {
    @Published var connections: [SMBConnection] = []
    @Published var activeVolumeUUIDs: Set<UUID> = []

    /// 用户希望在登录时恢复的连接。与 `activeVolumeUUIDs` 不同，
    /// 这个集合不会被 `reconcileMountStateWithSystem()` 清空，
    /// 因此能在重启后（此时尚未挂载任何东西）存活下来，并驱动自动挂载。
    @Published var autoMountUUIDs: Set<UUID> = []

    private let logger = TimestampedLogger(subsystem: "com.example.smbkeep.manager", category: "SMBConnectionManager")
    private var mountStateMonitorTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    static let connectionsFileName = "smb_connections.json"
    static let activeMountsFileName = "active_mounts.json"
    static let autoMountFileName = "auto_mount.json"

    /// App 自有的连接/状态 JSON 存储。App Group 容器已弃用：
    /// FSKit 扩展沙盒读不到它，而未沙盒化的 App 也不需要它，
    /// 未配置的 app-group entitlement 只会产生 “entitlement ignored” 警告。
    /// 我们复用已经存放 `mount-sources` 的同一 Application Support 目录。
    var sharedContainerURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        let dir = appSupport.appendingPathComponent(bundleID)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var connectionsFileURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.connectionsFileName)
    }

    var activeMountsFileURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.activeMountsFileName)
    }

    var autoMountFileURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.autoMountFileName)
    }

    init() {
        loadConnections()
        loadActiveMounts()
        loadAutoMount()
        reconcileMountStateWithSystem()
        startMountStateMonitoring()
    }

    deinit {
        mountStateMonitorTask?.cancel()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in appObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 连接持久化

    func loadConnections() {
        guard let url = connectionsFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([SMBConnection].self, from: data)
            connections = decoded
            restorePasswordsFromKeychain()
            logger.debug("Loaded \(decoded.count) connection(s)")
        } catch {
            logger.debug("No saved connections, using defaults")
        }
    }

    func saveConnections() {
        guard let url = connectionsFileURL else { return }
        let connections = self.connections
        do {
            let data = try JSONEncoder().encode(connections)
            try data.write(to: url, options: .atomic)
            logger.debug("Saved \(connections.count) connection(s)")
        } catch {
            logger.error("Failed to save connections: \(error)")
        }
    }

    private func restorePasswordsFromKeychain() {
        var changed = false
        for i in connections.indices {
            let conn = connections[i]
            if let keychainPassword = KeychainHelper.getPassword(forConnectionID: conn.id) {
                if conn.password != keychainPassword {
                    connections[i].password = keychainPassword
                }
            } else if !conn.password.isEmpty {
                KeychainHelper.savePassword(conn.password, forConnectionID: conn.id)
                changed = true
            }
        }
        if changed {
            saveConnections()
        }
    }

    func addConnection(_ connection: SMBConnection) {
        if !connection.password.isEmpty {
            KeychainHelper.savePassword(connection.password, forConnectionID: connection.id)
        }
        connections.append(connection)
        saveConnections()
    }

    func updateConnection(_ connection: SMBConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let oldPassword = connections[index].password
        connections[index] = connection
        if connection.password.isEmpty {
            KeychainHelper.deletePassword(forConnectionID: connection.id)
        } else if connection.password != oldPassword {
            KeychainHelper.savePassword(connection.password, forConnectionID: connection.id)
        }
        saveConnections()
    }

    func deleteConnection(_ id: UUID) {
        KeychainHelper.deletePassword(forConnectionID: id)
        connections.removeAll { $0.id == id }
        if autoMountUUIDs.remove(id) != nil {
            saveAutoMount()
        }
        saveConnections()
    }

    // MARK: - 活跃挂载

    func loadActiveMounts() {
        guard let url = activeMountsFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let uuids = try JSONDecoder().decode([UUID].self, from: data)
            activeVolumeUUIDs = Set(uuids)
            for i in connections.indices {
                connections[i].isMounted = activeVolumeUUIDs.contains(connections[i].id)
            }
        } catch {
            activeVolumeUUIDs = []
        }
    }

    func saveActiveMounts() {
        guard let url = activeMountsFileURL else { return }
        do {
            let data = try JSONEncoder().encode(Array(activeVolumeUUIDs))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save active mounts: \(error)")
        }
    }

    func markMounted(_ connectionID: UUID) {
        activeVolumeUUIDs.insert(connectionID)
        saveActiveMounts()
        // 成功挂载意味着用户希望在登录时恢复它。
        autoMountUUIDs.insert(connectionID)
        saveAutoMount()
        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].isMounted = true
            saveConnections()
        }
    }

    func markUnmounted(_ connectionID: UUID) {
        activeVolumeUUIDs.remove(connectionID)
        saveActiveMounts()
        // 显式卸载意味着用户不再希望自动挂载它。
        autoMountUUIDs.remove(connectionID)
        saveAutoMount()
        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].isMounted = false
            saveConnections()
        }
    }

    // MARK: - 自动挂载（登录恢复）

    func loadAutoMount() {
        guard let url = autoMountFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            autoMountUUIDs = Set(try JSONDecoder().decode([UUID].self, from: data))
        } catch {
            autoMountUUIDs = []
        }
    }

    func saveAutoMount() {
        guard let url = autoMountFileURL else { return }
        do {
            let data = try JSONEncoder().encode(Array(autoMountUUIDs))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save auto mounts: \(error)")
        }
    }

    /// 对照系统挂载表校验每条标记为“已挂载”的连接，
    /// 并清除卷已被外部卸载的陈旧条目。
    /// 不会修改 `autoMountUUIDs`，因此 Finder 外部卸载后仍可在下次登录时自动恢复。
    @discardableResult
    func reconcileMountStateWithSystem() -> Bool {
        let mountOutput = Self.runMountList()
        var changed = false

        for i in self.connections.indices {
            guard self.connections[i].isMounted else { continue }
            guard let mountPoint = Self.mountPointPath(for: self.connections[i]) else { continue }
            if !Self.isMountPointPresent(mountPoint, in: mountOutput) {
                self.connections[i].isMounted = false
                self.activeVolumeUUIDs.remove(self.connections[i].id)
                changed = true
                self.logger.debug("Stale mount cleaned: \(self.connections[i].displayName) not in mount table")
            }
        }

        if changed {
            saveConnections()
            saveActiveMounts()
        }
        return changed
    }

    /// 监听系统挂载变化，并在 App 重新激活时同步状态。
    func startMountStateMonitoring() {
        guard mountStateMonitorTask == nil else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reconcileMountStateWithSystem()
            }
            workspaceObservers.append(token)
        }

        let activeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileMountStateWithSystem()
        }
        appObservers.append(activeToken)

        // 轮询作为兜底：部分 FSKit 卸载路径可能不会及时投递 workspace 通知。
        mountStateMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.reconcileMountStateWithSystem()
            }
        }
    }

    static func mountPointPath(for connection: SMBConnection) -> String? {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = appSupport.appendingPathComponent(bundleID)
        return appDir
            .appendingPathComponent(connection.displayName.trimmingCharacters(in: .whitespaces))
            .path
    }

    private static func isMountPointPresent(_ mountPoint: String, in mountOutput: String) -> Bool {
        let marker = " on \(mountPoint) "
        return mountOutput.contains(marker)
    }

    private static func runMountList() -> String {
        let task = Process()
        task.launchPath = "/sbin/mount"
        task.arguments = []
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - 挂载 Source 配置

    /// 扩展在挂载 source 目录内读取的文件名。
    static let mountConfigFileName = "mount-config.json"

    /// App 拥有的基础目录，每个连接对应一个子目录。
    /// 每个子目录用作 `mount` 的 *source* 参数；FSKit 会把它作为
    /// 带安全作用域的 `FSPathURLResource` 交给扩展。
    ///
    /// 这里故意不使用 App Group 容器：FSKit 扩展沙盒不暴露它，
    /// 因此扩展无法从那里读取配置。
    private var mountSourcesBaseURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        return appSupport?
            .appendingPathComponent(bundleID)
            .appendingPathComponent("mount-sources")
    }

    /// 某个连接的挂载 source 目录。
    func mountSourceDirectory(for connectionID: UUID) -> URL? {
        mountSourcesBaseURL?.appendingPathComponent(connectionID.uuidString)
    }

    /// 把连接配置写入它自己的挂载 source 目录，并返回该目录，
    /// 供作为 `mount` 的 source 参数传入。
    /// 每个连接都有独立目录，因此同时挂载不同连接时不会互相覆盖配置。
    func writeMountConfig(for connectionID: UUID) -> URL? {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              let sourceDir = mountSourceDirectory(for: connectionID)
        else { return nil }

        let config: [String: String] = [
            "connectionID": connection.id.uuidString,
            "serverURL": connection.serverURL,
            "shareName": connection.shareName,
            "startingPath": connection.startingPath,
            "username": connection.username,
            "password": connection.password,
            "displayName": connection.displayName,
            "localUID": "\(getuid())",
            "localGID": "\(getgid())"
        ]

        do {
            let fm = FileManager.default
            // 将基础目录和每连接目录锁定为仅所有者可访问（0700）。
            if let baseURL = mountSourcesBaseURL {
                try fm.createDirectory(at: baseURL, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseURL.path)
            }
            try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceDir.path)

            let configURL = sourceDir.appendingPathComponent(Self.mountConfigFileName)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configURL, options: .atomic)
            // 明文凭据只在该挂载窗口内落盘；将文件设为仅所有者可读写（0600）。
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return sourceDir
        } catch {
            logger.error("Failed to write mount config: \(error)")
            return nil
        }
    }

    /// 只删除明文的 `mount-config.json`（保留 source 目录，
    /// 让挂载的 source 路径继续有效）。在挂载成功后立即调用：
    /// 扩展已在 `loadResource` 中把配置读入内存，凭据不再需要留在磁盘上。
    func removeMountConfigFile(for connectionID: UUID) {
        guard let sourceDir = mountSourceDirectory(for: connectionID) else { return }
        let configURL = sourceDir.appendingPathComponent(Self.mountConfigFileName)
        try? FileManager.default.removeItem(at: configURL)
    }

    /// 完全移除某个连接的挂载 source 目录（用于卸载和挂载失败时）。
    func clearMountConfig(for connectionID: UUID) {
        guard let sourceDir = mountSourceDirectory(for: connectionID) else { return }
        try? FileManager.default.removeItem(at: sourceDir)
    }

}
