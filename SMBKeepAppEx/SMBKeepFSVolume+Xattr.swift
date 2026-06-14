/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
为访达的每文件“打开方式”选择、标签和注释提供扩展属性（xattr）支持。

为避免污染远端 SMB 共享，这些 xattr 持久化保存在本地 App Group 容器里，
而不是写回服务器。实现 `supportedXattrNames(for:)` 会让 FSKit 进入“受限”模式，
只把这几个特定 xattr 路由给我们；其它所有 xattr 保持不变。
*/

import Foundation
import FSKit

/// 访达为每文件“始终用…打开”选择写入的 xattr（仅文件）。
private let openWithXattr = "com.apple.LaunchServices.OpenWith"
/// 访达用于标签和“注释”字段的 xattr（文件和文件夹）。
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

/// 一个以 SMB 路径为键、线程安全的本地 xattr 持久化小存储。
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
