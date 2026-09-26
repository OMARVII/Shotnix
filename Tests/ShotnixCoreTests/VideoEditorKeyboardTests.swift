import AppKit
import XCTest
@testable import ShotnixCore

/// The editor's keyboard: what each key does (and never does) to the video.
@MainActor
final class VideoEditorKeyboardTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    func testMMutesOnlyThePreview() async throws {
        var options = T.Options()
        options.audio = true
        let model = try await T.make(in: directory, options)
        XCTAssertTrue(model.hasAudio)
        model.selection = .none

        XCTAssertTrue(model.handleKey(T.key("m", code: 46)))
        XCTAssertTrue(model.previewMuted)
        XCTAssertTrue(model.playback.player.isMuted, "the player goes quiet")
        XCTAssertFalse(model.project.audio.muted, "the video's own sound is untouched")
        XCTAssertNil(model.exportSoundWarning, "so the export keeps its sound")
        XCTAssertEqual(model.notice?.message, "Preview muted — the export keeps its sound")
        XCTAssertFalse(model.canUndo, "not an edit")

        // Never saved with the draft.
        model.saveDraftNow()
        let draft = try XCTUnwrap(VideoDemoDraftStore.load(for: model.project.sourceURL))
        XCTAssertFalse(draft.project.audio.muted)

        XCTAssertTrue(model.handleKey(T.key("m", code: 46)))
        XCTAssertFalse(model.previewMuted)
        XCTAssertFalse(model.playback.player.isMuted)

        // With a clip selected, M mutes that clip (an edit, undoable).
        model.seek(to: 2)
        model.splitAtPlayhead()
        guard case .clip(let id) = model.selection else { return XCTFail("split selects the new clip") }
        XCTAssertTrue(model.handleKey(T.key("m", code: 46)))
        XCTAssertTrue(model.project.timelineClips.first { $0.id == id }?.muted ?? false)
        XCTAssertFalse(model.previewMuted)
    }

    func testExportSummaryWarnsWhenTheVideoIsMuted() async throws {
        var options = T.Options()
        options.audio = true
        let model = try await T.make(in: directory, options)
        XCTAssertNil(model.exportSoundWarning)
        model.setStyle { $0.audio.muted = true }
        XCTAssertNotNil(model.exportSoundWarning)
        model.setStyle { $0.audio.muted = false; $0.audio.volume = 0 }
        XCTAssertNotNil(model.exportSoundWarning, "levels at zero are silent too")
        model.setStyle { $0.audio.volume = 1 }
        if let id = model.segments.first?.id { model.setClipMuted(id, true) }
        XCTAssertNotNil(model.exportSoundWarning, "every clip muted")
    }

    func testExportSheetLetsTabSpaceAndArrowsThrough() async throws {
        let model = try await T.make(in: directory)
        model.isExportPresented = true
        let segments = model.segments.count
        XCTAssertFalse(model.handleKey(T.key("\t", code: 48)), "Tab moves focus in the sheet")
        XCTAssertFalse(model.handleKey(T.key("\t", code: 48, modifiers: [.shift])))
        XCTAssertFalse(model.handleKey(T.key(" ", code: 49)), "Space presses the focused control")
        for code: UInt16 in [123, 124, 125, 126] {
            XCTAssertFalse(model.handleKey(T.key("", code: code)), "arrow \(code) reaches the sheet")
        }
        XCTAssertFalse(model.handleKey(T.key("\r", code: 36)), "Return presses the default button")
        // Editing keys still stop at the sheet.
        model.seek(to: 2)
        XCTAssertTrue(model.handleKey(T.key("s", code: 1)))
        XCTAssertEqual(model.segments.count, segments, "S doesn't split behind the sheet")
        XCTAssertTrue(model.handleKey(T.key("\u{1b}", code: 53)))
        XCTAssertFalse(model.isExportPresented, "Esc closes it")
    }
}
