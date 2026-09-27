import Foundation
import XCTest
@testable import ShotnixCore

/// Shotnix in German, French, and Simplified Chinese: the catalog is sound
/// (placeholders match, so no translation can crash a format), strings resolve
/// through the same bundle the app uses, and converted areas keep every
/// user-visible string behind `L(…)`.
final class LocalizationTests: XCTestCase {

    /// Folders under Sources/ShotnixCore whose user-visible strings all go
    /// through `L(…)`: one marker file per folder in Localization/areas.
    static var localizedAreas: [String] {
        let folder = root.appendingPathComponent("Localization/areas")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    // MARK: The catalog

    private struct Entry {
        let key: String
        let values: [String: [String]] // language -> the string, or each plural form
    }

    private static func catalog() throws -> [Entry] {
        let url = root.appendingPathComponent("Localization/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        return strings.map { key, entry in
            var values: [String: [String]] = [:]
            for (language, unit) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                if let value = (unit["stringUnit"] as? [String: Any])?["value"] as? String {
                    values[language] = [value]
                } else if let plural = (unit["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    values[language] = plural.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
                }
            }
            return Entry(key: key, values: values)
        }
    }

    /// Format specifiers by kind, positions dropped ("%2$lld" is "lld").
    private static func specifiers(_ text: String) -> [String: Int] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(ll|l|q)?([@dDuUxXoOfFeEgGcCsSaAp])|%%"#)
        var counts: [String: Int] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let whole = (text as NSString).substring(with: match.range)
            guard whole != "%%" else { continue }
            let kind = (text as NSString).substring(with: match.range(at: 2))
            let length = match.range(at: 1).location == NSNotFound ? "" : (text as NSString).substring(with: match.range(at: 1))
            counts[kind == "@" ? "@" : length + kind, default: 0] += 1
        }
        return counts
    }

    func testEveryTranslationKeepsTheKeysPlaceholders() throws {
        for entry in try Self.catalog() {
            let expected = Self.specifiers(entry.key)
            for (language, values) in entry.values {
                let plural = values.count > 1
                for value in values {
                    let found = Self.specifiers(value)
                    if plural {
                        // A plural form may leave its number out ("Screenshot deleted").
                        XCTAssertTrue(found.allSatisfy { expected[$0.key, default: 0] >= $0.value },
                                      "\(language): \(value.debugDescription) adds placeholders to \(entry.key.debugDescription)")
                    } else {
                        XCTAssertEqual(found, expected, "\(language): \(value.debugDescription) must keep the placeholders of \(entry.key.debugDescription)")
                    }
                }
            }
        }
    }

    func testTheResourceBundleShipsEveryLanguage() throws {
        let bundle = try XCTUnwrap(ShotnixResources.bundle, "tests find the resource bundle, as the app does")
        for language in L10n.translations {
            // SwiftPM lowercases the folder names (zh-hans.lproj); macOS matches either.
            XCTAssertNotNil(bundle.path(forResource: language.lowercased(), ofType: "lproj") ?? bundle.path(forResource: language, ofType: "lproj"), "\(language).lproj")
            XCTAssertTrue(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [language]).first?.lowercased() == language.lowercased(),
                          "a Mac set to \(language) gets it")
        }
    }

    // MARK: Lookups

    func testStringsResolveInEachLanguage() {
        let expected = [
            "de": ("Bereich aufnehmen", "Bereich aufzeichnen", "Verlauf löschen?"),
            "fr": ("Capturer une zone", "Enregistrer une zone", "Effacer l’historique\u{00A0}?"),
            "zh-Hans": ("捕捉区域", "录制区域", "要清除历史记录吗？"),
            "ru": ("Снять область", "Записать область", "Очистить историю?"),
            "uk": ("Зняти область", "Записати область", "Очистити історію?"),
        ]
        for (language, strings) in expected {
            L10n.use(language)
            XCTAssertEqual(ShotnixShortcut.captureArea.title, strings.0, language)
            XCTAssertEqual(ShotnixShortcut.recordArea.title, strings.1, "\(language): a recording isn't a screenshot")
            XCTAssertEqual(L("Clear History?"), strings.2, language)
        }
        L10n.use(nil)
        XCTAssertEqual(ShotnixShortcut.captureArea.title, "Capture Area", "English is the key")
    }

    func testPluralsFollowEachLanguagesRules() {
        L10n.use("en")
        XCTAssertEqual(HistoryRetention.days7.title, "7 days")
        XCTAssertEqual(L("\(1) days"), "1 day")
        L10n.use("de")
        XCTAssertEqual(HistoryRetention.days30.title, "30 Tage")
        XCTAssertEqual(L("\(1) days"), "1 Tag")
        XCTAssertEqual(HistoryRetention.items1000.title, "Letzte 1.000 Bildschirmfotos", "numbers use the language's separators")
        L10n.use("fr")
        XCTAssertEqual(L("\(1) screenshots deleted — click or press ⌘Z to undo"), "Capture supprimée — cliquez ou appuyez sur ⌘Z pour annuler")
        XCTAssertEqual(L("\(3) screenshots deleted — click or press ⌘Z to undo"), "3 captures supprimées — cliquez ou appuyez sur ⌘Z pour annuler")
        L10n.use("zh-Hans")
        XCTAssertEqual(L("\(1) days"), "1 天", "Chinese has one form")
        L10n.use("ru")
        XCTAssertEqual(L("\(1) days"), "1 день")
        XCTAssertEqual(L("\(3) days"), "3 дня")
        XCTAssertEqual(HistoryRetention.days7.title, "7 дней")
        XCTAssertEqual(L("\(21) days"), "21 день", "Russian: 21 takes the one form")
        XCTAssertEqual(HistoryRetention.items1000.title, "Последние 1\u{00A0}000 снимков", "numbers use the language's separators")
        XCTAssertEqual(L("\(1) screenshots deleted — click or press ⌘Z to undo"), "1 снимок удален — нажмите сюда или ⌘Z, чтобы отменить")
    }

    func testTranslationsCanReorderPlaceholders() {
        L10n.use("zh-Hans")
        XCTAssertEqual(HistoryPanelController.headerText(shown: 3, total: 10, query: "invoice", filtered: false), "在 3 张截屏中找到“invoice”（共 10 张）", "the query moves after the count")
        XCTAssertEqual(HistoryPanelController.headerText(shown: 3, total: 10, query: "", filtered: true), "3 张截屏（共 10 张）")
        L10n.use("de")
        XCTAssertEqual(HistoryPanelController.headerText(shown: 3, total: 10, query: "invoice", filtered: false), "„invoice“ in 3 von 10 Bildschirmfotos gefunden")
        XCTAssertEqual(HistoryPanelController.headerText(shown: 1, total: 1, query: "", filtered: false), "1 gesichertes Bildschirmfoto · Karten in den Finder ziehen · Rechtsklick für mehr")
    }

    // MARK: Nothing left in English

    /// A line with a literal where AppKit or SwiftUI shows text, not wrapped in
    /// `L(…)`. Mark a deliberate exception with `// l10n-ignore`.
    private static let rawUIString = try! NSRegularExpression(pattern: #"(?:labelWithString|title|messageText|informativeText|toolTip|placeholderString|stringValue|setAccessibilityLabel|setAccessibilityHelp|setAccessibilityValue|addButton\(withTitle|addItem\(withTitle|message|Text|Button|Toggle|Label|Section|help|actionName)\s*[:=(]\s*"(?:[^"\\]|\\.)*[A-Za-z]{2,}"#)

    func testLocalizedAreasHaveNoRawUIStrings() throws {
        XCTAssertFalse(Self.localizedAreas.isEmpty)
        var offenders: [String] = []
        for area in Self.localizedAreas {
            let folder = Self.root.appendingPathComponent("Sources/ShotnixCore/\(area)")
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            for file in files {
                let lines = try String(contentsOf: file).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !line.contains("l10n-ignore") else { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if Self.rawUIString.firstMatch(in: line, range: range) != nil {
                        offenders.append("\(area)/\(file.lastPathComponent):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "User-visible strings must go through L(…):\n" + offenders.joined(separator: "\n"))
    }
}
