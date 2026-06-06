/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Maps AMSMB2 / URL resource keys into FSKit item attributes.
*/

import Foundation
import FSKit

enum SMBAttributeMapping {

    static func itemType(from resourceType: URLFileResourceType) -> FSItem.ItemType {
        switch resourceType {
        case .directory:
            return .directory
        case .symbolicLink:
            return .symlink
        default:
            return .file
        }
    }

    static func itemType(from attributes: [URLResourceKey: any Sendable]) -> FSItem.ItemType {
        if let type = attributes[.fileResourceTypeKey] as? URLFileResourceType {
            return itemType(from: type)
        }
        if (attributes[.isDirectoryKey] as? NSNumber)?.boolValue == true {
            return .directory
        }
        if (attributes[.isSymbolicLinkKey] as? NSNumber)?.boolValue == true {
            return .symlink
        }
        return .file
    }

    static func inode(from attributes: [URLResourceKey: any Sendable], fallbackPath: String) -> UInt64 {
        if let ino = attributes[.documentIdentifierKey] as? NSNumber {
            return ino.uint64Value
        }
        return inodeForPath(fallbackPath)
    }

    static func inodeForPath(_ path: String) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(path)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    static func makeAttributes(from attributes: [URLResourceKey: any Sendable],
                                itemType: FSItem.ItemType,
                                parentInode: UInt64,
                                desired: FSItem.GetAttributesRequest) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        let path = (attributes[.pathKey] as? String) ?? ""

        if desired.isAttributeWanted(.uid) {
            attrs.uid = currentUserUID()
        }
        if desired.isAttributeWanted(.gid) {
            attrs.gid = currentUserGID()
        }
        if desired.isAttributeWanted(.mode) {
            attrs.mode = defaultMode(for: itemType)
        }
        if desired.isAttributeWanted(.linkCount) {
            attrs.linkCount = (attributes[.linkCountKey] as? NSNumber)?.uint32Value ?? 1
        }
        if desired.isAttributeWanted(.flags) {
            attrs.flags = 0
        }
        if desired.isAttributeWanted(.size), itemType == .file {
            attrs.size = (attributes[.fileSizeKey] as? NSNumber)?.uint64Value ?? 0
        }
        if desired.isAttributeWanted(.allocSize), itemType == .file {
            attrs.allocSize = attrs.size
        }
        if desired.isAttributeWanted(.fileID) {
            let ino = inode(from: attributes, fallbackPath: path)
            attrs.fileID = FSItem.Identifier(rawValue: ino) ?? .invalid
        }
        if desired.isAttributeWanted(.parentID) {
            attrs.parentID = FSItem.Identifier(rawValue: parentInode) ?? .invalid
        }
        if desired.isAttributeWanted(.type) {
            attrs.type = itemType
        }

        if desired.isAttributeWanted(.accessTime) {
            attrs.accessTime = timespec(from: attributes[.contentAccessDateKey] as? Date)
        }
        if desired.isAttributeWanted(.changeTime) {
            attrs.changeTime = timespec(from: attributes[.attributeModificationDateKey] as? Date)
        }
        if desired.isAttributeWanted(.modifyTime) {
            attrs.modifyTime = timespec(from: attributes[.contentModificationDateKey] as? Date)
        }
        if desired.isAttributeWanted(.birthTime) {
            attrs.birthTime = timespec(from: attributes[.creationDateKey] as? Date)
        }
        if desired.isAttributeWanted(.addedTime) {
            attrs.addedTime = attrs.birthTime
        }
        if desired.isAttributeWanted(.backupTime) {
            attrs.backupTime = Darwin.timespec(tv_sec: 0, tv_nsec: 0)
        }
        return attrs
    }

    static func rawAttributes(from attributes: [URLResourceKey: any Sendable],
                              path: String) -> SMBKeepRawAttributes {
        let itemType = itemType(from: attributes)
        var raw = SMBKeepRawAttributes()
        raw.ownerID = currentUserUID()
        raw.groupID = currentUserGID()
        raw.accessMask = defaultMode(for: itemType)
        raw.fileID = inode(from: attributes, fallbackPath: path)
        raw.linkCount = (attributes[.linkCountKey] as? NSNumber)?.uint32Value ?? 1
        if itemType == .file {
            raw.size = (attributes[.fileSizeKey] as? NSNumber)?.uint64Value ?? 0
            raw.allocSize = raw.size
        }
        raw.createTime = timespec(from: attributes[.creationDateKey] as? Date)
        raw.modifyTime = timespec(from: attributes[.contentModificationDateKey] as? Date)
        raw.changeTime = timespec(from: attributes[.attributeModificationDateKey] as? Date)
        raw.accessTime = timespec(from: attributes[.contentAccessDateKey] as? Date)
        raw.addedTime = raw.createTime
        raw.hasAddedTime = true
        return raw
    }

    static func urlAttributes(from request: FSItem.SetAttributesRequest) -> [URLResourceKey: Any] {
        var result = [URLResourceKey: Any]()
        if request.isValid(.accessTime) {
            result[.contentAccessDateKey] = Date(timespec: request.accessTime)
        }
        if request.isValid(.modifyTime) {
            result[.contentModificationDateKey] = Date(timespec: request.modifyTime)
        }
        if request.isValid(.birthTime) {
            result[.creationDateKey] = Date(timespec: request.birthTime)
        }
        if request.isValid(.flags) {
            let supported = UInt32(UF_IMMUTABLE | UF_HIDDEN)
            let flags = request.flags & supported
            if flags & UInt32(UF_IMMUTABLE) != 0 {
                result[.isUserImmutableKey] = true
            }
            if flags & UInt32(UF_HIDDEN) != 0 {
                result[.isHiddenKey] = true
            }
        }
        return result
    }

    private static func currentUserUID() -> uid_t {
        getuid()
    }

    private static func currentUserGID() -> gid_t {
        getgid()
    }

    private static func defaultMode(for type: FSItem.ItemType) -> UInt32 {
        switch type {
        case .directory:
            return 0o755
        case .symlink:
            return 0o777
        default:
            return 0o644
        }
    }

    private static func timespec(from date: Date?) -> Darwin.timespec {
        guard let date else { return Darwin.timespec(tv_sec: 0, tv_nsec: 0) }
        let interval = date.timeIntervalSince1970
        let sec = Int(interval)
        let nsec = Int((interval - Double(sec)) * 1_000_000_000)
        return Darwin.timespec(tv_sec: sec, tv_nsec: nsec)
    }
}

private extension Date {
    init(timespec ts: Darwin.timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}
