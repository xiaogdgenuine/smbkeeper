/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Handles mounting and unmounting of SMB shares via FSKit.
*/

import Foundation
import OSLog

/// Manages the lifecycle of an FSKit volume mount.
@MainActor
class MountManager: ObservableObject {
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var mountOutput: String = ""

    private let logger = Logger(subsystem: "com.example.smbkeep.mount", category: "MountManager")
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

    /// Mount an SMB share.
    /// Writes the active config then triggers the extension via mount_fskit.
    /// Pass `silent: true` for unattended (login) mounts: it suppresses the
    /// admin-authorization fallback that would otherwise show a password prompt.
    func mount(connection: SMBConnection, silent: Bool = false) async -> Bool {
        isBusy = true
        lastError = nil
        mountOutput = ""

        guard let sourceDir = manager.writeMountConfig(for: connection.id) else {
            lastError = "无法写入挂载配置"
            isBusy = false
            return false
        }

        // Get the extension bundle identifier from the main app's bundle.
        guard let extBundleID = Bundle.main.object(forInfoDictionaryKey: "EXTENSION_BUNDLE_ID") as? String
                ?? guessExtensionBundleID() else {
            lastError = "无法确定扩展的 Bundle ID"
            isBusy = false
            return false
        }

        let mountPoint = mountPoint(for: connection).path

        // Register the extension before mounting to avoid stale ExtensionKit /
        // FSKit state after rebuilding or replacing the app.
        await registerExtension(extBundleID: extBundleID)

        // Try multiple approaches to mount.
        let result = await runMountCommand(extBundleID: extBundleID, sourceDir: sourceDir.path, mountPoint: mountPoint, connection: connection, silent: silent)

        if result {
            // The extension has already read the config in loadResource, so wipe
            // the plaintext credentials from disk immediately. Keep the (now empty)
            // source directory so the mount's source path stays valid.
            manager.removeMountConfigFile(for: connection.id)
            manager.markMounted(connection.id)
            logger.info("Mounted \(connection.displayName)")
        } else {
            manager.clearMountConfig(for: connection.id)
        }

        isBusy = false
        return result
    }

    /// Unmount an SMB share.
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
            logger.info("Unmounted \(connection.displayName)")
        }

        isBusy = false
        return result
    }

    // MARK: - Private

    private func guessExtensionBundleID() -> String? {
        let mainBundleID = Bundle.main.bundleIdentifier ?? ""
        return mainBundleID + ".AppEx"
    }

    private func registerExtension(extBundleID: String? = nil) async {
        guard let extBundleID = extBundleID
                ?? Bundle.main.object(forInfoDictionaryKey: "EXTENSION_BUNDLE_ID") as? String
                ?? guessExtensionBundleID() else {
            return
        }

        if let extensionURL = embeddedExtensionURL() {
            let registerOutput = await runShellCommand("pluginkit -a \(shellQuoted(extensionURL.path)) 2>&1")
            mountOutput += "=== pluginkit register ===\n\(registerOutput)\n"
        }

        // Disable and re-enable to force fskitd to release stale state.
        _ = await runShellCommand("pluginkit -e ignore -i \"\(extBundleID)\" 2>&1")
        let enableOutput = await runShellCommand("pluginkit -e use -i \"\(extBundleID)\" 2>&1")
        mountOutput += "=== pluginkit refresh ===\n\(enableOutput)\n"
    }

    private func embeddedExtensionURL() -> URL? {
        let extensionName = Bundle.main.object(forInfoDictionaryKey: "EXTENSION_NAME") as? String ?? "SMBKeepAppEx.appex"
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Extensions")
                .appendingPathComponent(extensionName),
            Bundle.main.builtInPlugInsURL?.appendingPathComponent(extensionName),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func runMountCommand(extBundleID: String, sourceDir: String, mountPoint: String, connection: SMBConnection, silent: Bool = false) async -> Bool {
        // FSKit extensions use the mount command with the FSShortName "smbkeep"
        // from the extension's Info.plist. The `-F` flag forces FSKit routing,
        // and the source argument is the per-connection config directory, which
        // FSKit delivers to the extension as a security-scoped FSPathURLResource.
        let commands: [(title: String, command: String)] = [
            // Try 1: mount with short name "smbkeep" (from Info.plist FSShortName)
            ("mount -F -t smbkeep",
             "/sbin/mount -F -t smbkeep \"\(sourceDir)\" \"\(mountPoint)\" 2>&1"),
        ]

        for (name, cmd) in commands {
            logger.info("Trying \(name)...")
            let output = await runShellCommand(cmd)
            mountOutput += "=== \(name) ===\n=== \(cmd) ===\n\(output)\n\n"

            let lower = output.lowercased()
            if !lower.contains("failed") && !lower.contains("error") && !lower.contains("not found")
                && !lower.contains("unknown special file") && !lower.contains("no such file") {
                // Verify it's actually mounted
                if await isMountPointMounted(mountPoint) {
                    return true
                }
                // Wait a bit and check again
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await isMountPointMounted(mountPoint) {
                    return true
                }
            }
        }

        let lowerMountOutput = mountOutput.lowercased()
        let staleFSKitState = lowerMountOutput.contains("extensionkit.errordomain")
            || lowerMountOutput.contains("file system named")
            || lowerMountOutput.contains("filesystem named")
        if staleFSKitState && !silent {
            // fskitd is holding stale state. Restart it via admin auth prompt,
            // then retry the mount once.
            let killed = await runShellCommand("osascript -e 'do shell script \"killall fskitd\" with administrator privileges' 2>&1")
            mountOutput += "=== fskitd restart ===\n\(killed)\n\n"
            if !killed.lowercased().contains("error") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await registerExtension(extBundleID: extBundleID)
                for (name, cmd) in commands {
                    logger.info("Retrying \(name) after fskitd restart...")
                    let retryOutput = await runShellCommand(cmd)
                    mountOutput += "=== retry: \(name) ===\n\(retryOutput)\n\n"
                    if await isMountPointMounted(mountPoint) {
                        return true
                    }
                }
            }
            lastError = """
                fskitd 重启后仍挂载失败。

                挂载点: \(mountPoint)
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

    private func runUnmountCommand(mountPoint: String, connection: SMBConnection) async -> Bool {
        let commands: [(title: String, command: String)] = [
            ("diskutil unmount", "diskutil unmount \"\(mountPoint)\" 2>&1"),
            ("diskutil unmount force", "diskutil unmount force \"\(mountPoint)\" 2>&1"),
            ("umount", "umount -f \"\(mountPoint)\" 2>&1"),
            ("umount force", "umount -f \"\(mountPoint)\" 2>&1"),
        ]

        for (name, cmd) in commands {
            logger.info("Trying \(name)...")
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

        // Check if it's already not mounted
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
