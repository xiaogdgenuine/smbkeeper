/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
定义透传文件系统所用的自定义 item 的类。
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

/// 定义的 item 打开模式。
enum SMBKeepFSItemOpenMode: Int32 {
    case close = -1
    case readOnly = 0
    case readWrite = 1
}

/// SMBKeepFSItem 表示一个以 SMB 路径为后端的文件系统 item。
class SMBKeepFSItem: FSItem {

    private let stateLock = NSLock()
    private var _smbPath: String
    private var _openMode: SMBKeepFSItemOpenMode
    private weak var _parent: SMBKeepFSItem?
    private var _name: String
    private var _itemType: FSItem.ItemType
    private var _inode: UInt64

    /// 目录枚举时捕获的属性；避免在 lookup/getattr 时对每个条目再做一次 `stat`。
    private var _cachedRaw: SMBKeepRawAttributes?
    /// ``cachedRaw`` 上次刷新的时间；用于让过期的属性缓存失效。
    private var _cachedRawAt: Date?

    struct StateSnapshot {
        let name: String
        let smbPath: String
        let parent: SMBKeepFSItem?
        let itemType: FSItem.ItemType
        let inode: UInt64
        let cachedRaw: SMBKeepRawAttributes?
        let cachedRawAt: Date?
    }

    /// 在 `stateLock` 保护下执行 `body`，作为所有可变状态访问的唯一入口。
    /// 把过去每个 getter 都重复一遍的 lock/defer-unlock 样板收敛到一处，语义不变。
    private func withLock<T>(_ body: () -> T) -> T {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return body()
    }

    var smbPath: String { withLock { _smbPath } }

    var parent: SMBKeepFSItem? { withLock { _parent } }

    var name: String { withLock { _name } }

    var itemType: FSItem.ItemType { withLock { _itemType } }

    var inode: UInt64 { withLock { _inode } }

    var fileDescriptor: Int32 { -1 }

    init(name: String, smbPath: String, type: FSItem.ItemType, openFlags: SMBKeepFSItemOpenMode, inode: UInt64) {
        self._name = name
        self._parent = nil
        self._smbPath = smbPath
        self._itemType = type
        self._openMode = openFlags
        self._inode = inode
        super.init()
    }

    /// 用 `readdir` / 目录列举已返回的数据创建子 item。
    init(name: String, parent: SMBKeepFSItem, smbPath: String, type: FSItem.ItemType,
         inode: UInt64, cachedRaw: SMBKeepRawAttributes?) {
        self._name = name
        self._parent = parent
        self._openMode = .close
        self._smbPath = smbPath
        self._itemType = type
        self._inode = inode
        self._cachedRaw = cachedRaw
        self._cachedRawAt = cachedRaw != nil ? Date() : nil
        super.init()
    }

    /// 在一次写操作后创建子 item；做一次 `stat` 来刷新身份。
    init(name: String, parent: SMBKeepFSItem, type: FSItem.ItemType, backend: SMBBackend) async throws {
        let smbPath = parent.smbPath.appendingSMBComponent(name)
        self._name = name
        self._parent = parent
        self._openMode = .close
        self._itemType = type
        self._smbPath = smbPath
        self._inode = 0
        self._cachedRaw = nil
        self._cachedRawAt = nil
        super.init()
        let attrs = try await backend.attributesOfItem(atPath: smbPath)
        let inode = SMBAttributeMapping.inode(from: attrs, fallbackPath: smbPath)
        let raw = SMBAttributeMapping.rawAttributes(from: attrs, path: smbPath)
        self.withLock {
            self._inode = inode
            self._cachedRaw = raw
            self._cachedRawAt = Date()
            if let resourceType = attrs[.fileResourceTypeKey] as? URLFileResourceType {
                self._itemType = SMBAttributeMapping.itemType(from: resourceType)
            }
        }
    }

    func upgradeOpenMode(mode: SMBKeepFSItemOpenMode) throws {
        if mode == .close {
            throw POSIXError(.EINVAL)
        }
        self.withLock {
            if self._openMode == .readWrite || self._openMode == mode {
                return
            }
            self._openMode = mode
        }
    }

    func forceReopen(mode: SMBKeepFSItemOpenMode) throws {
        self.withLock { self._openMode = .close }
        try self.upgradeOpenMode(mode: mode)
    }

    func closeItem() throws {
        self.withLock { self._openMode = .close }
    }

    func clearCachedMetadata() {
        self.withLock {
            self._cachedRaw = nil
            self._cachedRawAt = nil
        }
    }

    /// 缓存的属性是否仍在给定的新鲜度窗口内。
    func isAttributeCacheValid(ttl: TimeInterval) -> Bool {
        self.withLock {
            guard _cachedRaw != nil, let at = _cachedRawAt else { return false }
            return Date().timeIntervalSince(at) < ttl
        }
    }

    func stateSnapshot() -> StateSnapshot {
        self.withLock {
            StateSnapshot(name: self._name,
                          smbPath: self._smbPath,
                          parent: self._parent,
                          itemType: self._itemType,
                          inode: self._inode,
                          cachedRaw: self._cachedRaw,
                          cachedRawAt: self._cachedRawAt)
        }
    }

    func cachedRawIfValid(ttl: TimeInterval) -> SMBKeepRawAttributes? {
        self.withLock {
            guard let raw = self._cachedRaw,
                  let at = self._cachedRawAt,
                  Date().timeIntervalSince(at) < ttl else {
                return nil
            }
            return raw
        }
    }

    func updateCachedMetadata(_ raw: SMBKeepRawAttributes, ifCurrentPath expectedPath: String? = nil) {
        self.withLock {
            if let expectedPath, self._smbPath != expectedPath { return }
            self._cachedRaw = raw
            self._cachedRawAt = Date()
        }
    }

    func updateIdentityAfterRename(name: String, parent: SMBKeepFSItem, smbPath: String) {
        self.withLock {
            self._name = name
            self._parent = parent
            self._smbPath = smbPath
            self._cachedRaw = nil
            self._cachedRawAt = nil
        }
    }
}

extension String {
    func appendingSMBComponent(_ component: String) -> String {
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if isEmpty {
            return trimmed
        }
        if hasSuffix("/") {
            return self + trimmed
        }
        return self + "/" + trimmed
    }
}
