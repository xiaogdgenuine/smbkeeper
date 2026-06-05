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

    private let logger = Logger(subsystem: "com.example.passthrough.mount", category: "MountManager")
    private let manager: SMBConnectionManager

    init(manager: SMBConnectionManager) {
        self.manager = manager
    }

    /// Mount an SMB share.
    /// Writes the active config then triggers the extension via mount_fskit.
    func mount(connection: SMBConnection) async -> Bool {
        isBusy = true
        lastError = nil
        mountOutput = ""

        guard manager.writeActiveConfig(for: connection.id) else {
            lastError = "无法写入配置到共享容器"
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

        // Build the mount command.
        // FSKit extension mount: use mount_fskit or the newer fsutil.
        let mountPoint = "/Volumes/\(connection.displayName.trimmingCharacters(in: .whitespaces))"

        // Try multiple approaches to mount.
        let result = await runMountCommand(extBundleID: extBundleID, mountPoint: mountPoint, connection: connection)

        if result {
            manager.markMounted(connection.id)
            logger.info("Mounted \(connection.displayName)")
        } else {
            manager.clearActiveConfig()
        }

        isBusy = false
        return result
    }

    /// Unmount an SMB share.
    func unmount(connection: SMBConnection) async -> Bool {
        isBusy = true
        lastError = nil

        let mountPoint = "/Volumes/\(connection.displayName.trimmingCharacters(in: .whitespaces))"

        let result = await runUnmountCommand(mountPoint: mountPoint, connection: connection)

        if result {
            manager.markUnmounted(connection.id)
            manager.clearActiveConfig()
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

    private func runMountCommand(extBundleID: String, mountPoint: String, connection: SMBConnection) async -> Bool {
        // FSKit extensions use the mount command with the FSShortName "passthrough"
        // from the extension's Info.plist.
        let displayName = connection.displayName.trimmingCharacters(in: .whitespaces)
        let shareName = connection.shareName.trimmingCharacters(in: .whitespaces)

        // Create the mount point directory
        _ = await runShellCommand("mkdir -p \"\(mountPoint)\"")

        let commands: [(title: String, command: String)] = [
            // Try 1: mount with short name "passthrough" (from Info.plist FSShortName)
            ("mount -t passthrough",
             "mount -t passthrough \"\(shareName)\" \"\(mountPoint)\""),

            // Try 2: With explicit extension option
            ("mount -t passthrough (extension)",
             "mount -t passthrough -o extension=\(extBundleID) \"\(shareName)\" \"\(mountPoint)\""),

            // Try 3: activate extension first then mount
            ("systemextensionsctl + mount",
             "systemextensionsctl developer on 2>/dev/null; mount -t passthrough \"\(shareName)\" \"\(mountPoint)\" 2>&1"),
        ]

        for (name, cmd) in commands {
            logger.info("Trying \(name)...")
            let output = await runShellCommand(cmd)
            mountOutput += "=== \(name) ===\n\(output)\n\n"

            let lower = output.lowercased()
            if !lower.contains("failed") && !lower.contains("error") && !lower.contains("not found")
                && !lower.contains("unknown special file") && !lower.contains("no such file") {
                // Verify it's actually mounted
                let checkOutput = await runShellCommand("mount | grep \"\(displayName)\"")
                if !checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                // Wait a bit and check again
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let checkOutput2 = await runShellCommand("mount | grep \"\(displayName)\"")
                if !checkOutput2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
        }

        let helpMsg = """
            所有自动挂载方法均失败。

            请确保：
            1. 系统扩展已被批准：打开「系统设置 → 隐私与安全性」，查看是否有关于 "Passthrough" 扩展的批准提示
            2. 尝试手动挂载：
               mount -t passthrough "\(shareName)" "\(mountPoint)"
            3. 或使用 diskutil 挂载：
               diskutil apfs mount -mountPoint "\(mountPoint)" <disk-id>

            扩展 Bundle ID: \(extBundleID)
            """
        lastError = helpMsg
        return false
    }

    private func runUnmountCommand(mountPoint: String, connection: SMBConnection) async -> Bool {
        let displayName = connection.displayName.trimmingCharacters(in: .whitespaces)

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
            if !lower.contains("failed") && !lower.contains("not currently mounted")
                && !lower.contains("resource busy") && !lower.contains("no such file") {
                // Check if unmounted
                let checkOutput = await runShellCommand("mount | grep \"\(displayName)\"")
                if checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
        }

        // Check if it's already not mounted
        let checkOutput = await runShellCommand("mount | grep \"\(displayName)\"")
        if checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mountOutput += "卷宗似乎已经卸载\n"
            return true
        }

        lastError = "卸载失败，请尝试: diskutil unmount force \"\(mountPoint)\""
        return false
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
