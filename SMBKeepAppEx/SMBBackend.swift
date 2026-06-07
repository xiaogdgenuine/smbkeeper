/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
SMB storage facade; uses libsmb2 directly via ``SMB2DirectClient``.
*/

import Foundation
import OSLog

/// FSKit-facing SMB API implemented on top of libsmb2 (not AMSMB2).
final class SMBBackend: @unchecked Sendable {

    private let client: SMB2DirectClient
    let config: SMBConfiguration

    init(config: SMBConfiguration) throws {
        self.config = config
        self.client = try SMB2DirectClient(config: config)
    }

    func disconnect() {
        client.disconnect()
    }

    @discardableResult
    func reconnect() -> Bool {
        client.reconnect()
    }

    func isConnectionLost(_ error: Error) -> Bool {
        client.isConnectionLost(error)
    }

    func attributesOfItem(atPath path: String) throws -> [URLResourceKey: any Sendable] {
        try client.attributesOfItem(atPath: path)
    }

    func attributesOfFileSystem(forPath path: String = "") throws -> [FileAttributeKey: any Sendable] {
        try client.attributesOfFileSystem(forPath: path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [[URLResourceKey: any Sendable]] {
        try client.contentsOfDirectory(atPath: path)
    }

    func setAttributes(_ attributes: [URLResourceKey: Any], atPath path: String) throws {
        try client.setAttributes(attributes, atPath: path)
    }

    func truncateFile(atPath path: String, atOffset: UInt64) throws {
        try client.truncateFile(atPath: path, atOffset: atOffset)
    }

    func createDirectory(atPath path: String) throws {
        try client.createDirectory(atPath: path)
    }

    func createEmptyFile(atPath path: String) throws {
        try client.createEmptyFile(atPath: path)
    }

    func removeItem(atPath path: String) throws {
        try client.removeItem(atPath: path)
    }

    func moveItem(atPath path: String, toPath: String) throws {
        try client.moveItem(atPath: path, toPath: toPath)
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try client.destinationOfSymbolicLink(atPath: path)
    }

    func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
        try client.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    func read(path: String, offset: UInt64, length: Int) throws -> Data {
        try client.read(path: path, offset: offset, length: length)
    }

    func closeHandle(forPath path: String) {
        client.closeHandle(forPath: path)
    }

    func flushAll() throws {
        try client.flushAll()
    }

    func write(path: String, data: Data, offset: UInt64) throws -> Int {
        try client.write(path: path, data: data, offset: offset)
    }
}
