/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
SMB 后端透传文件系统的 FSVolume.Operations 实现。
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

struct SMBKeepRawAttributes {
    var ownerID: uid_t = 0
    var groupID: gid_t = 0
    var accessMask: UInt32 = 0
    var bsdFlags: UInt32 = 0
    var fileID: UInt64 = 0
    var parentID: UInt64 = 0
    var hasParentID: Bool = false
    var createTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
    var modifyTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
    var changeTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
    var accessTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
    var addedTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
    var hasAddedTime: Bool = false
    var size: UInt64 = 0
    var allocSize: UInt64 = 0
    var linkCount: UInt32 = 1
}

struct SMBKeepDirEntry {
    let name: String
    let itemType: FSItem.ItemType
    let itemID: UInt64
    let raw: SMBKeepRawAttributes
}

final class SMBKeepDirectorySnapshot {
    let verifier: UInt64
    let entries: [SMBKeepDirEntry]
    let createdAt: Date

    init(verifier: UInt64, entries: [SMBKeepDirEntry]) {
        self.verifier = verifier
        self.entries = entries
        self.createdAt = Date()
    }
}

extension SMBKeepFSVolume: FSVolume.Operations {

    public var volumeStatistics: FSStatFSResult {
        let res = FSStatFSResult(fileSystemTypeName: String("smbsmbkeepfs"))
        res.blockSize = 4096
        res.ioSize = 4096

        // FSKit 是同步读取这个值的，所以我们不能阻塞等待一次 SMB 往返。
        // 返回上一次缓存的 statvfs，并在后台刷新它。
        let cached = self.cache.cachedFileSystemAttributes()
        if let fsAttrs = cached {
            if let total = fsAttrs[.systemSize] as? NSNumber {
                res.totalBlocks = total.uint64Value / UInt64(res.blockSize)
            }
            if let free = fsAttrs[.systemFreeSize] as? NSNumber {
                res.freeBlocks = free.uint64Value / UInt64(res.blockSize)
                res.availableBlocks = res.freeBlocks
            }
            res.usedBlocks = res.totalBlocks &- res.freeBlocks
            if let nodes = fsAttrs[.systemNodes] as? NSNumber {
                res.totalFiles = nodes.uint64Value
            }
            if let freeNodes = fsAttrs[.systemFreeNodes] as? NSNumber {
                res.freeFiles = freeNodes.uint64Value
            }
        }
        Task { await self.refreshVolumeStatistics() }
        return res
    }

    private func refreshVolumeStatistics() async {
        do {
            let fsAttrs = try await self.smb.attributesOfFileSystem(forPath: "")
            self.cache.setFileSystemAttributes(fsAttrs)
        } catch {
            self.logger.debug("\(#function): statvfs unavailable (\(error))")
        }
    }

    public func activate(options: FSTaskOptions,
                         replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(self.rootItem, nil)
    }

    public func deactivate(options: FSDeactivateOptions = [],
                           replyHandler: @escaping ((any Error)?) -> Void) {
        self.log("Deactivate: disconnecting SMB")
        self.smb.disconnect()
        self.log("Deactivate complete")
        replyHandler(nil)
    }

    public func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
        self.log("Mount completed")
        replyHandler(nil)
    }

    public func unmount(replyHandler: @escaping () -> Void) {
        self.log("Unmount initiated")
        self.smb.disconnect()
        self.log("Unmount completed, SMB disconnected")
        replyHandler()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // 把缓存的可写句柄刷写到服务器。pwrite 已经把字节送达；
        // fsync 是请求服务器把它们落到稳定存储。
        let replyBox = FSKitSendableBox(reply)
        Task {
            do {
                try await self.smb.flushAll()
                return replyBox.value(nil)
            } catch {
                if await self.recoverFromConnectionLoss(error) {
                    // 重连之后已经没有可刷写的打开句柄了。
                    return replyBox.value(nil)
                }
                return replyBox.value(error)
            }
        }
    }

    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                              of item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let replyBox = FSKitSendableBox(replyHandler)
        let desiredBox = FSKitSendableBox(desiredAttributes)
        Task {
            do {
                let attrs = try await self.withReconnect(reopening: ptItem) {
                    try await self.fetchAttributes(desiredBox.value, of: ptItem)
                }
                return replyBox.value(attrs, nil)
            } catch {
                return replyBox.value(nil, error)
            }
        }
    }

    private func fetchAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                                 of ptItem: SMBKeepFSItem) async throws -> FSItem.Attributes {
        let snapshot = ptItem.stateSnapshot()
        let parentInode = snapshot.parent?.inode ?? snapshot.inode
        if let raw = ptItem.cachedRawIfValid(ttl: self.attributeCacheTTL) {
            return self.projectAttributes(raw, itemType: snapshot.itemType,
                                          parentInode: parentInode, desired: desiredAttributes)
        }
        let smbAttrs = try await self.smb.attributesOfItem(atPath: snapshot.smbPath)
        let type = SMBAttributeMapping.itemType(from: smbAttrs)
        let raw = SMBAttributeMapping.rawAttributes(from: smbAttrs, path: snapshot.smbPath)
        ptItem.updateCachedMetadata(raw, ifCurrentPath: snapshot.smbPath)
        return SMBAttributeMapping.makeAttributes(from: smbAttrs, itemType: type,
                                                  parentInode: parentInode,
                                                  desired: desiredAttributes)
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              creatingNewFile: Bool,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        if !creatingNewFile &&
            (newAttributes.isValid(.type) || newAttributes.isValid(.linkCount) ||
             newAttributes.isValid(.allocSize) || newAttributes.isValid(.fileID) ||
             newAttributes.isValid(.parentID) || newAttributes.isValid(.changeTime)) {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        if newAttributes.isValid(.mode) && ((Int32(newAttributes.mode) & ~modeAllBits) != 0) {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        // 静默接受 uid/gid 变更；反正卷始终把当前用户报告为所有者。

        let replyBox = FSKitSendableBox(replyHandler)
        let newAttributesBox = FSKitSendableBox(newAttributes)
        Task {
            do {
                let attrs = try await self.withReconnect(reopening: ptItem) { () -> FSItem.Attributes in
                    let snapshot = ptItem.stateSnapshot()
                    if newAttributesBox.value.isValid(.size), snapshot.itemType == .file {
                        try await self.smb.truncateFile(atPath: snapshot.smbPath, atOffset: newAttributesBox.value.size)
                    }

                    let urlAttrs = SMBAttributeMapping.urlAttributes(from: newAttributesBox.value)
                    if !urlAttrs.isEmpty {
                        try await self.smb.setAttributes(urlAttrs, atPath: snapshot.smbPath)
                    }
                    ptItem.clearCachedMetadata()

                    let getRequest = FSItem.GetAttributesRequest()
                    getRequest.wantedAttributes = [.gid, .uid, .mode, .size, .allocSize,
                                                   .type, .fileID, .parentID, .flags,
                                                   .linkCount, .accessTime, .birthTime,
                                                   .modifyTime, .changeTime]
                    return try await self.fetchAttributes(getRequest, of: ptItem)
                }
                return replyBox.value(attrs, nil)
            } catch {
                return replyBox.value(nil, error)
            }
        }
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        self.setAttributes(newAttributes, on: item, creatingNewFile: false, replyHandler: replyHandler)
    }

    public func lookupItem(named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? SMBKeepFSItem else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        if let cached = self.cachedChild(named: nameString, in: dirItem) {
            return replyHandler(cached, nil, nil)
        }

        let dirSnapshot = dirItem.stateSnapshot()
        let childPath = dirSnapshot.smbPath.appendingSMBComponent(nameString)
        let replyBox = FSKitSendableBox(replyHandler)
        let nameBox = FSKitSendableBox(name)
        Task {
            do {
                let (resultItem, replyName) = try await self.withReconnect(reopening: dirItem) { () -> (SMBKeepFSItem, FSFileName?) in
                    let attrs = try await self.smb.attributesOfItem(atPath: childPath)
                    let inode = SMBAttributeMapping.inode(from: attrs, fallbackPath: childPath)
                    if let cached = self.cache.item(forInode: inode), cached.smbPath == childPath {
                        return (cached, nil)
                    }

                    let type = SMBAttributeMapping.itemType(from: attrs)
                    let raw = SMBAttributeMapping.rawAttributes(from: attrs, path: childPath)
                    let newItem = SMBKeepFSItem(name: nameString, parent: dirItem, smbPath: childPath,
                                                    type: type, inode: inode, cachedRaw: raw)
                    self.cache.setItem(newItem, forInode: inode)
                    return (newItem, nameBox.value)
                }
                return replyBox.value(resultItem, replyName, nil)
            } catch {
                return replyBox.value(nil, nil, error)
            }
        }
    }

    public func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        let snapshot = ptItem.stateSnapshot()
        self.cache.removeItem(forInode: snapshot.inode)
        self.invalidateEnumerationCache(forInode: snapshot.inode)
        // 兜底保护：确保没有句柄比正被回收的 item 活得更久。
        if snapshot.itemType == .file {
            self.smb.closeHandle(forPath: snapshot.smbPath)
        }
        try? ptItem.closeItem()
        replyHandler(nil)
    }

    public func readSymbolicLink(_ item: FSItem,
                                 replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let replyBox = FSKitSendableBox(replyHandler)
        Task {
            do {
                let data = try await self.withReconnect(reopening: ptItem) { () -> Data in
                    let snapshot = ptItem.stateSnapshot()
                    let dest = try await self.smb.destinationOfSymbolicLink(atPath: snapshot.smbPath)
                    return Data(dest.utf8)
                }
                guard data.count <= maxSymlinkSize else {
                    return replyBox.value(nil, POSIXError(.ENAMETOOLONG))
                }
                return replyBox.value(FSFileName(data: data), nil)
            } catch {
                return replyBox.value(nil, error)
            }
        }
    }

    public func createItem(named name: FSFileName,
                           type: FSItem.ItemType,
                           inDirectory directory: FSItem,
                           attributes newAttributes: FSItem.SetAttributesRequest,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? SMBKeepFSItem else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        if (type == .file || type == .symlink) && !newAttributes.isValid(.mode) {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let dirSnapshot = dirItem.stateSnapshot()
        let childPath = dirSnapshot.smbPath.appendingSMBComponent(nameString)
        let replyBox = FSKitSendableBox(replyHandler)
        let newAttributesBox = FSKitSendableBox(newAttributes)
        let nameBox = FSKitSendableBox(name)
        Task {
            do {
                let newItem = try await self.withReconnect(reopening: dirItem) { () -> SMBKeepFSItem in
                    switch type {
                    case .directory:
                        try await self.smb.createDirectory(atPath: childPath)
                    case .file:
                        try await self.smb.createEmptyFile(atPath: childPath)
                    default:
                        throw POSIXError(.EINVAL)
                    }
                    return try await SMBKeepFSItem(name: nameString, parent: dirItem, type: type, backend: self.smb)
                }
                self.setAttributes(newAttributesBox.value, on: newItem, creatingNewFile: true) { attrs, error in
                    guard error == nil else {
                        return replyBox.value(nil, nil, error)
                    }
                    self.cache.setItem(newItem, forInode: newItem.inode)
                    self.invalidateEnumerationCache(forInode: dirSnapshot.inode)
                    replyBox.value(newItem, nameBox.value, nil)
                }
            } catch {
                return replyBox.value(nil, nil, error)
            }
        }
    }

    public func createSymbolicLink(named name: FSFileName,
                                   inDirectory directory: FSItem,
                                   attributes newAttributes: FSItem.SetAttributesRequest,
                                   linkContents contents: FSFileName,
                                   replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard !contents.data.isEmpty else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let dirItem = directory as? SMBKeepFSItem else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        let dirSnapshot = dirItem.stateSnapshot()
        guard dirSnapshot.itemType == .directory else {
            return replyHandler(nil, nil, POSIXError(.ENOTDIR))
        }
        guard newAttributes.isValid(.mode) else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let childPath = dirSnapshot.smbPath.appendingSMBComponent(nameString)
        let linkTarget = String(decoding: contents.data, as: Unicode.UTF8.self)

        let replyBox = FSKitSendableBox(replyHandler)
        let newAttributesBox = FSKitSendableBox(newAttributes)
        let nameBox = FSKitSendableBox(name)
        Task {
            do {
                try await self.smb.createSymbolicLink(atPath: childPath, withDestinationPath: linkTarget)
                let newItem = try await SMBKeepFSItem(name: nameString, parent: dirItem, type: .symlink, backend: self.smb)
                self.setAttributes(newAttributesBox.value, on: newItem, creatingNewFile: true) { _, error in
                    guard error == nil else {
                        return replyBox.value(nil, nil, error)
                    }
                    self.cache.setItem(newItem, forInode: newItem.inode)
                    self.invalidateEnumerationCache(forInode: dirSnapshot.inode)
                    replyBox.value(newItem, nameBox.value, nil)
                }
            } catch {
                replyBox.value(nil, nil, error)
            }
        }
    }

    public func createLink(to item: FSItem,
                           named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        replyHandler(nil, POSIXError(.ENOTSUP))
    }

    public func removeItem(_ item: FSItem,
                           named name: FSFileName,
                           fromDirectory directory: FSItem,
                           replyHandler: @escaping (Error?) -> Void) {
        guard let dirItem = directory as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        let dirSnapshot = dirItem.stateSnapshot()

        let replyBox = FSKitSendableBox(replyHandler)
        Task {
            do {
                try await self.withReconnect(reopening: dirItem) {
                    let itemSnapshot = ptItem.stateSnapshot()
                    try await self.smb.removeItem(atPath: itemSnapshot.smbPath)
                    self.cache.removeItem(forInode: itemSnapshot.inode)
                    self.invalidateEnumerationCache(forInode: dirSnapshot.inode)
                }
                return replyBox.value(nil)
            } catch {
                return replyBox.value(error)
            }
        }
    }

    public func renameItem(_ item: FSItem,
                           inDirectory sourceDirectory: FSItem,
                           named sourceName: FSFileName,
                           to destinationName: FSFileName,
                           inDirectory destinationDirectory: FSItem,
                           overItem: FSItem?,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let fromItem = item as? SMBKeepFSItem,
              let fromDir = sourceDirectory as? SMBKeepFSItem,
              let toDir = destinationDirectory as? SMBKeepFSItem,
              let destName = destinationName.string else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let fromSnapshot = fromItem.stateSnapshot()
        let fromDirSnapshot = fromDir.stateSnapshot()
        let toDirSnapshot = toDir.stateSnapshot()
        let fromInode = fromSnapshot.inode
        let destPath = toDirSnapshot.smbPath.appendingSMBComponent(destName)

        let replyBox = FSKitSendableBox(replyHandler)
        let overItemBox = FSKitSendableBox(overItem)
        let destinationNameBox = FSKitSendableBox(destinationName)
        Task {
            do {
                try await self.withReconnect {
                    let currentFrom = fromItem.stateSnapshot()
                    try await self.smb.moveItem(atPath: currentFrom.smbPath, toPath: destPath)
                    fromItem.updateIdentityAfterRename(name: destName, parent: toDir, smbPath: destPath)

                    let over = overItemBox.value as? SMBKeepFSItem
                    let overInode = (over != nil && over !== fromItem) ? over?.inode : nil
                    self.cache.reassignItem(fromItem, fromInode: fromInode,
                                            toInode: fromItem.inode, replacingInode: overInode)
                    self.invalidateEnumerationCache(forInode: fromDirSnapshot.inode)
                    self.invalidateEnumerationCache(forInode: toDirSnapshot.inode)
                }
                return replyBox.value(destinationNameBox.value, nil)
            } catch {
                return replyBox.value(nil, error)
            }
        }
    }

    public func enumerateDirectory(_ directory: FSItem,
                                   startingAt cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier,
                                   attributes: FSItem.GetAttributesRequest?,
                                   packer: FSDirectoryEntryPacker,
                                   replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        guard let dirItem = directory as? SMBKeepFSItem else {
            return replyHandler(FSDirectoryVerifier(0), POSIXError(.EINVAL))
        }
        let dirSnapshot = dirItem.stateSnapshot()
        guard dirSnapshot.itemType == .directory else {
            return replyHandler(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }

        // 用户正在浏览目录：即便之前因连续失败而熔断，也立刻解除熔断，
        // 让下面的操作（必要时经 recoverFromConnectionLoss）重新开始尝试重连。
        self.smb.resumeReconnects()

        // 显式捕获 FSKit 对象：它们在 Task 生命周期内必须保持存活，
        // 防止 FSKit 在回调返回后提前释放。
        let retainedPacker = FSKitSendableBox(packer)
        let retainedAttributes = attributes.map { FSKitSendableBox($0) }
        let replyBox = FSKitSendableBox(replyHandler)
        Task {
            do {
                let snapshot = try await self.withReconnect(reopening: dirItem) {
                    try await self.directorySnapshot(for: dirItem, cookie: cookie, verifier: verifier)
                }
                let startIndex = Int(cookie.rawValue)
                if startIndex < snapshot.entries.count {
                    for index in startIndex..<snapshot.entries.count {
                        let entry = snapshot.entries[index]
                        var itemAttributes: FSItem.Attributes?
                        if let retainedAttributes {
                            itemAttributes = self.projectAttributes(entry.raw, itemType: entry.itemType,
                                                                    parentInode: dirSnapshot.inode, desired: retainedAttributes.value)
                        }
                        let packed = retainedPacker.value.packEntry(name: FSFileName(string: entry.name),
                                                      itemType: entry.itemType,
                                                      itemID: FSItem.Identifier(rawValue: entry.itemID) ?? .invalid,
                                                      nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                                                      attributes: itemAttributes)
                        if !packed { break }
                    }
                }
                return replyBox.value(FSDirectoryVerifier(snapshot.verifier), nil)
            } catch {
                return replyBox.value(FSDirectoryVerifier(0), error)
            }
        }
    }

    private func directorySnapshot(for dirItem: SMBKeepFSItem,
                                   cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier) async throws -> SMBKeepDirectorySnapshot {
        let dirSnapshot = dirItem.stateSnapshot()
        // readdir 分页过程中必须保持一致，因此续读时总是复用同一份快照；
        // 而全新的一次打开只在 TTL 内复用，超过则重新列举以反映外部变更（具体判定在缓存内部）。
        if let cached = self.cache.enumerationSnapshot(forInode: dirSnapshot.inode,
                                                       cookie: cookie.rawValue,
                                                       verifier: verifier.rawValue,
                                                       ttl: self.directoryCacheTTL) {
            return cached
        }
        let entries = try await self.snapshotDirectory(atPath: dirSnapshot.smbPath, parent: dirItem)
        return self.cache.storeEnumeration(forInode: dirSnapshot.inode, entries: entries)
    }

    private func snapshotDirectory(atPath path: String,
                                   parent: SMBKeepFSItem) async throws -> [SMBKeepDirEntry] {
        let listing = try await self.smb.contentsOfDirectory(atPath: path)
        var entries: [SMBKeepDirEntry] = []
        entries.reserveCapacity(listing.count)
        for attrs in listing {
            guard let name = attrs[.nameKey] as? String else { continue }
            if name == "." || name == ".." { continue }
            let childPath = (attrs[.pathKey] as? String) ?? path.appendingSMBComponent(name)
            let type = SMBAttributeMapping.itemType(from: attrs)
            let inode = SMBAttributeMapping.inode(from: attrs, fallbackPath: childPath)
            let raw = SMBAttributeMapping.rawAttributes(from: attrs, path: childPath)
            entries.append(SMBKeepDirEntry(name: name, itemType: type, itemID: inode, raw: raw))
        }
        self.registerEnumeratedChildren(entries, in: parent)
        return entries
    }

    private func projectAttributes(_ raw: SMBKeepRawAttributes,
                                   itemType: FSItem.ItemType,
                                   parentInode: UInt64,
                                   desired: FSItem.GetAttributesRequest) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        if desired.isAttributeWanted(.uid) { attrs.uid = raw.ownerID }
        if desired.isAttributeWanted(.gid) { attrs.gid = raw.groupID }
        if desired.isAttributeWanted(.mode) { attrs.mode = raw.accessMask & UInt32(modeAllBits) }
        if desired.isAttributeWanted(.linkCount) { attrs.linkCount = raw.linkCount }
        if desired.isAttributeWanted(.flags) { attrs.flags = raw.bsdFlags }
        // 始终上报 size/allocSize，即便是目录和符号链接：FSKit 的标准属性集要求它们，
        // 缺失会导致 “attributes are incomplete” 错误。
        if desired.isAttributeWanted(.size) { attrs.size = raw.size }
        if desired.isAttributeWanted(.allocSize) { attrs.allocSize = raw.allocSize }
        if desired.isAttributeWanted(.fileID) {
            attrs.fileID = FSItem.Identifier(rawValue: raw.fileID) ?? .invalid
        }
        if desired.isAttributeWanted(.parentID) {
            let pid = raw.hasParentID ? raw.parentID : parentInode
            attrs.parentID = FSItem.Identifier(rawValue: pid) ?? .invalid
        }
        if desired.isAttributeWanted(.type) { attrs.type = itemType }
        if desired.isAttributeWanted(.accessTime) { attrs.accessTime = raw.accessTime }
        if desired.isAttributeWanted(.changeTime) { attrs.changeTime = raw.changeTime }
        if desired.isAttributeWanted(.modifyTime) { attrs.modifyTime = raw.modifyTime }
        if desired.isAttributeWanted(.birthTime) { attrs.birthTime = raw.createTime }
        if desired.isAttributeWanted(.addedTime) {
            attrs.addedTime = raw.hasAddedTime ? raw.addedTime : raw.createTime
        }
        if desired.isAttributeWanted(.backupTime) {
            attrs.backupTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
        }
        return attrs
    }

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = false
        capabilities.supportsHiddenFiles = true
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports2TBFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }
}
