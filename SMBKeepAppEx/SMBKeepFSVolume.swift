/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class defines a custom volume for use by the passthrough file system.
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

/// A SMBKeepFSVolume represents a volume backed by an SMB share.
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

    /// Name → item for children last enumerated under a directory inode (avoids N stat RPCs after readdir).
    var directoryLookupCache: [UInt64: [String: SMBKeepFSItem]] = [:]
    let directoryLookupCacheLock = NSLock()

    /// How long cached attributes / directory listings stay valid before being
    /// re-fetched from the server, so external changes become visible. Keeps the
    /// per-readdir pagination fast while bounding staleness (NFS-style attr cache).
    let attributeCacheTTL: TimeInterval = 2
    let directoryCacheTTL: TimeInterval = 2

    let smb: SMBBackend
    let volumeLabel: String
    let connectionID: String
    let logger: Logger

    /// The SMB config used to create this volume.
    let smbConfig: SMBConfiguration

    /// Local-only store for Finder metadata xattrs (tags, comment, "open with"),
    /// so they never get written back to the remote SMB share.
    // let localXattrStore: SMBKeepLocalXattrStore

    private var sleepWakeMonitor: SleepWakeMonitor?
    private var networkMonitor: SystemNetworkMonitor?
    private let wakeQueue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.wake.queue")
    private let reconnectLock = NSLock()

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
        // Derive a stable, per-connection volume ID so multiple connections can be
        // mounted at the same time without sharing one identifier.
        let volumeUUID = UUID(uuidString: smbConfig.connectionID) ?? UUID()
        super.init(volumeID: FSVolume.Identifier(uuid: volumeUUID), volumeName: volumeName)
        self.logger.info("\(#function): Created SMB volume \(self.name)")
        self.log("Volume initialized: \(smbConfig.displayName)")

        self.sleepWakeMonitor = SleepWakeMonitor(logger: self.logger) { [weak self] in
            self?.handleSystemDidWake()
        }
        self.networkMonitor = SystemNetworkMonitor(logger: self.logger) { [weak self] in
            self?.reconnectAndClearCaches(reason: "network change")
        }
    }

    // MARK: - Logging

    /// Emit a runtime log entry to the unified logging system (read live by the host app).
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
        guard ptItem.itemType == .file else {
            return replyHandler(0, POSIXError(.EPERM))
        }

        var recoveredOnce = false
        while true {
            do {
                let target = UInt64(offset) + UInt64(length)
                try self.smb.truncateFile(atPath: ptItem.smbPath, atOffset: target)
                return replyHandler(length, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(0, error)
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

        var recoveredOnce = false
        while true {
            do {
                let data = try self.smb.read(path: ptItem.smbPath, offset: UInt64(offset), length: length)
                let copyLen = min(data.count, length)
                buffer.withUnsafeMutableBytes { raw in
                    data.copyBytes(to: raw.bindMemory(to: UInt8.self).baseAddress!, count: copyLen)
                }
                return replyHandler(copyLen, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error) {
                    recoveredOnce = true
                    self.log("Read recovered after reconnect: \(ptItem.smbPath)")
                    continue
                }
                self.log("Read failed: \(ptItem.smbPath) error=\(error)")
                self.logger.error("\(#function): read \(ptItem.smbPath) failed: \(error)")
                return replyHandler(0, error)
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
        guard ptItem.itemType != .directory else {
            return replyHandler(0, POSIXError(.EISDIR))
        }

        var recoveredOnce = false
        while true {
            do {
                let written = try self.smb.write(path: ptItem.smbPath, data: contents, offset: UInt64(offset))
                return replyHandler(written, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(0, error)
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
        // Release the cached SMB handle now that this file is being closed; for a
        // writable handle this also flushes pending writes to the server.
        if ptItem.itemType == .file {
            self.smb.closeHandle(forPath: ptItem.smbPath)
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
                                   mode: SMBKeepFSItemOpenMode = .readOnly) -> Bool {
        guard self.isConnectionLost(error) else { return false }
        self.log("Connection lost: \(error.localizedDescription) - attempting reconnect...")
        reconnectLock.lock()
        defer { reconnectLock.unlock() }
        guard self.smb.reconnect() else {
            self.log("Reconnect FAILED")
            return false
        }
        self.log("Reconnect succeeded, clearing caches")

        self.clearAllDirectoryCaches()

        guard let item, item !== self.rootItem else { return true }
        do {
            try item.forceReopen(mode: mode)
        } catch {
            self.logger.error("\(#function): Failed to reopen \(item.name): \(error)")
            self.log("Failed to reopen \(item.name): \(error)")
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

    /// Registers enumerated children so subsequent `lookupItem` calls avoid extra SMB round trips.
    func registerEnumeratedChildren(_ entries: [SMBKeepDirEntry], in parent: SMBKeepFSItem) {
        var byName: [String: SMBKeepFSItem] = [:]
        byName.reserveCapacity(entries.count)
        self.itemCacheQueue.sync {
            for entry in entries {
                let childPath = parent.smbPath.appendingSMBComponent(entry.name)
                let item = SMBKeepFSItem(name: entry.name, parent: parent, smbPath: childPath,
                                             type: entry.itemType, inode: entry.itemID, cachedRaw: entry.raw)
                byName[entry.name] = item
                self.itemCache[entry.itemID] = item
            }
        }
        self.directoryLookupCacheLock.lock()
        self.directoryLookupCache[parent.inode] = byName
        self.directoryLookupCacheLock.unlock()
    }

    func cachedChild(named name: String, in parent: SMBKeepFSItem) -> SMBKeepFSItem? {
        self.directoryLookupCacheLock.lock()
        let item = self.directoryLookupCache[parent.inode]?[name]
        self.directoryLookupCacheLock.unlock()
        return item
    }

    private func handleSystemDidWake() {
        self.reconnectAndClearCaches(reason: "wake")
    }

    /// Rebuilds the SMB connection and clears stale caches, retrying with backoff on failure.
    private func reconnectAndClearCaches(reason: String, attempt: Int = 0) {
        reconnectLock.lock()
        let ok = self.smb.reconnect()
        reconnectLock.unlock()

        if ok {
            self.clearAllDirectoryCaches()
            self.logger.info("\(#function): Reconnected SMB after \(reason) (attempt \(attempt))")
            return
        }

        let maxAttempts = 5
        guard attempt < maxAttempts else {
            self.logger.error("\(#function): Couldn't reconnect SMB after \(reason)")
            return
        }
        let delay = DispatchTimeInterval.seconds(attempt + 1)
        wakeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconnectAndClearCaches(reason: reason, attempt: attempt + 1)
        }
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

/// Fires `onChange` whenever the active network changes (Wi-Fi switch, new IP, etc.).
///
/// Watches the primary IPv4 route and per-interface Wi-Fi association via
/// ``SCDynamicStore``, which reacts promptly even when switching between Wi-Fi
/// networks on the same interface. We don't try to classify "connected" vs.
/// "disconnected" — any change just triggers a reconnect + cache refresh.
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

/// Observes system sleep/wake transitions and invokes a handler when the machine wakes.
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
