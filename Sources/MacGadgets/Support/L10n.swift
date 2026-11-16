import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en = "en"
    case fr = "fr"
    case de = "de"
    case es = "es"
    case it = "it"
    case pt = "pt"
    case ru = "ru"
    case ar = "ar"
    case tr = "tr"
    case ja = "ja"
    case ko = "ko"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"

    var id: String { rawValue }

    /// Native display name shown in the language picker.
    var nativeName: String {
        switch self {
        case .system: return L10n.tr("language.system_default")
        case .en: return "English"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ar: return "اللغة العربية"
        case .tr: return "Türkçe"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }

    var isRTL: Bool {
        self == .ar
    }

    static var selectableLanguages: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    /// Resolves a macOS preferred language identifier (e.g. "zh-CN", "pt-BR", "en-US") to a supported language.
    static func resolveSystemLanguage(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for raw in preferred {
            let lower = raw.lowercased()
            if lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") {
                return .zhHans
            }
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return .zhHant
            }
            if lower.hasPrefix("zh") {
                return .zhHans
            }
            if let prefix = lower.split(separator: "-").first.map(String.init),
               let matched = AppLanguage(rawValue: prefix),
               matched != .system {
                return matched
            }
        }
        return .en
    }
}

/// Thread-safe localization lookup backed by `.lproj/Localizable.strings`.
enum L10n {
    private static let lock = NSLock()
    private static let defaultsKey = "MacGadgets.appLanguage"
    private static var cachedSelection: AppLanguage = loadInitialSelection()
    private static var cachedBundle: Bundle? = resolveBundle(for: effectiveLanguage(for: cachedSelection))
    private static var fallbackEnglishBundle: Bundle? = resolveBundle(for: .en)

    static var currentSelection: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return cachedSelection
    }

    static var effectiveLanguage: AppLanguage {
        lock.lock()
        let selection = cachedSelection
        lock.unlock()
        return effectiveLanguage(for: selection)
    }

    static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        cachedSelection = language
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        cachedBundle = resolveBundle(for: effectiveLanguage(for: language))
        lock.unlock()
    }

    static func tr(_ key: String) -> String {
        lock.lock()
        let bundle = cachedBundle
        let fallback = fallbackEnglishBundle
        lock.unlock()

        if let bundle {
            let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" {
                return value
            }
        }
        if let fallback {
            let value = fallback.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" {
                return value
            }
        }
        return key
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, locale: Locale.current, arguments: args)
    }

    private static func loadInitialSelection() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let lang = AppLanguage(rawValue: raw) else {
            return .system
        }
        return lang
    }

    private static func effectiveLanguage(for selection: AppLanguage) -> AppLanguage {
        selection == .system ? AppLanguage.resolveSystemLanguage() : selection
    }

    private static func resolveBundle(for language: AppLanguage) -> Bundle? {
        let code = language.rawValue
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        // Fallback for unbundled `swift run` or unit test binaries running from the repo.
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/\(code).lproj"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(code).lproj")
        ]
        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published private(set) var selection: AppLanguage

    var effectiveLanguage: AppLanguage {
        selection == .system ? AppLanguage.resolveSystemLanguage() : selection
    }

    var layoutDirection: LayoutDirection {
        effectiveLanguage.isRTL ? .rightToLeft : .leftToRight
    }

    var onLanguageChange: (() -> Void)?

    private init() {
        self.selection = L10n.currentSelection
    }

    func select(_ language: AppLanguage) {
        L10n.setLanguage(language)
        selection = language
        onLanguageChange?()
    }
}
