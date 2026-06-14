/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
定义透传文件系统所用的自定义卷的类。
*/

import Foundation
import ExtensionFoundation
import FSKit
import IOKit
import IOKit.pwr_mgt
import OSLog
import SystemConfiguration

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// SMBKeepFSVolume 表示一个以 SMB 共享为后端的卷。
class SMBKeepFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    var rootItem: SMBKeepFSItem
    var itemCache: [UInt64: SMBKeepFSItem]
    var itemCacheQueue: DispatchQueue

    var enumerationCache: [UInt64: SMBKeepDirectorySnapshot] = [:]
    var enumerationCacheGeneration: UInt64 = 0
    let enumerationCacheLock = NSLock()

    /// 最近一次已知的文件系统统计信息，在后台刷新。`volumeStatistics` 是 FSKit 的同步属性，
    /// 因此它返回这个缓存值（由 `itemCacheQueue` 保护），而不是阻塞等待一次 SMB 往返。
    var cachedFSAttrs: [FileAttributeKey: any Sendable]?

    /// 名称 → item，对应某个目录 inode 下最近一次枚举出的子项（避免 readdir 之后再做 N 次 stat RPC）。
    var directoryLookupCache: [UInt64: [String: SMBKeepFSItem]] = [:]
    let directoryLookupCacheLock = NSLock()

    /// 缓存的属性 / 目录列表在重新向服务器拉取前保持有效的时长，让外部变更得以可见。
    /// 在限制陈旧度的同时保持每次 readdir 分页的速度（类似 NFS 的属性缓存）。
    let attributeCacheTTL: TimeInterval = 2
    let directoryCacheTTL: TimeInterval = 2

    let smb: SMBBackend
    let volumeLabel: String
    let connectionID: String
    let logger: Logger

    /// 创建此卷所用的 SMB 配置。
    let smbConfig: SMBConfiguration

    /// 仅本地的访达元数据 xattr 存储（标签、注释、“打开方式”），
    /// 这样它们绝不会被写回远端 SMB 共享。
    // let localXattrStore: SMBKeepLocalXattrStore

    private var sleepWakeMonitor: SleepWakeMonitor?
    private var networkMonitor: SystemNetworkMonitor?

    init(backend: SMBBackend, volumeName: FSFileName, smbConfig: SMBConfiguration) throws {
        self.smb = backend
        self.smbConfig = smbConfig
        self.connectionID = smbConfig.connectionID
        self.volumeLabel = volumeName.string ?? smbConfig.displayName
        self.logger = Logger(subsystem: "com.apple.fskit.SMBKeepFS", category: smbConfig.connectionID)
        // self.localXattrStore = SMBKeepLocalXattrStore(connectionID: smbConfig.connectionID)

        let startingPath = smbConfig.startingPath
        let rootInode = SMBAttributeMapping.inodeForPath(startingPath)
        self.rootItem = SMBKeepFSItem(name: ".", smbPath: startingPath, type: .directory, openFlags: .readOnly, inode: rootInode)
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.itemcache.queue")
        // 派生一个稳定的、每连接独立的卷 ID，让多个连接可以同时挂载而不共用同一个标识符。
        let volumeUUID = UUID(uuidString: smbConfig.connectionID) ?? UUID()
        super.init(volumeID: FSVolume.Identifier(uuid: volumeUUID), volumeName: volumeName)
        self.logger.info("\(#function): Created SMB volume \(self.name)")
        self.log("Volume initialized: \(smbConfig.displayName)")

        self.sleepWakeMonitor = SleepWakeMonitor(logger: self.logger) { [weak self] in
            self?.handleSystemDidWake()
        }
        self.networkMonitor = SystemNetworkMonitor(logger: self.logger) { [weak self] in
            Task { await self?.reconnectAndClearCaches(reason: "network change") }
        }
    }

    // MARK: - 日志

    /// 向统一日志系统写入一条运行时日志（宿主 App 会实时读取）。
    func log(_ message: String) {
        self.logger.info("[FSVolume] \(message)")
    }

    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(name, nil)
    }

    public func preallocateSpace(for item: FSItem,
                                 at offset: off_t,
                                 length: Int,
                                 flags: FSVolume.PreallocateFlags,
                                 replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(0, POSIXError(.EINVAL))
        }
        let snapshot = ptItem.stateSnapshot()
        guard snapshot.itemType == .file else {
            return replyHandler(0, POSIXError(.EPERM))
        }

        Task {
            var recoveredOnce = false
            while true {
                do {
                    let target = UInt64(offset) + UInt64(length)
                    try await self.smb.truncateFile(atPath: snapshot.smbPath, atOffset: target)
                    return replyHandler(length, nil)
                } catch {
                    if !recoveredOnce, await self.recoverFromConnectionLoss(error) {
                        recoveredOnce = true
                        continue
                    }
                    return replyHandler(0, error)
                }
            }
        }
    }

    public func read(from item: FSItem,
                     at offset: off_t,
                     length: Int,
                     into buffer: FSMutableFileDataBuffer,
                     replyHandler: @escaping (Int, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(0, POSIXError(.EINVAL))
        }

        Task {
            var recoveredOnce = false
            while true {
                do {
                    let snapshot = ptItem.stateSnapshot()
                    let data = try await self.smb.read(path: snapshot.smbPath, offset: UInt64(offset), length: length)
                    let copyLen = min(data.count, length)
                    buffer.withUnsafeMutableBytes { raw in
                        data.copyBytes(to: raw.bindMemory(to: UInt8.self).baseAddress!, count: copyLen)
                    }
                    return replyHandler(copyLen, nil)
                } catch {
                    if !recoveredOnce, await self.recoverFromConnectionLoss(error) {
                        recoveredOnce = true
                        self.log("Read recovered after reconnect: \(ptItem.smbPath)")
                        continue
                    }
                    let path = ptItem.smbPath
                    self.log("Read failed: \(path) error=\(error)")
                    self.logger.error("\(#function): read \(path) failed: \(error)")
                    return replyHandler(0, error)
                }
            }
        }
    }

    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(0, POSIXError(.EINVAL))
        }
        let snapshot = ptItem.stateSnapshot()
        guard snapshot.itemType != .directory else {
            return replyHandler(0, POSIXError(.EISDIR))
        }

        Task {
            var recoveredOnce = false
            while true {
                do {
                    let written = try await self.smb.write(path: snapshot.smbPath, data: contents, offset: UInt64(offset))
                    return replyHandler(written, nil)
                } catch {
                    if !recoveredOnce, await self.recoverFromConnectionLoss(error) {
                        recoveredOnce = true
                        continue
                    }
                    return replyHandler(0, error)
                }
            }
        }
    }

    public func openItem(_ item: FSItem,
                         modes: FSVolume.OpenModes,
                         replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            return replyHandler(nil)
        }

        var ptfsMode: SMBKeepFSItemOpenMode = .readOnly
        if modes.contains(.write) {
            ptfsMode = .readWrite
        }
        do {
            try ptItem.upgradeOpenMode(mode: ptfsMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            return replyHandler(nil)
        }
        // 既然文件正在关闭，就释放缓存的 SMB 句柄；对可写句柄而言，这同时会把挂起的写刷到服务器。
        let snapshot = ptItem.stateSnapshot()
        if snapshot.itemType == .file {
            self.smb.closeHandle(forPath: snapshot.smbPath)
        }
        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    public var maximumLinkCount: Int { 64_000 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { false }
    public var truncatesLongNames: Bool { false }
    public var maximumFileSizeInBits: Int { 64 }
    public var maximumXattrSizeInBits: Int { 16 }

    func isConnectionLost(_ error: Error) -> Bool {
        smb.isConnectionLost(error)
    }

    @discardableResult
    func recoverFromConnectionLoss(_ error: Error, reopening item: SMBKeepFSItem? = nil,
                                   mode: SMBKeepFSItemOpenMode = .readOnly) async -> Bool {
        guard self.isConnectionLost(error) else { return false }
        self.log("Connection lost: \(error.localizedDescription) - attempting reconnect...")
        // `reconnect()` 会把并发的调用方合并到同一次尝试上，因此这里不需要卷级别的锁。
        guard await self.smb.reconnect() else {
            self.log("Reconnect FAILED")
            return false
        }
        self.log("Reconnect succeeded, clearing caches")

        self.clearAllDirectoryCaches()

        guard let item, item !== self.rootItem else { return true }
        do {
            try item.forceReopen(mode: mode)
        } catch {
            let name = item.name
            self.logger.error("\(#function): Failed to reopen \(name): \(error)")
            self.log("Failed to reopen \(name): \(error)")
            return false
        }
        return true
    }

    func clearAllDirectoryCaches() {
        self.enumerationCacheLock.lock()
        self.enumerationCache.removeAll(keepingCapacity: true)
        self.enumerationCacheLock.unlock()
        self.directoryLookupCacheLock.lock()
        self.directoryLookupCache.removeAll(keepingCapacity: true)
        self.directoryLookupCacheLock.unlock()
    }

    func invalidateEnumerationCache(forInode inode: UInt64) {
        guard inode != 0 else { return }
        self.enumerationCacheLock.lock()
        self.enumerationCache.removeValue(forKey: inode)
        self.enumerationCacheLock.unlock()
        self.directoryLookupCacheLock.lock()
        self.directoryLookupCache.removeValue(forKey: inode)
        self.directoryLookupCacheLock.unlock()
    }

    /// 登记枚举出的子项，让后续的 `lookupItem` 调用免去额外的 SMB 往返。
    func registerEnumeratedChildren(_ entries: [SMBKeepDirEntry], in parent: SMBKeepFSItem) {
        var byName: [String: SMBKeepFSItem] = [:]
        byName.reserveCapacity(entries.count)
        let parentSnapshot = parent.stateSnapshot()
        self.itemCacheQueue.sync {
            for entry in entries {
                let childPath = parentSnapshot.smbPath.appendingSMBComponent(entry.name)
                let item = SMBKeepFSItem(name: entry.name, parent: parent, smbPath: childPath,
                                             type: entry.itemType, inode: entry.itemID, cachedRaw: entry.raw)
                byName[entry.name] = item
                self.itemCache[entry.itemID] = item
            }
        }
        self.directoryLookupCacheLock.lock()
        self.directoryLookupCache[parentSnapshot.inode] = byName
        self.directoryLookupCacheLock.unlock()
    }

    func cachedChild(named name: String, in parent: SMBKeepFSItem) -> SMBKeepFSItem? {
        let parentInode = parent.inode
        self.directoryLookupCacheLock.lock()
        let item = self.directoryLookupCache[parentInode]?[name]
        self.directoryLookupCacheLock.unlock()
        return item
    }

    private func handleSystemDidWake() {
        Task { await self.reconnectAndClearCaches(reason: "wake") }
    }

    /// 重建 SMB 连接并清除陈旧缓存，失败时按退避策略重试。
    private func reconnectAndClearCaches(reason: String, attempt: Int = 0) async {
        if await self.smb.reconnect() {
            self.clearAllDirectoryCaches()
            self.logger.info("\(#function): Reconnected SMB after \(reason) (attempt \(attempt))")
            return
        }

        let maxAttempts = 5
        guard attempt < maxAttempts else {
            self.logger.error("\(#function): Couldn't reconnect SMB after \(reason)")
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
        await self.reconnectAndClearCaches(reason: reason, attempt: attempt + 1)
    }
}

private func systemNetworkStoreCallback(
    store: SCDynamicStore?,
    changedKeys: CFArray?,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<SystemNetworkMonitor>.fromOpaque(info).takeUnretainedValue().handleStoreChange()
}

/// 每当活动网络发生变化（切换 Wi-Fi、获得新 IP 等）就触发 `onChange`。
///
/// 通过 ``SCDynamicStore`` 监视主 IPv4 路由以及各网卡的 Wi-Fi 关联状态，
/// 即便是在同一网卡上切换不同 Wi-Fi 网络也能及时响应。我们不去区分“已连接”与“已断开”——
/// 任何变化都只是触发一次重连 + 缓存刷新。
final class SystemNetworkMonitor {
    private var store: SCDynamicStore?
    private let queue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.network.queue")
    private let onChange: () -> Void
    private let logger: Logger
    private var lastSnapshot: String?

    init(logger: Logger, onChange: @escaping () -> Void) {
        self.logger = logger
        self.onChange = onChange
        self.queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    private func startOnQueue() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "com.apple.fskit.smbkeepfs.network" as CFString,
            systemNetworkStoreCallback,
            &context
        ) else {
            self.logger.error("\(#function): SCDynamicStoreCreate failed")
            return
        }
        self.store = store

        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = [
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/AirPort",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        self.lastSnapshot = Self.captureSnapshot(from: store)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            self.logger.error("\(#function): SCDynamicStoreCreateRunLoopSource failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        self.logger.info("\(#function): System network monitor active (SCDynamicStore)")
        CFRunLoopRun()
    }

    fileprivate func handleStoreChange() {
        guard let store else { return }
        let snapshot = Self.captureSnapshot(from: store)
        defer { self.lastSnapshot = snapshot }
        guard self.lastSnapshot != snapshot else { return }
        self.logger.info("\(#function): Network configuration changed")
        self.onChange()
    }

    private static func captureSnapshot(from store: SCDynamicStore) -> String {
        var parts: [String] = []

        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            parts.append("pri=\(global["PrimaryInterface"] ?? "")")
            parts.append("router=\(global["Router"] ?? "")")
        }

        if let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/.*/IPv4" as CFString) as? [String] {
            for key in keys.sorted() {
                guard let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
                parts.append("\(key)=\(ipv4["Addresses"] ?? "")")
            }
        }

        if let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/.*/AirPort" as CFString) as? [String] {
            for key in keys.sorted() {
                guard let airport = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
                parts.append("\(key)=\(airport["SSID"] ?? "")/\(airport["BSSID"] ?? "")")
            }
        }

        return parts.joined(separator: "|")
    }

    deinit {
        self.queue.async {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

/// 监听系统睡眠/唤醒切换，并在机器唤醒时调用回调。
final class SleepWakeMonitor {
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: () -> Void
    private let logger: Logger
    private let queue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.sleepwake.queue")
    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?

    init?(logger: Logger, onWake: @escaping () -> Void) {
        self.logger = logger
        self.onWake = onWake
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0
        var port: IONotificationPortRef?
        let connect = IORegisterForSystemPower(context, &port, { (refcon, _, messageType, messageArgument) in
            guard let refcon else { return }
            let monitor = Unmanaged<SleepWakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(messageType: messageType, messageArgument: messageArgument)
        }, &notifier)

        guard connect != 0, let port else {
            self.logger.error("\(#function): IORegisterForSystemPower failed")
            return nil
        }
        self.rootPort = connect
        self.notifierObject = notifier
        self.notificationPort = port
        IONotificationPortSetDispatchQueue(port, self.queue)
        self.logger.info("\(#function): Sleep/wake monitor active")
    }

    private func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.messageCanSystemSleep, Self.messageSystemWillSleep:
            IOAllowPowerChange(self.rootPort, Int(bitPattern: messageArgument))
        case Self.messageSystemHasPoweredOn:
            self.onWake()
        default:
            break
        }
    }

    deinit {
        guard let notificationPort else { return }
        IONotificationPortSetDispatchQueue(notificationPort, nil)
        IODeregisterForSystemPower(&self.notifierObject)
        IOServiceClose(self.rootPort)
        IONotificationPortDestroy(notificationPort)
    }
}
