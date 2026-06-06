/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Extended-attribute support for Finder's per-file "open with" choice, tags, and comments.

To avoid polluting the remote SMB share, these xattrs are persisted locally in the
App Group container instead of being written back to the server. Implementing
`supportedXattrNames(for:)` puts FSKit in "limited" mode, so it only routes these
specific xattrs to us; every other xattr is left untouched.
*/

import Foundation
import FSKit

/// The xattr Finder writes for a per-file "Always Open With" choice (files only).
private let openWithXattr = "com.apple.LaunchServices.OpenWith"
/// xattrs Finder uses for tags and the "Comments" field (files and folders).
private let tagsXattr = "com.apple.metadata:_kMDItemUserTags"
private let commentXattr = "com.apple.metadata:kMDItemFinderComment"

//extension SMBKeepFSVolume: FSVolume.XattrOperations {
//
//    @objc(supportedXattrNamesForItem:)
//    public func supportedXattrNames(for item: FSItem) -> [FSFileName] {
//        guard let ptItem = item as? SMBKeepFSItem else { return [] }
//        var names = [tagsXattr, commentXattr]
//        if ptItem.itemType == .file { names.append(openWithXattr) }
//        return names.map { FSFileName(string: $0) }
//    }
//
//    @objc(getXattrNamed:ofItem:replyHandler:)
//    public func getXattr(named name: FSFileName,
//                         of item: FSItem,
//                         replyHandler: @escaping (Data?, (any Error)?) -> Void) {
//        guard let ptItem = item as? SMBKeepFSItem, let key = name.string else {
//            return replyHandler(nil, POSIXError(.EINVAL))
//        }
//        guard let data = self.localXattrStore.value(named: key, forPath: ptItem.smbPath) else {
//            return replyHandler(nil, POSIXError(.ENOATTR))
//        }
//        replyHandler(data, nil)
//    }
//
//    @objc(setXattrNamed:toData:onItem:policy:replyHandler:)
//    public func setXattr(named name: FSFileName,
//                         to value: Data?,
//                         on item: FSItem,
//                         policy: FSVolume.SetXattrPolicy,
//                         replyHandler: @escaping ((any Error)?) -> Void) {
//        guard let ptItem = item as? SMBKeepFSItem, let key = name.string else {
//            return replyHandler(POSIXError(.EINVAL))
//        }
//        let exists = self.localXattrStore.value(named: key, forPath: ptItem.smbPath) != nil
//        switch policy {
//        case .delete:
//            self.localXattrStore.set(nil, named: key, forPath: ptItem.smbPath)
//            return replyHandler(nil)
//        case .mustCreate where exists:
//            return replyHandler(POSIXError(.EEXIST))
//        case .mustReplace where !exists:
//            return replyHandler(POSIXError(.ENOATTR))
//        default:
//            self.localXattrStore.set(value, named: key, forPath: ptItem.smbPath)
//            return replyHandler(nil)
//        }
//    }
//
//    @objc(listXattrsOfItem:replyHandler:)
//    public func listXattrs(of item: FSItem,
//                           replyHandler: @escaping ([FSFileName]?, (any Error)?) -> Void) {
//        guard let ptItem = item as? SMBKeepFSItem else {
//            return replyHandler(nil, POSIXError(.EINVAL))
//        }
//        let names = self.localXattrStore.names(forPath: ptItem.smbPath).map { FSFileName(string: $0) }
//        replyHandler(names, nil)
//    }
//}

/// A tiny thread-safe, persistent store for local-only xattrs, keyed by SMB path.
//final class SMBKeepLocalXattrStore {
//    private let fileURL: URL?
//    private let lock = NSLock()
//    private var map: [String: [String: Data]]
//
//    init(connectionID: String) {
//        let appGroupID = "xiaogd.com.SMBKeep"
//        if let container = FileManager.default
//            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
//            let dir = container.appendingPathComponent("xattrs", isDirectory: true)
//            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
//            let url = dir.appendingPathComponent("\(connectionID).plist")
//            self.fileURL = url
//            if let data = try? Data(contentsOf: url),
//               let decoded = try? PropertyListDecoder().decode([String: [String: Data]].self, from: data) {
//                self.map = decoded
//            } else {
//                self.map = [:]
//            }
//        } else {
//            self.fileURL = nil
//            self.map = [:]
//        }
//    }
//
//    func value(named name: String, forPath path: String) -> Data? {
//        self.lock.lock(); defer { self.lock.unlock() }
//        return self.map[path]?[name]
//    }
//
//    func names(forPath path: String) -> [String] {
//        self.lock.lock(); defer { self.lock.unlock() }
//        return Array(self.map[path]?.keys ?? Dictionary<String, Data>().keys)
//    }
//
//    func set(_ value: Data?, named name: String, forPath path: String) {
//        self.lock.lock()
//        if let value {
//            self.map[path, default: [:]][name] = value
//        } else {
//            self.map[path]?.removeValue(forKey: name)
//            if self.map[path]?.isEmpty == true { self.map.removeValue(forKey: path) }
//        }
//        let snapshot = self.map
//        let url = self.fileURL
//        self.lock.unlock()
//
//        guard let url, let data = try? PropertyListEncoder().encode(snapshot) else { return }
//        try? data.write(to: url, options: .atomic)
//    }
//}
