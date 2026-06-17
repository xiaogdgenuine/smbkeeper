/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
卷级别的内存缓存，统一收敛到单一串行队列之后。

历史上这些缓存散落在卷里、由「一个 DispatchQueue + 两个 NSLock」分别守护，既要记住每份状态
归哪把锁管、又有嵌套加锁（枚举锁里再拿子项锁）和跨缓存的非原子更新，是多线程 bug 的高发区。
这里把四份状态——inode→item 映射、目录子项查找表、目录枚举快照、文件系统统计——全部限定在同一个
串行队列 `queue` 上访问。所有方法都用 `queue.sync` 做一次进出，绝不在持有队列时回调外部代码，
因此既无锁顺序问题、也无重入死锁；每份状态的可变访问都只有这一个入口。
*/

import Foundation

/// 卷级别共享缓存的唯一持有者；所有可变状态都只在内部串行队列上访问。
final class SMBKeepVolumeCache {

    private let queue = DispatchQueue(label: "com.apple.fskit.smbkeepfs.cache.queue")

    /// inode → item，跨 lookup/getattr/reclaim 复用 FSKit item 身份。
    private var itemsByInode: [UInt64: SMBKeepFSItem] = [:]

    /// 父目录 inode → （子项名 → item），保存最近一次枚举出的子项，省去 lookup 时的额外 stat。
    private var childrenByParentInode: [UInt64: [String: SMBKeepFSItem]] = [:]

    /// 目录 inode → 最近一次枚举快照（用于 readdir 分页一致性与 TTL 内复用）。
    private var enumerationByInode: [UInt64: SMBKeepDirectorySnapshot] = [:]
    /// 单调递增的快照代号，用作 FSKit 的 directory verifier。
    private var enumerationGeneration: UInt64 = 0

    /// 最近一次已知的文件系统统计信息（`volumeStatistics` 同步读取，后台刷新）。
    private var fsAttributes: [FileAttributeKey: any Sendable]?

    /// 枚举快照数量上限；超过即整体清空，避免无界增长。
    private static let maxEnumerationSnapshots = 64

    // MARK: - item 身份缓存

    func item(forInode inode: UInt64) -> SMBKeepFSItem? {
        queue.sync { itemsByInode[inode] }
    }

    func setItem(_ item: SMBKeepFSItem, forInode inode: UInt64) {
        queue.sync { itemsByInode[inode] = item }
    }

    func removeItem(forInode inode: UInt64) {
        queue.sync { _ = itemsByInode.removeValue(forKey: inode) }
    }

    /// 重命名后原子地搬移 item 身份：删除旧 inode、登记新 inode，并清掉被覆盖项（如有）。
    func reassignItem(_ item: SMBKeepFSItem, fromInode oldInode: UInt64,
                      toInode newInode: UInt64, replacingInode overInode: UInt64?) {
        queue.sync {
            itemsByInode.removeValue(forKey: oldInode)
            itemsByInode[newInode] = item
            if let overInode, overInode != newInode {
                itemsByInode.removeValue(forKey: overInode)
            }
        }
    }

    // MARK: - 目录子项查找缓存

    func child(named name: String, parentInode: UInt64) -> SMBKeepFSItem? {
        queue.sync { childrenByParentInode[parentInode]?[name] }
    }

    /// 登记一次枚举出的子项：同时写入子项查找表和 inode→item 映射（一次进出、保证一致）。
    func registerChildren(_ byName: [String: SMBKeepFSItem], parentInode: UInt64) {
        queue.sync {
            childrenByParentInode[parentInode] = byName
            for item in byName.values {
                itemsByInode[item.inode] = item
            }
        }
    }

    // MARK: - 目录枚举快照缓存

    /// 取出可复用的枚举快照：续读（cookie≠0 且 verifier 匹配）总是复用同一份以保证分页一致；
    /// 全新打开（cookie/verifier 均为 0）仅在 TTL 内复用，超时则返回 nil 以重新拉取反映外部变更。
    func enumerationSnapshot(forInode inode: UInt64, cookie: UInt64, verifier: UInt64,
                             ttl: TimeInterval) -> SMBKeepDirectorySnapshot? {
        queue.sync {
            guard let cached = enumerationByInode[inode] else { return nil }
            let matchesResume = cookie != 0 && cached.verifier == verifier
            let isFresh = Date().timeIntervalSince(cached.createdAt) < ttl
            let matchesFreshOpen = cookie == 0 && verifier == 0 && isFresh
            return (matchesResume || matchesFreshOpen) ? cached : nil
        }
    }

    /// 存入一份新的枚举快照并返回它（带新生成的 verifier）。超过上限时整体清空枚举/子项缓存。
    @discardableResult
    func storeEnumeration(forInode inode: UInt64, entries: [SMBKeepDirEntry]) -> SMBKeepDirectorySnapshot {
        queue.sync {
            enumerationGeneration += 1
            let snapshot = SMBKeepDirectorySnapshot(verifier: enumerationGeneration, entries: entries)
            if enumerationByInode.count >= Self.maxEnumerationSnapshots {
                enumerationByInode.removeAll(keepingCapacity: true)
                childrenByParentInode.removeAll(keepingCapacity: true)
            }
            enumerationByInode[inode] = snapshot
            return snapshot
        }
    }

    // MARK: - 失效

    /// 让某个目录 inode 的枚举快照与子项查找一并失效（内容可能已变更）。
    func invalidateDirectory(inode: UInt64) {
        guard inode != 0 else { return }
        queue.sync {
            enumerationByInode.removeValue(forKey: inode)
            childrenByParentInode.removeValue(forKey: inode)
        }
    }

    /// 清空全部目录相关缓存（枚举快照 + 子项查找）；保留 inode→item 身份映射。
    func clearDirectoryCaches() {
        queue.sync {
            enumerationByInode.removeAll(keepingCapacity: true)
            childrenByParentInode.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - 文件系统统计

    func cachedFileSystemAttributes() -> [FileAttributeKey: any Sendable]? {
        queue.sync { fsAttributes }
    }

    func setFileSystemAttributes(_ attributes: [FileAttributeKey: any Sendable]) {
        queue.sync { fsAttributes = attributes }
    }
}
