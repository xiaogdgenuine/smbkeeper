/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
通过 FSKit 处理 SMB 共享的挂载与卸载。
*/

import Foundation
import Network
import OSLog

/// 管理 FSKit 卷挂载的生命周期。
@MainActor
class MountManager: ObservableObject {
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var mountOutput: String = ""

    /// 当挂载失败疑似由 FSKit 守护进程陈旧状态引起时，给出建议用户自行在终端执行的命令；
    /// 否则为 nil。App 沙箱不允许提权执行命令，因此交由用户手动重启。
    @Published var fskitRestartCommand: String?

    /// 重启 FSKit 相关守护进程的命令。多数情况下并不需要执行，仅在挂载因陈旧状态失败时建议使用。
    static let fskitRestartCommand = "sudo killall pkd fskitd fskit_agent"

    private let logger = TimestampedLogger(subsystem: "com.example.smbkeep.mount", category: "MountManager")
    private let manager: SMBConnectionManager
    init(manager: SMBConnectionManager) {
        self.manager = manager
    }

    private func mountPoint(for connection: SMBConnection) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.smbkeep"
        let appDir = appSupport.appendingPathComponent(bundleID)
        let mountDir = appDir.appendingPathComponent(connection.displayName.trimmingCharacters(in: .whitespaces))
        try? FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        return mountDir
    }

    /// 挂载一个 SMB 共享。
    /// 写入活动配置，然后通过 mount_fskit 触发扩展。
    func mount(connection: SMBConnection, silent: Bool = false) async -> Bool {
        isBusy = true
        lastError = nil
        mountOutput = ""
        fskitRestartCommand = nil

        guard let sourceDir = manager.writeMountConfig(for: connection.id) else {
            lastError = "无法写入挂载配置"
            isBusy = false
            return false
        }

        // 从主 App 的 bundle 中获取扩展的 bundle identifier。
        guard let extBundleID = Bundle.main.object(forInfoDictionaryKey: "EXTENSION_BUNDLE_ID") as? String
                ?? guessExtensionBundleID() else {
            lastError = "无法确定扩展的 Bundle ID"
            isBusy = false
            return false
        }

        let mountPoint = mountPoint(for: connection).path

        // 挂载前先注册扩展，避免 extensionKit error 2。
        await registerExtension()

        if let preflightError = await preflightLocalSMBAccess(for: connection) {
            mountOutput += "=== local network preflight ===\n\(preflightError)\n\n"
            logger.error("Local network preflight failed: \(preflightError)")
        }

        // 尝试多种挂载方式。
        let result = await runMountCommand(extBundleID: extBundleID, sourceDir: sourceDir.path, mountPoint: mountPoint, connection: connection, silent: silent)

        if result {
            // 扩展已在 loadResource 中读过配置，因此立刻从磁盘擦除明文凭据。
            // 保留（现已为空的）source 目录，让挂载的 source 路径继续有效。
            manager.removeMountConfigFile(for: connection.id)
            manager.markMounted(connection.id)
            logger.debug("Mounted \(connection.displayName)")
        } else {
            manager.clearMountConfig(for: connection.id)
        }

        isBusy = false
        return result
    }

    /// 卸载一个 SMB 共享。
    func unmount(connection: SMBConnection) async -> Bool {
        isBusy = true
        lastError = nil

        let mountPoint = mountPoint(for: connection).path

        guard await isMountPointMounted(mountPoint) else {
            mountOutput += "挂载点已经不在 mount 表中，按已卸载处理\n"
            manager.markUnmounted(connection.id)
            manager.clearMountConfig(for: connection.id)
            isBusy = false
            return true
        }

        let result = await runUnmountCommand(mountPoint: mountPoint, connection: connection)

        if result {
            manager.markUnmounted(connection.id)
            manager.clearMountConfig(for: connection.id)
            logger.debug("Unmounted \(connection.displayName)")
        }

        isBusy = false
        return result
    }

    // MARK: - 私有

    private func guessExtensionBundleID() -> String? {
        let mainBundleID = Bundle.main.bundleIdentifier ?? ""
        return mainBundleID + ".AppEx"
    }

    private func registerExtension() async {
        guard let extBundleID = Bundle.main.object(forInfoDictionaryKey: "EXTENSION_BUNDLE_ID") as? String
                ?? guessExtensionBundleID() else {
            return
        }
        // 确保扩展处于启用状态即可。实测无需每次都 ignore/use 来强制 fskitd 释放陈旧状态，
        // 那样反而拖慢挂载；陈旧状态仅在挂载失败时再处理。
        let enableOutput = await runShellCommand("pluginkit -e use -i \"\(extBundleID)\" 2>&1")
        mountOutput += "=== pluginkit enable ===\n\(enableOutput)\n"
    }

    private func preflightLocalSMBAccess(for connection: SMBConnection) async -> String? {
        guard let url = URL(string: connection.serverURL),
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 445)) else {
            return nil
        }

        let queue = DispatchQueue(label: "com.example.smbkeep.network-preflight")
        let nwConnection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didFinish = false
            var waitingError: NWError?

            func finish(_ message: String?) {
                lock.lock()
                guard !didFinish else {
                    lock.unlock()
                    return
                }
                didFinish = true
                lock.unlock()

                nwConnection.cancel()
                continuation.resume(returning: message)
            }

            nwConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(nil)
                case .waiting(let error):
                    lock.lock()
                    waitingError = error
                    lock.unlock()
                case .failed(let error):
                    finish("Could not reach \(host):\(port.rawValue): \(error)")
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + 5) {
                lock.lock()
                let error = waitingError
                lock.unlock()

                if let error {
                    finish("Could not reach \(host):\(port.rawValue): \(error)")
                } else {
                    finish("Timed out connecting to \(host):\(port.rawValue)")
                }
            }

            nwConnection.start(queue: queue)
        }
    }

    private func runMountCommand(extBundleID: String, sourceDir: String, mountPoint: String, connection: SMBConnection, silent: Bool = false) async -> Bool {
            // FSKit 扩展通过 mount 命令使用扩展 Info.plist 中的 FSShortName "smbkeep"。
            // `-F` 强制走 FSKit 路由；source 参数是每连接独立的配置目录，
            // FSKit 会把它作为带安全作用域的 FSPathURLResource 交给扩展。
            let commands: [(title: String, command: String)] = [
                // 尝试 1：用短名 "smbkeep" 挂载（来自 Info.plist 的 FSShortName）
                ("mount -F -t smbkeep",
                 "/sbin/mount -F -t smbkeep \"\(sourceDir)\" \"\(mountPoint)\" 2>&1"),
            ]

            for (name, cmd) in commands {
                logger.debug("Trying \(name)...")
                let output = await runShellCommand(cmd)
                mountOutput += "=== \(name) ===\n=== \(cmd) ===\n\(output)\n\n"

                let lower = output.lowercased()
                if !lower.contains("failed") && !lower.contains("error") && !lower.contains("not found")
                    && !lower.contains("unknown special file") && !lower.contains("no such file") {
                    // 确认它确实已经挂载
                    if await isMountPointMounted(mountPoint) {
                        return true
                    }
                    // 稍等片刻再检查一次
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if await isMountPointMounted(mountPoint) {
                        return true
                    }
                }
            }

            // App 沙箱不允许提权执行命令，因此不再自动重启 fskitd。
            // 仅在挂载失败疑似由 FSKit 守护进程陈旧状态引起时，提示用户自行在终端重启。
            if mountOutputIndicatesStaleFSKitState() {
                fskitRestartCommand = Self.fskitRestartCommand
                lastError = """
                    挂载失败，疑似 FSKit 守护进程状态陈旧。

                    请在「终端」中执行下方命令重启 fskitd，然后重新挂载（多数情况下并不需要这一步）：
                    \(Self.fskitRestartCommand)

                    扩展 Bundle ID: \(extBundleID)
                    """
            } else {
                lastError = """
                    所有自动挂载方法均失败。

                    请确保系统扩展已被批准：打开「系统设置 → 通用 → 登陆项与扩展 → 扩展 → 按类别 → 文件系统扩展 → ⓘ → 启用 SMBKeep File System」

                    扩展 Bundle ID: \(extBundleID)
                    """
            }
            return false
        }

    /// 根据累计的挂载命令输出，判断失败是否疑似源于 FSKit 守护进程持有的陈旧状态。
    private func mountOutputIndicatesStaleFSKitState() -> Bool {
        let lower = mountOutput.lowercased()
        return lower.contains("extensionkit.errordomain")
            || lower.contains("file system named")
            || lower.contains("filesystem named")
    }

    private func runUnmountCommand(mountPoint: String, connection: SMBConnection) async -> Bool {
        let commands: [(title: String, command: String)] = [
            ("diskutil unmount", "diskutil unmount \"\(mountPoint)\" 2>&1"),
            ("diskutil unmount force", "diskutil unmount force \"\(mountPoint)\" 2>&1"),
            ("umount", "umount -f \"\(mountPoint)\" 2>&1"),
            ("umount force", "umount -f \"\(mountPoint)\" 2>&1"),
        ]

        for (name, cmd) in commands {
            logger.debug("Trying \(name)...")
            let output = await runShellCommand(cmd)
            mountOutput += "=== \(name) ===\n\(output)\n\n"

            let lower = output.lowercased()
            if lower.contains("not currently mounted") || lower.contains("no such file")
                || lower.contains("not mounted") {
                if !(await isMountPointMounted(mountPoint)) {
                    mountOutput += "挂载点已经卸载，忽略卸载命令错误\n"
                    return true
                }
            }

            if !lower.contains("failed") && !lower.contains("resource busy") {
                if !(await isMountPointMounted(mountPoint)) {
                    return true
                }
            }
        }

        // 检查它是否已经不在挂载状态
        if !(await isMountPointMounted(mountPoint)) {
            mountOutput += "卷宗似乎已经卸载\n"
            return true
        }

        lastError = "卸载失败，请尝试: diskutil unmount force \"\(mountPoint)\""
        return false
    }

    private func isMountPointMounted(_ mountPoint: String) async -> Bool {
        let marker = " on \(mountPoint) "
        let command = "mount | grep -F \(shellQuoted(marker))"
        let output = await runShellCommand(command)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runShellCommand(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", command]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            task.terminationHandler = { _ in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: output + error)
            }

            do {
                try task.run()
            } catch {
                continuation.resume(returning: "Error: \(error)")
            }
        }
    }
}
