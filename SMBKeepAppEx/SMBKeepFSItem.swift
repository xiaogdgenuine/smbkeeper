/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that defines a custom item for use by the passthrough file system.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

/// Defined item open modes.
enum SMBKeepFSItemOpenMode: Int32 {
    case close = -1
    case readOnly = 0
    case readWrite = 1
}

/// A SMBKeepFSItem represents a file system item backed by an SMB path.
class SMBKeepFSItem: FSItem {

    var smbPath: String
    var openMode: SMBKeepFSItemOpenMode
    var parent: SMBKeepFSItem?
    var name: String
    var itemType: FSItem.ItemType
    var inode: UInt64
    let openModeLock = NSLock()

    /// Attributes captured during directory enumeration; avoids per-entry `stat` on lookup/getattr.
    var cachedRaw: SMBKeepRawAttributes?

    var fileDescriptor: Int32 { -1 }

    init(name: String, smbPath: String, type: FSItem.ItemType, openFlags: SMBKeepFSItemOpenMode, inode: UInt64) {
        self.name = name
        self.parent = nil
        self.smbPath = smbPath
        self.itemType = type
        self.openMode = openFlags
        self.inode = inode
        super.init()
    }

    /// Creates a child item using data already returned by `readdir` / directory listing.
    init(name: String, parent: SMBKeepFSItem, smbPath: String, type: FSItem.ItemType,
         inode: UInt64, cachedRaw: SMBKeepRawAttributes?) {
        self.name = name
        self.parent = parent
        self.openMode = .close
        self.smbPath = smbPath
        self.itemType = type
        self.inode = inode
        self.cachedRaw = cachedRaw
        super.init()
    }

    /// Creates a child item after a mutating operation; one `stat` to refresh identity.
    init(name: String, parent: SMBKeepFSItem, type: FSItem.ItemType, backend: SMBBackend) throws {
        self.name = name
        self.parent = parent
        self.openMode = .close
        self.itemType = type
        self.smbPath = parent.smbPath.appendingSMBComponent(name)
        self.inode = 0
        self.cachedRaw = nil
        super.init()
        let attrs = try backend.attributesOfItem(atPath: self.smbPath)
        self.inode = SMBAttributeMapping.inode(from: attrs, fallbackPath: self.smbPath)
        self.cachedRaw = SMBAttributeMapping.rawAttributes(from: attrs, path: self.smbPath)
        if let resourceType = attrs[.fileResourceTypeKey] as? URLFileResourceType {
            self.itemType = SMBAttributeMapping.itemType(from: resourceType)
        }
    }

    func upgradeOpenMode(mode: SMBKeepFSItemOpenMode) throws {
        if mode == .close {
            throw POSIXError(.EINVAL)
        }
        self.openModeLock.lock()
        defer { self.openModeLock.unlock() }
        if self.openMode == .readWrite || self.openMode == mode {
            return
        }
        self.openMode = mode
    }

    func forceReopen(mode: SMBKeepFSItemOpenMode) throws {
        self.openModeLock.lock()
        self.openMode = .close
        self.openModeLock.unlock()
        try self.upgradeOpenMode(mode: mode)
    }

    func closeItem() throws {
        self.openModeLock.lock()
        defer { self.openModeLock.unlock() }
        self.openMode = .close
    }

    func clearCachedMetadata() {
        self.cachedRaw = nil
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
