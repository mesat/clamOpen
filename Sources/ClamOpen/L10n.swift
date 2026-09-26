import Foundation

/// 界面语言：系统首选语言为中文时显示中文，其余一律显示英文。
/// 可单独为本 App 指定语言，例如：
///   defaults write com.clamopen.app AppleLanguages '("en")'
enum L10n {
    static let isChinese: Bool = {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return lang.hasPrefix("zh")
    }()
}

/// 按当前界面语言返回英文或中文文案
func tr(_ en: String, _ zh: String) -> String {
    L10n.isChinese ? zh : en
}
