/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
管理应用内的界面语言强制切换：在「跟随系统 / 英文 / 简体中文」之间选择，
通过 SwiftUI 的 `\.locale` 环境值即时作用于界面，并持久化用户选择。
*/

import Foundation
import SwiftUI

/// 应用内可供选择的界面语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    /// 跟随系统语言（不强制）。
    case system
    /// 英文。
    case english = "en"
    /// 简体中文。
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 具体语言用其母语名称展示，便于用户在任何当前界面语言下都能识别；
    /// 「跟随系统」没有母语名称（返回 nil），由调用方用可本地化文案展示。
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// 维护用户选择的界面语言，并提供注入 SwiftUI 环境用的 `Locale`，
/// 以及供模型层 `String(localized:)` 强制查表用的 `Bundle`。
///
/// 实现方式：通过 SwiftUI 的 `\.locale` 环境值强制切换，立即生效、无需重启。
/// 这里刻意不改写 `AppleLanguages`，因此「跟随系统」始终能反映真实的系统语言，
/// 行为可预期。代价是 macOS 菜单栏与系统权限弹窗仍跟随系统语言——这是系统界面的固有行为。
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "AppSelectedLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        language = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// 当前生效的 `Locale`，注入到 SwiftUI 环境中驱动所有 `Text` 等控件的本地化查表。
    var locale: Locale {
        switch language {
        case .system:
            return .autoupdatingCurrent
        case .english, .simplifiedChinese:
            return Locale(identifier: language.rawValue)
        }
    }

    /// 与所选语言对应的 `.lproj` Bundle。用于非 SwiftUI 文案（如 `String(localized:)`），
    /// 因为这些 API 默认用启动时固定的 `.current`，无法随应用内切换即时更新。
    var bundle: Bundle {
        switch language {
        case .system:
            return .main
        case .english, .simplifiedChinese:
            if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
            return .main
        }
    }
}
