import Foundation

/// Where Shotnix's text comes from. Every user-visible string goes through
/// `L(_:)`; English strings are the keys. The translations live in one String
/// Catalog, Localization/Localizable.xcstrings, which scripts/localize.py
/// keeps in step with the code and compiles into the resource bundle's
/// .lproj folders. macOS picks the language: the Mac's own, or the one set for
/// Shotnix in System Settings → General → Language & Region.
enum L10n {
    /// Languages Shotnix is translated into, besides English.
    static let translations = ["de", "fr", "zh-Hans", "ru", "uk"]

    /// The bundle strings are looked up in. Tests point it at one language.
    nonisolated(unsafe) static var bundle: Bundle = defaultBundle

    /// The locale that formats numbers and picks plural forms: the user's,
    /// or the language tests point `use(_:)` at, whatever the Mac's region.
    nonisolated(unsafe) static var locale: Locale = .autoupdatingCurrent

    private static var defaultBundle: Bundle { ShotnixResources.bundle ?? .main }

    /// Looks every string up in one language (tests and snapshots), or the
    /// user's languages again with nil.
    static func use(_ language: String?) {
        // SwiftPM lowercases folder names when it builds the resource bundle
        // (zh-Hans.lproj becomes zh-hans.lproj); macOS matches either case.
        guard let language,
              let path = defaultBundle.path(forResource: language, ofType: "lproj")
                ?? defaultBundle.path(forResource: language.lowercased(), ofType: "lproj"),
              let lproj = Bundle(path: path) else {
            bundle = defaultBundle
            locale = .autoupdatingCurrent
            return
        }
        bundle = lproj
        locale = Locale(identifier: language)
    }
}

/// User-visible text in the user's language: `L("Save")`,
/// `L("\(count) captures")`. Interpolated values become placeholders
/// (%lld, %@), so each language can place them where its grammar needs.
/// The compiler extracts every call when scripts/localize.py runs.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: nil, bundle: L10n.bundle, locale: L10n.locale)
}
