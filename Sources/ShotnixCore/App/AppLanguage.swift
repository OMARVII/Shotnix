import Foundation

/// The language chosen for Shotnix in Settings → General. It is stored the
/// way System Settings → General → Language & Region → Applications stores
/// it, so the two always agree: an "AppleLanguages" array in Shotnix's own
/// defaults domain (["de"]), and no key to follow the Mac. macOS reads it at
/// launch, so a new choice applies after a restart.
struct AppLanguage {
    static let key = "AppleLanguages"

    /// English, then every language Shotnix is translated into.
    static var all: [String] { ["en"] + L10n.translations }

    private let defaults: UserDefaults
    private let domain: String

    /// Shotnix's own defaults; tests pass a throwaway suite and its name.
    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "com.shotnix.app") {
        self.defaults = defaults
        self.domain = domain
    }

    /// The language chosen for Shotnix, or nil to follow the Mac. Read from
    /// Shotnix's own domain: `defaults.array(forKey:)` would also find the
    /// Mac's languages in the global domain.
    var choice: String? {
        get {
            let stored = defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
            return stored?.first.flatMap(Self.language(matching:))
        }
        nonmutating set {
            if let newValue {
                defaults.set([newValue], forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Which of Shotnix's languages an identifier means ("de-AT" is German,
    /// "zh-CN" Simplified Chinese), or nil for a language Shotnix doesn't have.
    static func language(matching identifier: String) -> String? {
        let wanted = Locale.Language(identifier: identifier)
        return all.first {
            let language = Locale.Language(identifier: $0)
            return language.languageCode == wanted.languageCode && language.script == wanted.script
        }
    }

    /// The language Shotnix shows. macOS picks it at launch and keeps it
    /// until Shotnix quits, whatever is stored meanwhile.
    static var shownLanguage: String {
        Bundle.preferredLocalizations(from: all).first ?? "en"
    }

    /// The language Shotnix shows when it follows the Mac: the first of the
    /// Mac's languages it has, else English, as macOS picks it.
    static func systemLanguage(preferring languages: [String] = macLanguages) -> String {
        Bundle.preferredLocalizations(from: all, forPreferences: languages).first ?? "en"
    }

    /// The Mac's languages, leaving out the one chosen for Shotnix.
    static var macLanguages: [String] {
        CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? [String] ?? Locale.preferredLanguages
    }

    /// The language a restart would switch Shotnix to with this choice, or
    /// nil when Shotnix would come back in the language it shows now.
    static func languageAfterRestart(with choice: String?, shown: String = shownLanguage, system: String = systemLanguage()) -> String? {
        let next = choice ?? system
        return next == shown ? nil : next
    }

    /// A language's name in that language, as a list shows it: "English",
    /// "Deutsch", "Français", "简体中文".
    static func endonym(_ language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// A language's name in the language Shotnix shows: "Englisch" in German.
    static func localizedName(_ language: String) -> String {
        L10n.locale.localizedString(forIdentifier: language) ?? endonym(language)
    }
}
