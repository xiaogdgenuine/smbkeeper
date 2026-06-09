/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Manages SMB connection configurations stored in the shared App Group container.
*/

import Foundation
import OSLog

/// Manages reading and writing SMB connection configs to the shared App Group container.
@MainActor
class SMBConnectionManager: ObservableObject {
    @Published var connections: [SMBConnection] = []
    @Published var activeVolumeUUIDs: Set<UUID> = []

    /// Connections the user wants restored at login. Unlike `activeVolumeUUIDs`,
    /// this set is NOT cleared by `reconcileMountStateWithSystem()`, so it
    /// survives a reboot (when nothing is mounted yet) and drives auto-mount.
    @Published var autoMountUUIDs: Set<UUID> = []

    private let logger = Logger(subsystem: "com.example.smbkeep.manager", category: "SMBConnectionManager")

    static let connectionsFileName = "smb_connections.json"
    static let activeMountsFileName = "active_mounts.json"
    static let autoMountFileName = "auto_mount.json"

    var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SMBConnection.appGroupIdentifier)
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
    }

    // MARK: - Connection Persistence

    func loadConnections() {
        guard let url = connectionsFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([SMBConnection].self, from: data)
            connections = decoded
            restorePasswordsFromKeychain()
            logger.info("Loaded \(decoded.count) connection(s)")
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
            logger.info("Saved \(connections.count) connection(s)")
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

    // MARK: - Active Mounts

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
        // A successful mount means the user wants this restored at login.
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
        // An explicit unmount means the user no longer wants it auto-mounted.
        autoMountUUIDs.remove(connectionID)
        saveAutoMount()
        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].isMounted = false
            saveConnections()
        }
    }

    // MARK: - Auto Mount (login restore)

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

    /// Verify each "mounted" connection against the system mount table and
    /// clear any stale entries where the volume has been unmounted externally.
    func reconcileMountStateWithSystem() {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appDir = appSupport?.appendingPathComponent(bundleID) else { return }

        let mountOutput = Self.runMountList()
        var changed = false

        for i in self.connections.indices {
            guard self.connections[i].isMounted else { continue }
            let mountPoint = appDir
                .appendingPathComponent(self.connections[i].displayName.trimmingCharacters(in: .whitespaces))
                .path
            let marker = " on \(mountPoint) "
            if !mountOutput.contains(marker) {
                self.connections[i].isMounted = false
                self.activeVolumeUUIDs.remove(self.connections[i].id)
                changed = true
                self.logger.info("Stale mount cleaned: \(self.connections[i].displayName) not in mount table")
            }
        }

        if changed {
            saveConnections()
            saveActiveMounts()
        }
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

    // MARK: - Mount Source Config

    /// File name the extension reads inside the mount source directory.
    static let mountConfigFileName = "mount-config.json"

    /// Base directory (app-owned) that holds one subdirectory per connection.
    /// Each subdirectory is used as the `mount` *source* argument; FSKit delivers
    /// it to the extension as a security-scoped `FSPathURLResource`.
    ///
    /// The App Group container is intentionally NOT used here: FSKit extension
    /// sandboxes don't expose it, so the extension can't read config from there.
    private var mountSourcesBaseURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        return appSupport?
            .appendingPathComponent(bundleID)
            .appendingPathComponent("mount-sources")
    }

    /// The per-connection mount source directory.
    func mountSourceDirectory(for connectionID: UUID) -> URL? {
        mountSourcesBaseURL?.appendingPathComponent(connectionID.uuidString)
    }

    /// Write the connection's config into its own mount source directory and
    /// return that directory, to be passed as the `mount` source argument.
    /// Each connection gets a distinct directory, so simultaneous mounts of
    /// different connections never overwrite each other's config.
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
            "operationTimeout": "\(connection.operationTimeout)",
            "displayName": connection.displayName,
            "localUID": "\(getuid())",
            "localGID": "\(getgid())"
        ]

        do {
            let fm = FileManager.default
            // Lock down the base and per-connection directories to owner-only (0700).
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
            // Plaintext credentials live here only during the mount window; make
            // the file owner read/write only (0600).
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return sourceDir
        } catch {
            logger.error("Failed to write mount config: \(error)")
            return nil
        }
    }

    /// Delete just the plaintext `mount-config.json` (keep the source directory
    /// so the mount's source path stays valid). Call this right after a mount
    /// succeeds: the extension has already read the config into memory in
    /// `loadResource`, so the credentials no longer need to be on disk.
    func removeMountConfigFile(for connectionID: UUID) {
        guard let sourceDir = mountSourceDirectory(for: connectionID) else { return }
        let configURL = sourceDir.appendingPathComponent(Self.mountConfigFileName)
        try? FileManager.default.removeItem(at: configURL)
    }

    /// Remove a connection's mount source directory entirely (used on unmount
    /// and on mount failure).
    func clearMountConfig(for connectionID: UUID) {
        guard let sourceDir = mountSourceDirectory(for: connectionID) else { return }
        try? FileManager.default.removeItem(at: sourceDir)
    }

}
