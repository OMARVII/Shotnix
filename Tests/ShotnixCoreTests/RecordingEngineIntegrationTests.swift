import AppKit
import AVFoundation
import CoreImage
import IOKit.pwr_mgt
import ScreenCaptureKit
import XCTest
@testable import ShotnixCore

/// Real recordings through the engine and ScreenCaptureKit: needs Screen
/// Recording permission for the test runner, skipped otherwise.
@MainActor
final class RecordingEngineIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var engine: RecordingEngine?
    private var displayAssertion: IOPMAssertionID = 0

    override func setUp() async throws {
        try await super.setUp()
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("needs Screen Recording permission") }
        // Displays that doze off mid-test stall ScreenCaptureKit.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Shotnix recording tests" as CFString, &displayAssertion)
        guard await Self.wakeDisplays() else { throw XCTSkip("no display to record (asleep or headless)") }
        _ = NSApplication.shared
        VideoTestStorage.isolate()
        suiteName = "ShotnixCoreTests.RecordingEngine.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(Settings.setAutoSaveLocation(folder.path))
        // Nothing that would ask for another permission or open windows.
        Settings.recordingMicrophone = false
        Settings.recordingSystemAudio = false
        Settings.recordingCamera = false
        Settings.recordingKeystrokes = false
        Settings.openVideoEditorAfterRecording = false
        Settings.recordingFPS = 30
    }

    override func tearDown() async throws {
        if let engine, engine.active {
            engine.discardRecording()
            try? await waitUntil(timeout: 10) { !engine.active }
        }
        engine = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        Settings.defaults = .standard
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
        try await super.tearDown()
    }

    /// Asleep displays aren't listed by ScreenCaptureKit; declaring user
    /// activity lights them (a locked Mac stays locked).
    private static func wakeDisplays() async -> Bool {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Shotnix recording tests" as CFString, kIOPMUserActiveLocal, &assertion)
        for _ in 0..<40 {
            let content = await within(10) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            if content?.displays.isEmpty == false { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// The operation's result, or nil if it fails or doesn't answer in time
    /// (ScreenCaptureKit can stall while another process hammers it).
    private static func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let lock = NSLock()
            nonisolated(unsafe) var resumed = false
            let finish: @Sendable (T?) -> Void = { value in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            Task { finish(try? await operation()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish(nil)
            }
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func areaOnMainScreen() throws -> (CGRect, NSScreen) {
        let screen = try XCTUnwrap(NSScreen.main)
        return (CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 640, height: 360), screen)
    }

    private func startedEngine() async throws -> (RecordingEngine, () -> URL?) {
        let engine = RecordingEngine()
        self.engine = engine
        var finished: URL?
        engine.recordingFinishedHandler = { url, _ in finished = url }
        let (rect, screen) = try areaOnMainScreen()
        try await start(engine) { await engine.startRecording(rect: rect, on: screen) }
        return (engine, { finished })
    }

    /// A display that just woke can be slow to hand out its first frames;
    /// one retry covers that. A stream that won't start at all is the
    /// machine's state (asleep, or ScreenCaptureKit busy elsewhere), not a
    /// finding.
    private func start(_ engine: RecordingEngine, _ begin: () async -> Void) async throws {
        await begin()
        if engine.elapsedSeconds == nil {
            try await sleep(1)
            await begin()
        }
        guard engine.elapsedSeconds != nil else { throw XCTSkip("ScreenCaptureKit didn't start a stream") }
        // A started stream that never sends a picture (displays powered
        // down under a lock screen, a capture service busy elsewhere) is the
        // machine's state too.
        let deadline = Date().addingTimeInterval(6)
        while !engine.hasCapturedFrames, Date() < deadline {
            try await sleep(0.05)
        }
        guard engine.hasCapturedFrames else {
            engine.discardRecording()
            try await waitUntil(timeout: 10) { !engine.active }
            throw XCTSkip("the screen isn't delivering frames")
        }
    }

    func testRecordsAPlayableAreaAndCleansUpAfterwards() async throws {
        let (engine, finished) = try await startedEngine()
        // While recording: a stop shortcut, a display that stays awake, and
        // quitting that waits for the file.
        XCTAssertTrue(RecordingStopHotkey.isRegistered)
        XCTAssertTrue(engine.isPreventingDisplaySleep)
        XCTAssertTrue(AppTermination.isBusy)
        XCTAssertNotNil(RecordingRecovery.load(), "a crash would leave a note to recover from")

        try await sleep(2)
        engine.stopRecording()
        XCTAssertTrue(engine.isSaving)
        try await waitUntil(timeout: 20) { finished() != nil }
        let url = try XCTUnwrap(finished())

        XCTAssertFalse(engine.active)
        XCTAssertFalse(RecordingStopHotkey.isRegistered)
        XCTAssertFalse(engine.isPreventingDisplaySleep)
        XCTAssertFalse(AppTermination.isBusy)
        XCTAssertNil(RecordingRecovery.load())

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.35)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let scale = try XCTUnwrap(NSScreen.main).backingScaleFactor
        XCTAssertEqual(size, CGSize(width: 640 * scale, height: 360 * scale))

        let metadata = try XCTUnwrap(VideoDemoSidecarStore.load(for: url))
        XCTAssertEqual(metadata.duration, duration, accuracy: 0.2)
        XCTAssertEqual(metadata.fps, 30)
        XCTAssertNotNil(metadata.screenActivity, "activity is recorded for idle detection")
        XCTAssertTrue(metadata.screenActivity?.allSatisfy { $0 >= 0 && $0 <= duration + 0.05 } ?? false)
        // Pointer samples run on the video's clock: t=0 at the first frame
        // (a still pointer is sampled every 0.25 s), so they span the video.
        XCTAssertEqual(metadata.cursorSamples.first?.time ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(metadata.cursorSamples.last?.time ?? 0, duration - 0.35)
        XCTAssertLessThanOrEqual(metadata.cursorSamples.last?.time ?? .infinity, duration + 0.05)
    }

    func testPausedTimeIsCutFromTheRecording() async throws {
        let (engine, finished) = try await startedEngine()
        try await sleep(1)
        engine.togglePause()
        XCTAssertTrue(engine.isPaused)
        let atPause = try XCTUnwrap(engine.elapsedSeconds)
        try await sleep(1.5)
        XCTAssertEqual(try XCTUnwrap(engine.elapsedSeconds), atPause, accuracy: 0.05, "the clock stops while paused")
        engine.togglePause()
        XCTAssertFalse(engine.isPaused)
        try await sleep(1)
        engine.stopRecording()
        try await waitUntil(timeout: 20) { finished() != nil }
        let url = try XCTUnwrap(finished())
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.35, "3.5 s of wall time, 1.5 s of it paused")
        let metadata = try XCTUnwrap(VideoDemoSidecarStore.load(for: url))
        XCTAssertEqual(metadata.duration, 2, accuracy: 0.35)
        XCTAssertTrue(metadata.cursorSamples.allSatisfy { $0.time <= metadata.duration + 0.05 }, "pointer data skips the pause too")
    }

    func testDiscardLeavesNothingBehind() async throws {
        let (engine, finished) = try await startedEngine()
        try await sleep(1)
        engine.discardRecording()
        try await waitUntil(timeout: 10) { !engine.active }
        XCTAssertNil(finished())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, [], "the file is deleted")
        XCTAssertNil(RecordingRecovery.load())
        XCTAssertFalse(AppTermination.isBusy)
    }

    /// Quit (or logout, or an update) mid-recording: stop, save, then let go.
    func testQuittingStopsAndSavesFirst() async throws {
        let (engine, finished) = try await startedEngine()
        try await sleep(1.2)
        var quitMayProceed = false
        AppTermination.finishAll { quitMayProceed = true }
        XCTAssertFalse(quitMayProceed, "waits for the file")
        try await waitUntil(timeout: 20) { quitMayProceed }
        XCTAssertFalse(engine.active)
        XCTAssertNil(finished(), "no editor or panel on the way out")
        let saved = URL(fileURLWithPath: Settings.lastRecordingPath)
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        let playable = try await AVURLAsset(url: saved).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    /// A second recording set up while the first saves starts once it's ready.
    func testStartingWhileSavingWaitsForTheFile() async throws {
        let (engine, finished) = try await startedEngine()
        try await sleep(1)
        engine.stopRecording()
        let (rect, screen) = try areaOnMainScreen()
        await engine.startRecording(rect: rect, on: screen)
        XCTAssertNotNil(finished(), "the first file finished before the second began")
        XCTAssertNotNil(engine.elapsedSeconds, "and the second one is recording")
        engine.discardRecording()
        try await waitUntil(timeout: 10) { !engine.active }
    }

    /// Window recordings follow the window: moved, the crop moves with it;
    /// resized, it's scaled into the video.
    func testWindowRecordingFollowsItsWindow() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 160, y: screen.frame.minY + 160, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0, green: 0.8, blue: 0.2, alpha: 1).cgColor
        window.contentView = content
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await sleep(0.4)

        let shareable = await Self.within(10) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        let scWindow = try XCTUnwrap(shareable?.windows.first { $0.windowID == CGWindowID(window.windowNumber) })

        let engine = RecordingEngine()
        self.engine = engine
        var finished: URL?
        engine.recordingFinishedHandler = { url, _ in finished = url }
        try await start(engine) { await engine.startRecording(window: scWindow, on: screen) }
        try await sleep(1)
        window.setFrameOrigin(NSPoint(x: screen.frame.minX + 520, y: screen.frame.minY + 260))
        try await sleep(1)
        window.setContentSize(NSSize(width: 800, height: 300))
        try await sleep(1)
        engine.stopRecording()
        try await waitUntil(timeout: 20) { finished != nil }
        let url = try XCTUnwrap(finished)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func greenFraction(at seconds: Double, rows: ClosedRange<Double>) async throws -> Double {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let ci = CIImage(cgImage: image)
            let band = CGRect(x: 0, y: ci.extent.height * (1 - rows.upperBound), width: ci.extent.width, height: ci.extent.height * (rows.upperBound - rows.lowerBound))
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: band)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return Double(pixel[1]) / 204
        }
        let before = try await greenFraction(at: 0.5, rows: 0.1...0.9)
        let afterMove = try await greenFraction(at: 1.7, rows: 0.1...0.9)
        XCTAssertGreaterThan(before, 0.9, "the window fills the video")
        XCTAssertGreaterThan(afterMove, 0.9, "after moving, the crop followed it")

        // Twice as wide: scaled to fit, bars above and below.
        let resizedMiddle = try await greenFraction(at: 2.8, rows: 0.4...0.6)
        let resizedTop = try await greenFraction(at: 2.8, rows: 0.0...0.15)
        XCTAssertGreaterThan(resizedMiddle, 0.9, "the resized window is still in the video")
        XCTAssertLessThan(resizedTop, 0.2, "letterboxed, not stretched or cropped")
    }
}
