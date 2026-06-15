/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
实现以 SMB（AMSMB2）为后端的简化文件系统的自定义类。
*/

import Darwin
import Foundation
import FSKit

#if DEBUG
/// 当前进程是否已被调试器 attach（通过 `P_TRACED` 标志判断）。
private func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
        return false
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}

/// 仅 active（loadResource）实例会调用；probe 实例不受影响。
/// 挂载后在此阻塞，直到 Xcode attach 到本 PID。
private func waitForDebuggerAttach() {
    let pid = getpid()
    TimestampedLogger.smbkeepfs.debug("loadResource active PID=\(pid)，等待调试器 attach…")
    while !isDebuggerAttached() {
        sleep(1)
    }
    TimestampedLogger.smbkeepfs.debug("调试器已 attach，继续 loadResource (PID=\(pid))")
}
#endif

extension TimestampedLogger {
    static let smbkeepfs = TimestampedLogger(subsystem: "com.apple.fskit.SMBKeepFS", category: "default")
}

/// 把当前的 `errno` 值包装成 `POSIXError` 返回。
var posixErrno: POSIXError {
    POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
}

/// 返回给定闭包的结果；若 `errno` 非零则抛出错误。
func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    let ret = try block()
    guard ret >= 0 else {
        guard errno != 0 else {
            TimestampedLogger.smbkeepfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

/// 从 FSKit 交给扩展的 `FSPathURLResource` 中读取本次挂载的 SMB 配置。
/// 主 App 把一个每连接独立的目录（内含 `mount-config.json`）作为挂载的 *source* 传入，
/// 由于设置了 `FSRequiresSecurityScopedPathURLResources`，FSKit 会授予对它的安全作用域访问权限。
///
/// 这是 FSKit 扩展唯一可行的通道：App Group 容器不会暴露给扩展的沙盒，
/// 因此从那里读取共享文件会失败。从该资源读取还能让每次挂载的配置相互独立，
/// 这正是允许多个连接同时挂载的前提。
private func loadConfig(from resource: FSResource) -> SMBConfiguration? {
    guard let urlResource = resource as? FSPathURLResource else {
        TimestampedLogger.smbkeepfs.error("Resource is not an FSPathURLResource: \(type(of: resource))")
        return nil
    }
    let url = urlResource.url
    let didStart = url.startAccessingSecurityScopedResource()
    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
    return SMBConfiguration.load(fromSourceDirectory: url)
}

/// 通过 FSKit 暴露一个 SMB 共享的文件系统。
@objc
class SMBKeepFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var loadedVolume: SMBKeepFSVolume?

    public override init() {
        super.init()
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
//#if DEBUG
//        waitForDebuggerAttach()
//#endif

        guard let smbConfig = loadConfig(from: resource) else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        // 用从挂载 source 读到的配置初始化 SMB 后端。
        let backend = SMBBackend(config: smbConfig)
        let volumeName = FSFileName(string: smbConfig.displayName + smbConfig.volumeNameSuffix)
        let volume: SMBKeepFSVolume
        do {
            volume = try SMBKeepFSVolume(backend: backend,
                                         volumeName: volumeName,
                                         smbConfig: smbConfig)
        } catch {
            TimestampedLogger.smbkeepfs.error("\(#function): volume setup failed: \(error)")
            return replyHandler(nil, error)
        }
        self.loadedVolume = volume

        // 异步建立 SMB 连接，连接成功后再上报就绪。
        Task {
            do {
                try await backend.connect()
                self.containerStatus = .ready
                volume.log("Volume mounted: \(smbConfig.displayName) at \(smbConfig.serverURL)/\(smbConfig.shareName)")
                replyHandler(volume, nil)
            } catch {
                TimestampedLogger.smbkeepfs.error("\(#function): SMB connect failed: \(error)")
                self.loadedVolume = nil
                replyHandler(nil, error)
            }
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions,
                               replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let volume = self.loadedVolume {
            volume.log("Volume unmounted: \(volume.volumeLabel)")
            volume.smb.disconnect()
        }
        self.loadedVolume = nil
        return reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let config = loadConfig(from: resource) else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let name = config.displayName + config.volumeNameSuffix
        // 从连接派生出稳定的 container ID，让每个连接得到各自独立的 container，
        // 从而多个挂载之间不会冲突。
        let containerUUID = UUID(uuidString: config.connectionID) ?? UUID()
        let containerID = FSContainerIdentifier(uuid: containerUUID)
        let probeResult = FSProbeResult.usable(name: name, containerID: containerID)
        return replyHandler(probeResult, nil)
    }
}
