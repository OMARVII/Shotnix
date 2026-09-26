import AppKit
import XCTest
@testable import ShotnixCore

/// Quitting, closing, and autosave: running work is announced to the quit
/// prompt, and no edit is lost.
@MainActor
final class VideoEditorLifecycleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-life-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    func testExportIsAnnouncedToTheQuitPromptUntilItEnds() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 2, size: CGSize(width: 320, height: 200)))
        XCTAssertFalse(AppTermination.isBusy)
        model.beginExport(toClipboard: true)
        XCTAssertTrue(AppTermination.isBusy)
        XCTAssertTrue(AppTermination.asksBeforeQuit, "losing an export asks first")
        XCTAssertTrue(AppTermination.descriptions.contains { $0.hasPrefix("Exporting") }, "\(AppTermination.descriptions)")
        XCTAssertEqual(AppTermination.descriptions.filter { $0.hasPrefix("Exporting") }.count, 1, "one registration per export")
        // A quit waits for the file instead of cutting it off. (Exports run
        // in the background queue, so the editor stays free meanwhile.)
        var quitGoesAhead = false
        AppTermination.finishAll { quitGoesAhead = true }
        let job = try XCTUnwrap(model.exportJobs.last)
        for _ in 0..<200 where !job.isDone {
            await T.settle(0.05)
        }
        if case .finished = job.state {} else { XCTFail("finished: \(job.state)") }
        XCTAssertTrue(quitGoesAhead)
        XCTAssertFalse(AppTermination.isBusy)
        VideoExportQueue.shared.dismiss(job)
        NSPasteboard.general.clearContents()
    }

    func testCancellingAnExportLetsTheQuitGoAhead() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 3, size: CGSize(width: 320, height: 200)))
        model.beginExport(toClipboard: true)
        var quitGoesAhead = false
        AppTermination.finishAll { quitGoesAhead = true }
        let job = try XCTUnwrap(model.exportJobs.last)
        model.cancelExport()
        for _ in 0..<200 where !job.isDone || model.notice?.message != "Export cancelled" {
            await T.settle(0.05)
        }
        XCTAssertTrue(quitGoesAhead)
        XCTAssertFalse(AppTermination.isBusy)
        XCTAssertEqual(model.notice?.message, "Export cancelled")
        VideoExportQueue.shared.dismiss(job)
    }

    func testTranscriptionIsAnnouncedAndCancelEndsIt() async throws {
        var options = T.Options(seconds: 2)
        options.audio = true
        let model = try await T.make(in: directory, options)
        model.generateCaptions()
        XCTAssertTrue(AppTermination.descriptions.contains { $0.hasPrefix("Transcribing") }, "\(AppTermination.descriptions)")
        XCTAssertTrue(AppTermination.asksBeforeQuit)
        model.cancelCaptions()
        XCTAssertFalse(AppTermination.isBusy)
    }

    func testVoiceCleanupStopsForAQuit() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation isn't available on this Mac")
        var options = T.Options(seconds: 3)
        options.audio = true
        options.audioTracks = [.microphone]
        let model = try await T.make(in: directory, options)
        if let url = model.voiceTrackIndex.map({ VideoVoiceEnhancer.cacheURL(for: model.project.sourceURL, trackIndex: $0) }) {
            try? FileManager.default.removeItem(at: url)
        }
        model.setStyle { $0.audio.enhanceVoice = true }
        XCTAssertNotNil(model.voiceTask)
        XCTAssertTrue(AppTermination.descriptions.contains { $0.hasPrefix("Cleaning up the voice") }, "\(AppTermination.descriptions)")
        var quitGoesAhead = false
        AppTermination.finishAll { quitGoesAhead = true }
        for _ in 0..<200 where !quitGoesAhead {
            await T.settle(0.05)
        }
        XCTAssertTrue(quitGoesAhead, "a quit doesn't wait for a cache")
        XCTAssertFalse(AppTermination.isBusy)
    }

    func testClosingDuringVoiceCleanupEndsItsQuitRegistration() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation isn't available on this Mac")
        var options = T.Options(seconds: 3)
        options.audio = true
        options.audioTracks = [.microphone]
        var model: VideoEditorModel? = try await T.make(in: directory, options)
        if let url = model?.voiceTrackIndex.map({ VideoVoiceEnhancer.cacheURL(for: model!.project.sourceURL, trackIndex: $0) }) {
            try? FileManager.default.removeItem(at: url)
        }
        model?.setStyle { $0.audio.enhanceVoice = true }
        XCTAssertTrue(AppTermination.descriptions.contains { $0.hasPrefix("Cleaning up the voice") })
        // The window closes: the editor stops and goes away — its work is
        // off the quit prompt right then, whenever the cleanup notices.
        model?.stop()
        XCTAssertFalse(AppTermination.descriptions.contains { $0.hasPrefix("Cleaning up the voice") }, "\(AppTermination.descriptions)")
        model = nil
        for _ in 0..<100 where AppTermination.isBusy {
            await T.settle(0.05)
        }
        XCTAssertFalse(AppTermination.isBusy, "no stale work for the next quit or update to wait on: \(AppTermination.descriptions)")
    }

    func testQuittingWritesTheLastEdits() async throws {
        let model = try await T.make(in: directory)
        model.setStyle { $0.padding = 0.2 }
        // Autosave waits a moment; a quit doesn't.
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        let draft = try XCTUnwrap(VideoDemoDraftStore.load(for: model.project.sourceURL))
        XCTAssertEqual(draft.project.padding, 0.2, accuracy: 0.0001)
    }
}
