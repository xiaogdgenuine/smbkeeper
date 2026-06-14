/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
通过 SMAppService 将 App 注册为 macOS 登录项，以便在登录时自动挂载卷，
而无需再次打开 App，也无需在启动脚本中存储凭据。
*/

import Foundation
import ServiceManagement
import OSLog

/// 封装 `SMAppService.mainApp`，提供简单的“登录时启动”开关。
///
/// 凭据不会经过这一层：登录启动的 App 在挂载时从 Keychain 读取密码，
/// 因此没有任何敏感信息留在 launch agent、plist 或脚本里。
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    private let logger = TimestampedLogger(subsystem: "com.example.smbkeep.loginitem", category: "LoginItemManager")

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 注册或注销 App 为登录项。
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            logger.error("Login item toggle failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        refresh()
    }
}
