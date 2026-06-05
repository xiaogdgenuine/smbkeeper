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

    private let logger = Logger(subsystem: "com.example.passthrough.manager", category: "SMBConnectionManager")

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

    var logsDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent("logs", isDirectory: true)
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
            // No saved configs yet — start with a default from existing hardcoded config.
            if connections.isEmpty {
                connections = [
                    SMBConnection(
                        displayName: "默认共享",
                        serverURL: "smb://192.168.1.4",
                        shareName: "2T",
                        username: "test",
                        password: "1Ailovetest"
                    )
                ]
            }
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

    /// Get the active connection config for the extension to read.
    /// Writes a single "active.json" that the extension picks up on loadResource.
    func writeActiveConfig(for connectionID: UUID) -> Bool {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              let configURL = sharedContainerURL?.appendingPathComponent("active_config.json")
        else { return false }

        let config: [String: String] = [
            "connectionID": connection.id.uuidString,
            "serverURL": connection.serverURL,
            "shareName": connection.shareName,
            "username": connection.username,
            "password": connection.password,
            "operationTimeout": "\(connection.operationTimeout)",
            "displayName": connection.displayName
        ]

        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            logger.error("Failed to write active config: \(error)")
            return false
        }
    }

    /// Clear the active config (used on unmount).
    func clearActiveConfig() {
        guard let configURL = sharedContainerURL?.appendingPathComponent("active_config.json") else { return }
        try? FileManager.default.removeItem(at: configURL)
    }

    // MARK: - Logging Support

    /// Returns the log file URL for a given connection.
    func logFileURL(for connectionID: UUID) -> URL? {
        logsDirectoryURL?.appendingPathComponent("\(connectionID.uuidString).log")
    }

    /// Read log contents for a connection.
    func readLog(for connectionID: UUID) -> String {
        guard let url = logFileURL(for: connectionID) else { return "No log file available." }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "Log not available yet."
        }
    }
}
