import XCTest
@testable import ShotnixCore

/// Settings → General → Language: the choice lives where System Settings
/// keeps a per-app language (AppleLanguages in Shotnix's own domain), the
/// pop-up names each language in its own words, and a restart is offered only
/// when the language would change. Everything is written to a throwaway suite:
/// the Mac's own AppleLanguages are never touched.
@MainActor
final class AppLanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preference: AppLanguage!

    override func setUp() async throws {
        suiteName = "ShotnixCoreTests.AppLanguage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preference = AppLanguage(defaults: defaults, domain: suiteName)
    }

    override func tearDown() async throws {
        L10n.use(nil)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var stored: Any? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
    }

    // MARK: Storing the choice

    func testEachLanguageIsStoredAsSystemSettingsStoresIt() {
        for language in AppLanguage.all {
            preference.choice = language
            XCTAssertEqual(stored as? [String], [language])
            XCTAssertEqual(AppLanguage(defaults: defaults, domain: suiteName).choice, language, "the pop-up opens on it")
        }
    }

    func testSystemDefaultRemovesTheKey() {
        preference.choice = "de"
        preference.choice = nil
        XCTAssertNil(stored)
        XCTAssertNil(preference.choice)
    }

    func testNothingStoredMeansSystemDefault() {
        // Only Shotnix's own domain counts: `array(forKey:)` would also find
        // the Mac's languages in the global domain.
        XCTAssertNil(preference.choice)
    }

    func testAValueForARegionMeansItsLanguage() {
        for (value, language) in [("de-AT", "de"), ("fr-CA", "fr"), ("en-GB", "en"), ("zh-CN", "zh-Hans"), ("zh-Hans-CN", "zh-Hans")] {
            defaults.set([value], forKey: "AppleLanguages")
            XCTAssertEqual(preference.choice, language, value)
        }
    }

    func testALanguageShotnixDoesntShipMeansSystemDefault() {
        for value in ["es", "ja", "ar-DE", "zh-Hant", "zh-HK"] {
            defaults.set([value], forKey: "AppleLanguages")
            XCTAssertNil(preference.choice, value)
        }
        defaults.set([String](), forKey: "AppleLanguages")
        XCTAssertNil(preference.choice, "an empty list")
        defaults.set("de", forKey: "AppleLanguages")
        XCTAssertNil(preference.choice, "not a list")
    }

    // MARK: The pop-up

    func testTheListIsEnglishAndEveryTranslationEachInItsOwnWords() {
        XCTAssertEqual(AppLanguage.all, ["en"] + L10n.translations)
        let endonyms = ["English", "Deutsch", "Français", "简体中文"]
        XCTAssertEqual(AppLanguage.all.map(AppLanguage.endonym), endonyms)
        for language in AppLanguage.all {
            L10n.use(language)
            let options = GeneralSettingsView.languageOptions(system: "en")
            XCTAssertNil(options.first?.value, "System Default comes first")
            XCTAssertEqual(options.dropFirst().map(\.value), AppLanguage.all.map(Optional.some))
            XCTAssertEqual(options.dropFirst().map(\.title), endonyms, "\(language): never translated")
        }
    }

    func testSystemDefaultNamesTheMacsLanguageInTheLanguageShown() {
        let expected = [
            "en": ("System Default (English)", "System Default (German)"),
            "de": ("Systemstandard (Englisch)", "Systemstandard (Deutsch)"),
            "fr": ("Par défaut du système (anglais)", "Par défaut du système (allemand)"),
            "zh-Hans": ("系统默认（英语）", "系统默认（德语）"),
        ]
        for (language, titles) in expected {
            L10n.use(language)
            XCTAssertEqual(GeneralSettingsView.languageOptions(system: "en").first?.title, titles.0, language)
            XCTAssertEqual(GeneralSettingsView.languageOptions(system: "de").first?.title, titles.1, language)
        }
    }

    func testTheSystemLanguageIsTheMacsFirstLanguageShotnixHas() {
        XCTAssertEqual(AppLanguage.systemLanguage(preferring: ["en-US", "ar-DE"]), "en")
        XCTAssertEqual(AppLanguage.systemLanguage(preferring: ["ar", "de-DE", "fr"]), "de", "Arabic isn't translated; German comes next")
        XCTAssertEqual(AppLanguage.systemLanguage(preferring: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.systemLanguage(preferring: ["es", "ja"]), "en", "English when Shotnix has none of them")
    }

    // MARK: Offering a restart

    func testARestartIsOfferedOnlyWhenTheLanguageWouldChange() {
        XCTAssertEqual(AppLanguage.languageAfterRestart(with: "de", shown: "en", system: "en"), "de")
        XCTAssertEqual(AppLanguage.languageAfterRestart(with: nil, shown: "de", system: "fr"), "fr", "back to the Mac's language")
        XCTAssertNil(AppLanguage.languageAfterRestart(with: "en", shown: "en", system: "fr"), "already showing it")
        XCTAssertNil(AppLanguage.languageAfterRestart(with: nil, shown: "en", system: "en"), "the Mac's language is the one shown")
    }
}
