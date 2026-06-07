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

    private let logger = Logger(subsystem: "com.example.smbkeep.manager", category: "SMBConnectionManager")

    static let connectionsFileName = "smb_connections.json"
    static let activeMountsFileName = "active_mounts.json"

    var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SMBConnection.appGroupIdentifier)
    }

    var connectionsFileURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.connectionsFileName)
    }

    var activeMountsFileURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.activeMountsFileName)
    }

    init() {
        loadConnections()
        loadActiveMounts()
    }

    // MARK: - Connection Persistence

    func loadConnections() {
        guard let url = connectionsFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([SMBConnection].self, from: data)
            connections = decoded
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

    func addConnection(_ connection: SMBConnection) {
        connections.append(connection)
        saveConnections()
    }

    func updateConnection(_ connection: SMBConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        saveConnections()
    }

    func deleteConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        saveConnections()
    }

    // MARK: - Active Mounts

    func loadActiveMounts() {
        guard let url = activeMountsFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let uuids = try JSONDecoder().decode([UUID].self, from: data)
            activeVolumeUUIDs = Set(uuids)
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
        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].isMounted = true
            saveConnections()
        }
    }

    func markUnmounted(_ connectionID: UUID) {
        activeVolumeUUIDs.remove(connectionID)
        saveActiveMounts()
        if let index = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[index].isMounted = false
            saveConnections()
        }
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
