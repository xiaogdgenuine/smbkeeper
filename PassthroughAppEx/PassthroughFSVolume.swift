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

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A PassthroughFSVolume represents a volume backed by an SMB share via AMSMB2.
class PassthroughFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    static let defaultVolumeUUID = UUID()

    var rootItem: PassthroughFSItem
    var itemCache: [UInt64: PassthroughFSItem]
    var itemCacheQueue: DispatchQueue

    var enumerationCache: [UInt64: PassthroughDirectorySnapshot] = [:]
    var enumerationCacheGeneration: UInt64 = 0
    let enumerationCacheLock = NSLock()

    /// Name → item for children last enumerated under a directory inode (avoids N stat RPCs after readdir).
    var directoryLookupCache: [UInt64: [String: PassthroughFSItem]] = [:]
    let directoryLookupCacheLock = NSLock()

    let smb: SMBBackend
    let volumeLabel: String

    private var sleepWakeMonitor: SleepWakeMonitor?
    private let wakeQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.wake.queue")
    private let reconnectLock = NSLock()

    init(backend: SMBBackend, volumeName: FSFileName) throws {
        self.smb = backend
        self.volumeLabel = volumeName.string ?? "smb_passthrough"
        let rootInode = SMBAttributeMapping.inodeForPath("")
        self.rootItem = PassthroughFSItem(name: ".", smbPath: "", type: .directory, openFlags: .readOnly, inode: rootInode)
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.itemcache.queue")
        super.init(volumeID: FSVolume.Identifier(uuid: PassthroughFSVolume.defaultVolumeUUID), volumeName: volumeName)
        Logger.passthroughfs.info("\(#function): Created SMB volume \(self.name)")

        self.sleepWakeMonitor = SleepWakeMonitor { [weak self] in
            self?.handleSystemDidWake()
        }
    }

    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(name, nil)
    }

    public func preallocateSpace(for item: FSItem,
                                 at offset: off_t,
                                 length: Int,
                                 flags: FSVolume.PreallocateFlags,
                                 replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
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
        guard let ptItem = item as? PassthroughFSItem else {
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
                    continue
                }
                Logger.passthroughfs.error("\(#function): read \(ptItem.smbPath) failed: \(error)")
                return replyHandler(0, error)
            }
        }
    }

    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
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
        guard let ptItem = item as? PassthroughFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            return replyHandler(nil)
        }

        var ptfsMode: PassthroughFSItemOpenMode = .readOnly
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
        guard let ptItem = item as? PassthroughFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            return replyHandler(nil)
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
    func recoverFromConnectionLoss(_ error: Error, reopening item: PassthroughFSItem? = nil,
                                   mode: PassthroughFSItemOpenMode = .readOnly) -> Bool {
        guard self.isConnectionLost(error) else { return false }
        reconnectLock.lock()
        defer { reconnectLock.unlock() }
        guard self.smb.reconnect() else { return false }

        self.clearAllDirectoryCaches()

        guard let item, item !== self.rootItem else { return true }
        do {
            try item.forceReopen(mode: mode)
        } catch {
            Logger.passthroughfs.error("\(#function): Failed to reopen \(item.name): \(error)")
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
    func registerEnumeratedChildren(_ entries: [PassthroughDirEntry], in parent: PassthroughFSItem) {
        var byName: [String: PassthroughFSItem] = [:]
        byName.reserveCapacity(entries.count)
        self.itemCacheQueue.sync {
            for entry in entries {
                let childPath = parent.smbPath.appendingSMBComponent(entry.name)
                let item = PassthroughFSItem(name: entry.name, parent: parent, smbPath: childPath,
                                             type: entry.itemType, inode: entry.itemID, cachedRaw: entry.raw)
                byName[entry.name] = item
                self.itemCache[entry.itemID] = item
            }
        }
        self.directoryLookupCacheLock.lock()
        self.directoryLookupCache[parent.inode] = byName
        self.directoryLookupCacheLock.unlock()
    }

    func cachedChild(named name: String, in parent: PassthroughFSItem) -> PassthroughFSItem? {
        self.directoryLookupCacheLock.lock()
        let item = self.directoryLookupCache[parent.inode]?[name]
        self.directoryLookupCacheLock.unlock()
        return item
    }

    private func handleSystemDidWake(attempt: Int = 0) {
        reconnectLock.lock()
        let ok = self.smb.reconnect()
        reconnectLock.unlock()

        if ok {
            self.clearAllDirectoryCaches()
            Logger.passthroughfs.info("\(#function): Reconnected SMB after wake (attempt \(attempt))")
            return
        }

        let maxAttempts = 5
        guard attempt < maxAttempts else {
            Logger.passthroughfs.error("\(#function): Couldn't reconnect SMB after wake")
            return
        }
        let delay = DispatchTimeInterval.seconds(attempt + 1)
        wakeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.handleSystemDidWake(attempt: attempt + 1)
        }
    }
}

/// Observes system sleep/wake transitions and invokes a handler when the machine wakes.
final class SleepWakeMonitor {
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: () -> Void
    private let queue = DispatchQueue(label: "com.apple.fskit.passthroughfs.sleepwake.queue")
    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?

    init?(onWake: @escaping () -> Void) {
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
            Logger.passthroughfs.error("\(#function): IORegisterForSystemPower failed")
            return nil
        }
        self.rootPort = connect
        self.notifierObject = notifier
        self.notificationPort = port
        IONotificationPortSetDispatchQueue(port, self.queue)
        Logger.passthroughfs.info("\(#function): Sleep/wake monitor active")
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
