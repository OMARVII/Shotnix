import Foundation
import XCTest
@testable import ShotnixCore

/// The video editor in German, French, and Simplified Chinese: Undo and Redo
/// name every edit in a whole phrase of their own, the tab names read the
/// same in the tabs, the tips, and the commands, counts take each language's
/// plural forms, and the editor's files keep every user-visible string
/// behind `L(…)`.
final class VideoEditorLocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let video = root.appendingPathComponent("Sources/ShotnixCore/Video")

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    // MARK: Undo and Redo

    /// Every edit name the Video sources can give an undo step: labels passed
    /// to `mutate` and `applyToRange`, the group move's pending label, and
    /// the names VideoEditDescription works out from a change.
    private static func undoNames() throws -> Set<String> {
        let literal = #""((?:[^"\\]|\\.)*)""#
        let patterns = [
            #"(?:mutate|applyToRange)\([^\n]*?label:\s*"# + literal,
            #"(?:mutate|applyToRange)\([^\n]*?label:\s*[^?\n"]*\?\s*"# + literal + #"\s*:\s*"# + literal,
            #"pendingUndoLabel\s*=\s*"# + literal,
        ].map { try! NSRegularExpression(pattern: $0) }
        var names = Set<String>()
        func collect(_ text: String, _ expressions: [NSRegularExpression]) {
            for expression in expressions {
                for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                        names.insert((text as NSString).substring(with: match.range(at: group)))
                    }
                }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: video, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file)
            collect(text, patterns)
            // The names worked out from a change: every literal they return.
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let everyLiteral = try NSRegularExpression(pattern: literal)
            if file.lastPathComponent == "VideoEditHistory.swift", let end = code.range(of: "// MARK: - Undo and Redo") ?? code.range(of: "extension VideoEditDescription") {
                collect(String(code[..<end.lowerBound]).components(separatedBy: "enum VideoEditDescription").last ?? "", [everyLiteral])
            }
            if let start = code.range(of: "static func framing(from"), let end = code.range(of: "\n    }\n", range: start.upperBound..<code.endIndex) {
                collect(String(code[start.upperBound..<end.lowerBound]), [everyLiteral])
            }
        }
        // "Move \(count) Items" names a count.
        return Set(names.map { $0.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "2", options: .regularExpression) })
    }

    func testEveryUndoNameHasWholeCommands() throws {
        let names = try Self.undoNames()
        XCTAssertGreaterThan(names.count, 90, "found the edit names: \(names.sorted())")
        L10n.use("en")
        for name in names.sorted() {
            XCTAssertNotNil(VideoEditDescription.commands(for: name), "\(name.debugDescription) needs its own Undo and Redo phrases in VideoEditDescription.commands(for:)")
            // English reads as it always did.
            XCTAssertEqual(VideoEditDescription.undoTitle(name), "Undo \(name)")
            XCTAssertEqual(VideoEditDescription.redoTitle(name), "Redo \(name)")
        }
    }

    func testUndoCommandsAreWholePhrasesInEachLanguage() {
        let expected = [
            "de": ("Löschen des Zooms widerrufen", "Löschen des Zooms wiederholen", "Widerrufen"),
            "fr": ("Annuler la suppression du zoom", "Rétablir la suppression du zoom", "Annuler"),
            "zh-Hans": ("撤销删除缩放", "重做删除缩放", "撤销"),
            "ru": ("Отменить удаление увеличения", "Повторить удаление увеличения", "Отменить"),
        ]
        for (language, phrases) in expected {
            L10n.use(language)
            XCTAssertEqual(VideoEditDescription.undoTitle("Delete Zoom"), phrases.0, language)
            XCTAssertEqual(VideoEditDescription.redoTitle("Delete Zoom"), phrases.1, language)
            XCTAssertEqual(VideoEditDescription.undoTitle(nil), phrases.2, "\(language): nothing named")
            XCTAssertEqual(VideoEditDescription.undoTitle("A New Edit"), phrases.2, "\(language): a name without phrases")
        }
        L10n.use("de")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 1 Items"), "Verschieben von 1 Objekt widerrufen")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 3 Items"), "Verschieben von 3 Objekten widerrufen")
        XCTAssertEqual(VideoEditDescription.redoTitle("Delete 3 Items"), "Löschen von 3 Objekten wiederholen")
        L10n.use("ru")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 1 Items"), "Отменить перемещение 1 объекта")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 3 Items"), "Отменить перемещение 3 объектов")
        XCTAssertEqual(VideoEditDescription.redoTitle("Delete 5 Items"), "Повторить удаление 5 объектов")
        L10n.use("en")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 1 Items"), "Undo Move 1 Item", "one item reads right in English too")
        XCTAssertEqual(VideoEditDescription.undoTitle("Move 3 Items"), "Undo Move 3 Items")
    }

    @MainActor
    func testTheUndoMessageIsTheWholePhrase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        VideoTestStorage.isolate()
        let model = try await VideoEditorTestModel.make(in: directory, VideoEditorTestModel.Options(seconds: 6, pointer: false))
        let zoom = try XCTUnwrap(model.addZoom(at: 1, length: 1))
        model.deleteZoom(zoom)
        XCTAssertEqual(model.undoLabel, "Delete Zoom", "the name itself stays English")
        L10n.use("fr")
        model.undo()
        XCTAssertEqual(model.notice?.message, "Annuler la suppression du zoom")
        model.redo()
        XCTAssertEqual(model.notice?.message, "Rétablir la suppression du zoom")
        VideoDemoDraftStore.delete(for: model.project.sourceURL)
    }

    // MARK: Words that must match

    /// The tips, hints, and commands name the tabs by the tabs' own names.
    func testTabNamesReadTheSameEverywhere() {
        for language in L10n.translations {
            L10n.use(language)
            let captions = VideoEditorModel.InspectorTab.captions.title
            let style = VideoEditorModel.InspectorTab.background.title
            let zoom = VideoEditorModel.InspectorTab.zoom.title
            let camera = VideoEditorModel.InspectorTab.camera.title
            let uses: [(String, String)] = [
                (captions, L("Captions tab")),
                (captions, L("Transcribe Narration (Captions, Edit by Text)")),
                (style, L("Intro card — click to edit it in Style")),
                (style, L("Opens its title and length in Style")),
                (zoom, L("Hover the Zoom track")),
                (camera, L("Drag the block on the Camera lane to move it, or its edges to change how long it lasts. Each change eases in and out.")),
            ]
            for (name, text) in uses {
                XCTAssertTrue(text.localizedCaseInsensitiveContains(name), "\(language): “\(text)” should name the tab “\(name)”")
            }
            // "Style" is French too.
            if language != "fr" {
                XCTAssertNotEqual(style, "Style", "\(language): the tab names are translated")
            }
        }
    }

    // MARK: Counts and numbers

    func testCountsTakeEachLanguagesPluralForms() {
        L10n.use("en")
        XCTAssertEqual(L("Plans zooms around your \(1) clicks. Zooms you placed by hand are kept."), "Plans zooms around your 1 click. Zooms you placed by hand are kept.")
        XCTAssertEqual(L("Removed \(1) items — ⌘Z to undo"), "Removed 1 item — ⌘Z to undo")
        XCTAssertEqual(L("\(2) zooms"), "2 zooms")
        L10n.use("de")
        XCTAssertEqual(L("\(1) zooms"), "1 Zoom")
        XCTAssertEqual(L("\(3) zooms"), "3 Zooms")
        XCTAssertEqual(L("Shorten \(1) pauses"), "1 Pause kürzen")
        XCTAssertEqual(L("Shorten \(4) pauses"), "4 Pausen kürzen")
        L10n.use("fr")
        XCTAssertEqual(L("\(1) selected"), "1 sélectionné")
        XCTAssertEqual(L("\(2) selected"), "2 sélectionnés")
        XCTAssertEqual(L("Remove \(1) ums"), "Supprimer 1 hésitation")
        L10n.use("zh-Hans")
        XCTAssertEqual(L("\(3) zooms"), "3 个缩放", "Chinese has one form")
        L10n.use("ru")
        XCTAssertEqual(L("\(1) zooms"), "1 увеличение")
        XCTAssertEqual(L("\(3) zooms"), "3 увеличения")
        XCTAssertEqual(L("\(5) zooms"), "5 увеличений")
        XCTAssertEqual(L("Shorten \(22) pauses"), "Сократить 22 паузы")
    }

    func testPercentagesFollowTheLanguage() {
        L10n.use("en")
        XCTAssertEqual(VideoEditorFormat.percent(0.42), "42%")
        L10n.use("de")
        XCTAssertEqual(VideoEditorFormat.percent(0.42), "42\u{00A0}%")
        L10n.use("fr")
        XCTAssertEqual(VideoEditorFormat.percent(0.42), "42\u{202F}%")
        L10n.use("zh-Hans")
        XCTAssertEqual(VideoEditorFormat.percent(0.42), "42%")
        L10n.use("ru")
        XCTAssertEqual(VideoEditorFormat.percent(0.42), "42\u{00A0}%")
    }

    /// VoiceOver descriptions: each part a whole phrase, joined the way the
    /// language lists them.
    @MainActor
    func testSpokenDescriptionsInEachLanguage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        VideoTestStorage.isolate()
        let model = try await VideoEditorTestModel.make(in: directory, VideoEditorTestModel.Options(seconds: 8, pointer: false))
        model.mutate { $0.captions = [VideoCaptionLine(start: 3, end: 4.5, text: "Hello there")] }
        let caption = try XCTUnwrap(model.project.captions.first?.id)
        L10n.use("de")
        XCTAssertTrue(model.accessibilityDescription(of: .caption(caption)).hasPrefix("Untertitel „Hello there“, "), model.accessibilityDescription(of: .caption(caption)))
        XCTAssertTrue(model.accessibilityDescription(of: .caption(caption)).contains(" bis "))
        L10n.use("zh-Hans")
        XCTAssertTrue(model.accessibilityDescription(of: .caption(caption)).hasPrefix("字幕“Hello there”，"), model.accessibilityDescription(of: .caption(caption)))
        XCTAssertTrue(VideoEditorModel.spokenList(["片段 2", "已静音"]) == "片段 2，已静音", "a Chinese list takes a full-width comma")
        VideoDemoDraftStore.delete(for: model.project.sourceURL)
    }

    // MARK: Nothing left in English

    /// The same check LocalizationTests runs on converted areas, on the
    /// editor's own files now (the Video folder gets its marker once the
    /// video features are converted too).
    private static let rawUIString = try! NSRegularExpression(pattern: #"(?:labelWithString|title|messageText|informativeText|toolTip|placeholderString|stringValue|setAccessibilityLabel|setAccessibilityHelp|setAccessibilityValue|addButton\(withTitle|addItem\(withTitle|message|Text|Button|Toggle|Label|Section|help|actionName)\s*[:=(]\s*"(?:[^"\\]|\\.)*[A-Za-z]{2,}"#)

    static let editorFiles = [
        "VideoInspectorView", "VideoEditorView", "VideoFeatureInspectors", "VideoTimelineView", "VideoTimelineLanes",
        "VideoTimelineExtras", "VideoTimelineScroller", "VideoTranscriptView", "VideoPreviewView", "VideoCropView",
        "VideoEditorWindowController", "VideoEditorSelection", "VideoEditorTheme", "VideoEditorFileMenu",
        "VideoEditHistory", "VideoAnnotationGeometry",
    ]

    func testTheEditorsFilesHaveNoRawUIStrings() throws {
        var offenders: [String] = []
        for name in Self.editorFiles {
            let lines = try String(contentsOf: Self.video.appendingPathComponent("\(name).swift")).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !line.contains("l10n-ignore") else { continue }
                if Self.rawUIString.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offenders.append("\(name).swift:\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "User-visible strings must go through L(…):\n" + offenders.joined(separator: "\n"))
    }
}
