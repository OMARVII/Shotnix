import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The star ask on the video side, through the real export queue and the
/// real export sheet: the line arrives with the third finished export,
/// both of its buttons are clicked, and it is rendered in every language
/// (printed as SNAPSHOT: …, in the shotnix-ux temporary folder).
@MainActor
final class VideoStarAskTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var window: NSWindow?
    private var opened: [URL] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.VideoStarAsk.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = defaults
        StarNudge.countsExports = true
        StarNudge.exportLineIsOnShow = false
        opened = []
        StarNudge.open = { [weak self] url in self?.opened.append(url) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-star-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        unmount()
        L10n.use(nil)
        StarNudge.countsExports = false
        StarNudge.exportLineIsOnShow = false
        StarNudge.open = { NSWorkspace.shared.open($0) }
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Support

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func makeModel() async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 2, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "not ready")
        model.exportSettings = VideoInspection.mp4Settings()
        return model
    }

    /// In a window far off screen, drawn and laid out like a visible one.
    private func mount<V: View>(_ view: V, size: CGSize) async {
        unmount()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -9000, y: -9000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = TestAppearance.appearance
        window.isReleasedWhenClosed = false
        window.contentView = Host(rootView: AnyView(view.frame(width: size.width, height: size.height).environment(\.colorScheme, TestAppearance.colorScheme)))
        window.orderFrontRegardless()
        self.window = window
        await settle(0.4)
    }

    private func unmount() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    private func settle(_ seconds: Double = 0.2) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    private func snapshot(_ name: String) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("star-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
        return rep
    }

    /// A click in top-left view coordinates.
    private func click(_ point: CGPoint) async {
        guard let window, let view = window.contentView else { return }
        let location = NSPoint(x: point.x, y: view.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            await settle(0.05)
        }
        await settle(0.3)
    }

    /// One export from the sheet to the end, as a person waiting for it.
    @discardableResult
    private func export(_ model: VideoEditorModel, _ name: String) async throws -> VideoExportQueue.Job {
        model.exportPhase = .idle
        model.isExportPresented = true
        model.enqueueExport(to: directory.appendingPathComponent(name), settings: model.exportSettings, toClipboard: false)
        let job = try XCTUnwrap(model.exportJobs.last)
        try await wait(for: job)
        return job
    }

    private func wait(for job: VideoExportQueue.Job) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !job.isDone {
            if Date() > deadline { return XCTFail("export didn't finish") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The sheet follows the job a moment later.
        await settle(0.4)
    }

    /// As after the third finished export, unanswered.
    private func askIsWaiting() {
        Settings.videoExportCount = StarNudge.exportThreshold
        StarNudge.state = .toastShown
    }

    private func finishedSheet(_ model: VideoEditorModel, copied: Bool = false) -> VideoExportSheet {
        model.isExportPresented = true
        model.exportPhase = .finished(url: directory.appendingPathComponent("Onboarding walkthrough.mp4"), bytes: 18_400_000, copied: copied)
        return VideoExportSheet(model: model)
    }

    private static let sheetSize = CGSize(width: 900, height: 600)

    // MARK: Through the queue

    func testTheLineArrivesWithTheThirdFinishedExport() async throws {
        let model = try await makeModel()
        for index in 1...2 {
            let job = try await export(model, "take \(index).mp4")
            guard case .finished = job.state else { return XCTFail("export \(index): \(job.state)") }
            guard case .finished = model.exportPhase else { return XCTFail("the sheet shows export \(index) finished: \(model.exportPhase)") }
            await mount(VideoExportSheet(model: model), size: Self.sheetSize)
            XCTAssertFalse(StarNudge.exportLineIsOnShow, "nothing asks after export \(index)")
            XCTAssertEqual(StarNudge.state, .pending)
            unmount()
            VideoExportQueue.shared.dismiss(job)
        }
        XCTAssertEqual(Settings.videoExportCount, 2)

        // An export that never finished isn't one.
        model.exportPhase = .idle
        model.enqueueExport(to: directory.appendingPathComponent("cancelled.mp4"), settings: model.exportSettings, toClipboard: false)
        let cancelled = try XCTUnwrap(model.exportJobs.last)
        VideoExportQueue.shared.cancel(cancelled)
        try await wait(for: cancelled)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(Settings.videoExportCount, 2, "a cancelled export doesn't count")
        XCTAssertEqual(StarNudge.state, .pending)
        VideoExportQueue.shared.dismiss(cancelled)

        let third = try await export(model, "take 3.mp4")
        guard case .finished = third.state else { return XCTFail("\(third.state)") }
        XCTAssertEqual(Settings.videoExportCount, 3)
        XCTAssertEqual(StarNudge.state, .toastShown, "the third finished export asks")
        await mount(VideoExportSheet(model: model), size: Self.sheetSize)
        XCTAssertTrue(StarNudge.exportLineIsOnShow, "under the finished export")
        try snapshot("third-export")
        XCTAssertFalse(StarNudge.shouldToastAfterExport(lineOnShow: StarNudge.exportLineIsOnShow, appActive: true), "the line asks, so no toast on top")
        unmount()
        await settle()
        XCTAssertFalse(StarNudge.exportLineIsOnShow, "gone with the sheet")

        // Unanswered, it waits under the next one too.
        let fourth = try await export(model, "take 4.mp4")
        await mount(VideoExportSheet(model: model), size: Self.sheetSize)
        XCTAssertTrue(StarNudge.exportLineIsOnShow)
        XCTAssertEqual(StarNudge.state, .toastShown)
        VideoExportQueue.shared.dismiss(third)
        VideoExportQueue.shared.dismiss(fourth)
        model.stop()
    }

    func testAHiddenSheetGetsTheToastOnlyWithShotnixInFront() {
        askIsWaiting()
        XCTAssertTrue(StarNudge.shouldToastAfterExport(lineOnShow: false, appActive: true), "the sheet was hidden and Shotnix is in front")
        XCTAssertFalse(StarNudge.shouldToastAfterExport(lineOnShow: true, appActive: true), "the line is already asking")
        XCTAssertFalse(StarNudge.shouldToastAfterExport(lineOnShow: false, appActive: false), "nothing pops up over another app")
        StarNudge.markDismissed()
        XCTAssertFalse(StarNudge.shouldToastAfterExport(lineOnShow: false, appActive: true), "answered within the beat before the toast")
    }

    // MARK: The line itself

    func testNoLineBeforeTheAskOrBeforeThreeExports() async throws {
        let model = try await makeModel()
        await mount(finishedSheet(model), size: Self.sheetSize)
        XCTAssertFalse(StarNudge.exportLineIsOnShow, "a fresh install")
        try snapshot("none")

        // Asked over screenshots, with one video so far.
        StarNudge.state = .toastShown
        Settings.videoExportCount = 1
        await mount(finishedSheet(model), size: Self.sheetSize)
        XCTAssertFalse(StarNudge.exportLineIsOnShow)
        model.stop()
    }

    /// The two buttons sit at the right end of the line's last row.
    private func mountLine() async -> CGSize {
        let size = CGSize(width: 440, height: 96)
        await mount(VStack(spacing: 0) { Spacer(minLength: 0); VideoStarAskLine() }.background(Color(white: 0.105)), size: size)
        return size
    }

    func testNotNowRetiresItEverywhere() async throws {
        askIsWaiting()
        let size = await mountLine()
        XCTAssertTrue(StarNudge.exportLineIsOnShow)
        try snapshot("line")
        await click(CGPoint(x: size.width - 150, y: size.height - 14))
        XCTAssertEqual(StarNudge.state, .dismissed, "Not now was clicked")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(StarNudge.exportLineIsOnShow, "the line left at once")
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel, "and History's line with it")

        let model = try await makeModel()
        await mount(finishedSheet(model), size: Self.sheetSize)
        XCTAssertFalse(StarNudge.exportLineIsOnShow, "the next finished export doesn't ask")
        XCTAssertFalse(StarNudge.recordExport())
        model.stop()
    }

    func testStarOpensTheRepositoryAndRetiresIt() async throws {
        askIsWaiting()
        let size = await mountLine()
        await click(CGPoint(x: size.width - 40, y: size.height - 14))
        XCTAssertEqual(opened, [StarNudge.repositoryURL], "Star on GitHub was clicked")
        XCTAssertEqual(StarNudge.state, .starred)
        XCTAssertFalse(StarNudge.exportLineIsOnShow)
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel)
    }

    // MARK: How it reads

    func testTheLineInEachLanguage() async throws {
        let model = try await makeModel()
        askIsWaiting()
        for language in ["en"] + L10n.translations {
            L10n.use(language == "en" ? nil : language)
            await mount(finishedSheet(model), size: Self.sheetSize)
            XCTAssertTrue(StarNudge.exportLineIsOnShow, language)
            try snapshot("\(language)-finished")
        }
        L10n.use(nil)
        await mount(finishedSheet(model, copied: true), size: Self.sheetSize)
        try snapshot("en-copied")
        // The smallest editor window still has room for it.
        _ = finishedSheet(model)
        await mount(VideoEditorRootView(model: model), size: CGSize(width: 1080, height: 700))
        XCTAssertTrue(StarNudge.exportLineIsOnShow)
        try snapshot("en-smallest-window")
        model.stop()
    }
}
