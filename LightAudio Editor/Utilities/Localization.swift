import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case english
    case simplifiedChinese

    static let preferenceKey = "LightAudio.AppLanguage"

    var resourceIdentifier: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        }
    }

    static var preferred: AppLanguage {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: preferenceKey),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }

    static func resolvedIdentifier(
        preference: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        if let identifier = preference.resourceIdentifier {
            return identifier
        }
        guard let preferred = preferredLanguages.first?.lowercased() else { return "en" }
        if preferred.hasPrefix("zh-hans") || preferred.hasPrefix("zh-cn") || preferred.hasPrefix("zh-sg") {
            return "zh-Hans"
        }
        return "en"
    }
}

enum L10n {
    // Keep the active language stable for the lifetime of an editing session.
    // Preferences update the next-launch choice rather than rebuilding live UI.
    static let activeLanguageIdentifier = AppLanguage.resolvedIdentifier(preference: AppLanguage.preferred)

    private static let translations = translationTable(
        languageIdentifier: activeLanguageIdentifier,
        bundle: .main
    )

    static var locale: Locale {
        Locale(identifier: activeLanguageIdentifier)
    }

    static func tr(_ key: String) -> String {
        translations[key] ?? key
    }

    static func translated(
        _ key: String,
        languageIdentifier: String,
        bundle: Bundle = .main
    ) -> String {
        translationTable(languageIdentifier: languageIdentifier, bundle: bundle)[key] ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }

    private static func translationTable(
        languageIdentifier: String,
        bundle: Bundle
    ) -> [String: String] {
        guard languageIdentifier != "en",
              let url = bundle.url(
                forResource: languageIdentifier,
                withExtension: "json",
                subdirectory: "Localization"
              ),
              let data = try? Data(contentsOf: url),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dictionary
    }
}
