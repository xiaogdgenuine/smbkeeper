/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
SMB 存储门面（facade）；通过异步的 ``SMB2DirectClient`` 直接使用 libsmb2。
*/

import Foundation
import OSLog

/// 面向 FSKit 的 SMB API，构建在 libsmb2 之上（而非 AMSMB2）。
final class SMBBackend: @unchecked Sendable {

    private let client: SMB2DirectClient
    let config: SMBConfiguration

    init(config: SMBConfiguration) {
        self.config = config
        self.client = SMB2DirectClient(config: config)
    }

    /// 建立初始连接。必须 await 完成后才能开始处理 I/O。
    func connect() async throws {
        try await client.connect()
    }

    func disconnect() {
        client.disconnect()
    }

    /// 网络变化/系统唤醒时调用：解除重连熔断，并中止可能卡在旧路由上的在途 connect。
    func handleNetworkChange() {
        client.handleNetworkChange()
    }

    @discardableResult
    func reconnect() async -> Bool {
        await client.reconnect()
    }

    func isConnectionLost(_ error: Error) -> Bool {
        client.isConnectionLost(error)
    }

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: any Sendable] {
        try await client.attributesOfItem(atPath: path)
    }

    func attributesOfFileSystem(forPath path: String = "") async throws -> [FileAttributeKey: any Sendable] {
        try await client.attributesOfFileSystem(forPath: path)
    }

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: any Sendable]] {
        try await client.contentsOfDirectory(atPath: path)
    }

    func setAttributes(_ attributes: [URLResourceKey: Any], atPath path: String) async throws {
        try await client.setAttributes(attributes, atPath: path)
    }

    func truncateFile(atPath path: String, atOffset: UInt64) async throws {
        try await client.truncateFile(atPath: path, atOffset: atOffset)
    }

    func createDirectory(atPath path: String) async throws {
        try await client.createDirectory(atPath: path)
    }

    func createEmptyFile(atPath path: String) async throws {
        try await client.createEmptyFile(atPath: path)
    }

    func removeItem(atPath path: String) async throws {
        try await client.removeItem(atPath: path)
    }

    func moveItem(atPath path: String, toPath: String) async throws {
        try await client.moveItem(atPath: path, toPath: toPath)
    }

    func destinationOfSymbolicLink(atPath path: String) async throws -> String {
        try await client.destinationOfSymbolicLink(atPath: path)
    }

    func createSymbolicLink(atPath path: String, withDestinationPath destination: String) async throws {
        try await client.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await client.read(path: path, offset: offset, length: length)
    }

    func closeHandle(forPath path: String) {
        client.closeHandle(forPath: path)
    }

    func flushAll() async throws {
        try await client.flushAll()
    }

    func write(path: String, data: Data, offset: UInt64) async throws -> Int {
        try await client.write(path: path, data: data, offset: offset)
    }
}
