/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
FSVolume.Operations for the SMB-backed passthrough file system.
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
        do {
            let fsAttrs = try self.smb.attributesOfFileSystem(forPath: "")
            if let blockSize = fsAttrs[.systemSize] as? NSNumber {
                let bsize = blockSize.uint64Value > 0 ? 4096 : 4096
                res.blockSize = Int(bsize)
                res.ioSize = Int(bsize)
            }
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
        } catch {
            Logger.smbkeepfs.debug("\(#function): statvfs unavailable (\(error))")
        }
        return res
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
        reply(nil)
    }

    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                              of item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        do {
            return replyHandler(try self.fetchAttributes(desiredAttributes, of: ptItem), nil)
        } catch {
            guard self.recoverFromConnectionLoss(error, reopening: ptItem) else {
                return replyHandler(nil, error)
            }
            do {
                return replyHandler(try self.fetchAttributes(desiredAttributes, of: ptItem), nil)
            } catch {
                return replyHandler(nil, error)
            }
        }
    }

    private func fetchAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                                 of ptItem: SMBKeepFSItem) throws -> FSItem.Attributes {
        let parentInode = ptItem.parent?.inode ?? ptItem.inode
        if let raw = ptItem.cachedRaw, ptItem.isAttributeCacheValid(ttl: self.attributeCacheTTL) {
            return self.projectAttributes(raw, itemType: ptItem.itemType,
                                          parentInode: parentInode, desired: desiredAttributes)
        }
        let smbAttrs = try self.smb.attributesOfItem(atPath: ptItem.smbPath)
        let type = SMBAttributeMapping.itemType(from: smbAttrs)
        ptItem.cachedRaw = SMBAttributeMapping.rawAttributes(from: smbAttrs, path: ptItem.smbPath)
        ptItem.cachedRawAt = Date()
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

        // Silently accept uid/gid changes; the volume reports current user as owner anyway.

        var recoveredOnce = false
        while true {
            do {
                if newAttributes.isValid(.size), ptItem.itemType == .file {
                    try self.smb.truncateFile(atPath: ptItem.smbPath, atOffset: newAttributes.size)
                }

                let urlAttrs = SMBAttributeMapping.urlAttributes(from: newAttributes)
                if !urlAttrs.isEmpty {
                    try self.smb.setAttributes(urlAttrs, atPath: ptItem.smbPath)
                }
                ptItem.clearCachedMetadata()

                let getRequest = FSItem.GetAttributesRequest()
                getRequest.wantedAttributes = [.gid, .uid, .mode, .size, .allocSize,
                                               .type, .fileID, .parentID, .flags,
                                               .linkCount, .accessTime, .birthTime,
                                               .modifyTime, .changeTime]
                let attrs = try self.fetchAttributes(getRequest, of: ptItem)
                return replyHandler(attrs, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: ptItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(nil, error)
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

        let childPath = dirItem.smbPath.appendingSMBComponent(nameString)
        var recoveredOnce = false
        while true {
            do {
                let attrs = try self.smb.attributesOfItem(atPath: childPath)
                let inode = SMBAttributeMapping.inode(from: attrs, fallbackPath: childPath)
                var cached: SMBKeepFSItem?
                self.itemCacheQueue.sync {
                    cached = self.itemCache[inode]
                }
                if let cached {
                    return replyHandler(cached, nil, nil)
                }

                let type = SMBAttributeMapping.itemType(from: attrs)
                let raw = SMBAttributeMapping.rawAttributes(from: attrs, path: childPath)
                let newItem = SMBKeepFSItem(name: nameString, parent: dirItem, smbPath: childPath,
                                                type: type, inode: inode, cachedRaw: raw)
                self.itemCacheQueue.sync {
                    self.itemCache[inode] = newItem
                }
                return replyHandler(newItem, name, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: dirItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(nil, nil, error)
            }
        }
    }

    public func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(POSIXError(.EINVAL))
        }
        self.itemCacheQueue.sync {
            self.itemCache.removeValue(forKey: ptItem.inode)
        }
        self.invalidateEnumerationCache(forInode: ptItem.inode)
        try? ptItem.closeItem()
        replyHandler(nil)
    }

    public func readSymbolicLink(_ item: FSItem,
                                 replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let ptItem = item as? SMBKeepFSItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        var recoveredOnce = false
        while true {
            do {
                let dest = try self.smb.destinationOfSymbolicLink(atPath: ptItem.smbPath)
                let data = Data(dest.utf8)
                guard data.count <= maxSymlinkSize else {
                    return replyHandler(nil, POSIXError(.ENAMETOOLONG))
                }
                return replyHandler(FSFileName(data: data), nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: ptItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(nil, error)
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

        let childPath = dirItem.smbPath.appendingSMBComponent(nameString)
        var recoveredOnce = false
        while true {
            do {
                switch type {
                case .directory:
                    try self.smb.createDirectory(atPath: childPath)
                case .file:
                    try self.smb.createEmptyFile(atPath: childPath)
                default:
                    return replyHandler(nil, nil, POSIXError(.EINVAL))
                }

                let newItem = try SMBKeepFSItem(name: nameString, parent: dirItem, type: type, backend: self.smb)
                self.setAttributes(newAttributes, on: newItem, creatingNewFile: true) { attrs, error in
                    guard error == nil else {
                        return replyHandler(nil, nil, error)
                    }
                    self.itemCacheQueue.sync {
                        self.itemCache[newItem.inode] = newItem
                    }
                    self.invalidateEnumerationCache(forInode: dirItem.inode)
                    replyHandler(newItem, name, nil)
                }
                return
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: dirItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(nil, nil, error)
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
        guard dirItem.itemType == .directory else {
            return replyHandler(nil, nil, POSIXError(.ENOTDIR))
        }
        guard newAttributes.isValid(.mode) else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let childPath = dirItem.smbPath.appendingSMBComponent(nameString)
        let linkTarget = String(decoding: contents.data, as: Unicode.UTF8.self)

        do {
            try self.smb.createSymbolicLink(atPath: childPath, withDestinationPath: linkTarget)
            let newItem = try SMBKeepFSItem(name: nameString, parent: dirItem, type: .symlink, backend: self.smb)
            self.setAttributes(newAttributes, on: newItem, creatingNewFile: true) { _, error in
                guard error == nil else {
                    return replyHandler(nil, nil, error)
                }
                self.itemCacheQueue.sync {
                    self.itemCache[newItem.inode] = newItem
                }
                self.invalidateEnumerationCache(forInode: dirItem.inode)
                replyHandler(newItem, name, nil)
            }
        } catch {
            replyHandler(nil, nil, error)
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

        var recoveredOnce = false
        while true {
            do {
                try self.smb.removeItem(atPath: ptItem.smbPath)
                self.itemCacheQueue.sync {
                    self.itemCache.removeValue(forKey: ptItem.inode)
                }
                self.invalidateEnumerationCache(forInode: dirItem.inode)
                return replyHandler(nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: dirItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(error)
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

        let fromInode = fromItem.inode
        let destPath = toDir.smbPath.appendingSMBComponent(destName)

        var recoveredOnce = false
        while true {
            do {
                try self.smb.moveItem(atPath: fromItem.smbPath, toPath: destPath)
                fromItem.name = destName
                fromItem.parent = toDir
                fromItem.smbPath = destPath
                fromItem.clearCachedMetadata()

                self.itemCacheQueue.sync {
                    self.itemCache.removeValue(forKey: fromInode)
                    self.itemCache[fromItem.inode] = fromItem
                }
                if let over = overItem as? SMBKeepFSItem, over !== fromItem {
                    self.itemCacheQueue.sync {
                        self.itemCache.removeValue(forKey: over.inode)
                    }
                }
                self.invalidateEnumerationCache(forInode: fromDir.inode)
                self.invalidateEnumerationCache(forInode: toDir.inode)
                return replyHandler(destinationName, nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(nil, error)
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
        guard dirItem.itemType == .directory else {
            return replyHandler(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }

        var recoveredOnce = false
        while true {
            do {
                let snapshot = try self.directorySnapshot(for: dirItem, cookie: cookie, verifier: verifier)
                let startIndex = Int(cookie.rawValue)
                if startIndex < snapshot.entries.count {
                    for index in startIndex..<snapshot.entries.count {
                        let entry = snapshot.entries[index]
                        var itemAttributes: FSItem.Attributes?
                        if let attributes {
                            itemAttributes = self.projectAttributes(entry.raw, itemType: entry.itemType,
                                                                    parentInode: dirItem.inode, desired: attributes)
                        }
                        let packed = packer.packEntry(name: FSFileName(string: entry.name),
                                                      itemType: entry.itemType,
                                                      itemID: FSItem.Identifier(rawValue: entry.itemID) ?? .invalid,
                                                      nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                                                      attributes: itemAttributes)
                        if !packed { break }
                    }
                }
                return replyHandler(FSDirectoryVerifier(snapshot.verifier), nil)
            } catch {
                if !recoveredOnce, self.recoverFromConnectionLoss(error, reopening: dirItem) {
                    recoveredOnce = true
                    continue
                }
                return replyHandler(FSDirectoryVerifier(0), error)
            }
        }
    }

    private func directorySnapshot(for dirItem: SMBKeepFSItem,
                                   cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier) throws -> SMBKeepDirectorySnapshot {
        self.enumerationCacheLock.lock()
        if let cached = self.enumerationCache[dirItem.inode] {
            // Mid-readdir pagination must stay consistent, so always reuse the
            // snapshot when resuming. A fresh open only reuses it within the TTL,
            // otherwise we re-list to pick up external changes.
            let matchesResume = cookie.rawValue != 0 && cached.verifier == verifier.rawValue
            let isFresh = Date().timeIntervalSince(cached.createdAt) < self.directoryCacheTTL
            let matchesFreshOpen = cookie.rawValue == 0 && verifier.rawValue == 0 && isFresh
            if matchesResume || matchesFreshOpen {
                self.enumerationCacheLock.unlock()
                return cached
            }
        }
        self.enumerationCacheLock.unlock()

        let entries = try self.snapshotDirectory(atPath: dirItem.smbPath, parent: dirItem)

        self.enumerationCacheLock.lock()
        defer { self.enumerationCacheLock.unlock() }
        self.enumerationCacheGeneration += 1
        let snapshot = SMBKeepDirectorySnapshot(verifier: self.enumerationCacheGeneration, entries: entries)
        if self.enumerationCache.count >= 64 {
            self.enumerationCache.removeAll(keepingCapacity: true)
            self.directoryLookupCacheLock.lock()
            self.directoryLookupCache.removeAll(keepingCapacity: true)
            self.directoryLookupCacheLock.unlock()
        }
        self.enumerationCache[dirItem.inode] = snapshot
        return snapshot
    }

    private func snapshotDirectory(atPath path: String,
                                   parent: SMBKeepFSItem) throws -> [SMBKeepDirEntry] {
        let listing = try self.smb.contentsOfDirectory(atPath: path)
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
        if desired.isAttributeWanted(.size), itemType == .file { attrs.size = raw.size }
        if desired.isAttributeWanted(.allocSize), itemType == .file { attrs.allocSize = raw.allocSize }
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
