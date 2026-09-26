import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShotnixCore

/// What keeps recordings from capturing Shotnix itself, stopping from the
/// wrong key, or disappearing after a crash.
@MainActor
final class RecordingSafetyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: Shotnix's own windows

    private func window(titled: Bool, level: NSWindow.Level = .normal) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: titled ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = level
        window.setFrameOrigin(RecordingUITestSupport.offscreen)
        window.orderFrontRegardless()
        return window
    }

    func testOnlyShotnixsRealWindowsAreKeptInDisplayRecordings() {
        let editor = window(titled: true)
        let editorController = ShotnixStyleController(window: editor)
        let chrome = window(titled: false)          // toast, HUD, overlay…
        let appKitOwned = window(titled: true)      // e.g. an open panel
        let appKitController = NSWindowController(window: appKitOwned)
        let plain = window(titled: true)            // a titled panel without a controller
        let hidden = window(titled: true)
        hidden.orderOut(nil)
        defer {
            [editor, chrome, appKitOwned, plain, hidden].forEach { $0.orderOut(nil) }
            _ = (editorController, appKitController)
        }

        let kept = RecordingCaptureFilter.recordableOwnWindowIDs(in: [editor, chrome, appKitOwned, plain, hidden], front: nil)
        XCTAssertEqual(kept, Set([editor, appKitOwned, plain].map { CGWindowID($0.windowNumber) }))
    }

    /// Framework UI shipped inside the app (the updater's prompts) stays out;
    /// Shotnix's own code and the system's (AppKit alerts, panels) don't.
    func testOnlyBundledFrameworksAreTreatedAsForeign() throws {
        XCTAssertFalse(RecordingCaptureFilter.isBundledFramework(Bundle(for: RecordingEngine.self)))
        XCTAssertFalse(RecordingCaptureFilter.isBundledFramework(Bundle(for: NSAlert.self)))
        XCTAssertFalse(RecordingCaptureFilter.isBundledFramework(Bundle(for: NSWindowController.self)))
        let updater: AnyClass = try XCTUnwrap(NSClassFromString("SPUStandardUpdaterController"), "the updater framework is linked")
        XCTAssertTrue(RecordingCaptureFilter.isBundledFramework(Bundle(for: updater)))
    }

    /// Recording Shotnix's own editor keeps what opens from it: a real
    /// popover (an untitled child window), a real alert sheet (owned by
    /// AppKit), and menus while the editor is in front.
    func testPopoversSheetsAndMenusOfShotnixsWindowsAreKept() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let editor = window(titled: true)
        let editorController = ShotnixStyleController(window: editor)
        editor.setFrameOrigin(NSPoint(x: screen.frame.minX + 200, y: screen.frame.minY + 200))
        let anchor = NSView(frame: NSRect(x: 130, y: 90, width: 40, height: 20))
        editor.contentView?.addSubview(anchor)
        let chrome = window(titled: false)
        let chromeAnchor = NSView(frame: NSRect(x: 130, y: 90, width: 40, height: 20))
        chrome.contentView?.addSubview(chromeAnchor)
        chrome.setFrameOrigin(NSPoint(x: screen.frame.minX + 700, y: screen.frame.minY + 200))
        RecordingUITestSupport.spinRunLoop(0.1)

        func popover(from view: NSView) -> NSPopover {
            let popover = NSPopover()
            let content = NSViewController()
            content.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
            popover.contentViewController = content
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            return popover
        }
        let editorPopover = popover(from: anchor)
        let chromePopover = popover(from: chromeAnchor)
        let alert = NSAlert()
        alert.messageText = "Delete this zoom?"
        alert.beginSheetModal(for: editor) { _ in }
        let menu = window(titled: false, level: .popUpMenu)
        RecordingUITestSupport.spinRunLoop(0.4)
        defer {
            editor.endSheet(alert.window)
            editorPopover.close()
            chromePopover.close()
            [editor, chrome, menu].forEach { $0.orderOut(nil) }
            _ = editorController
        }

        let editorPopoverWindow = try XCTUnwrap(editorPopover.contentViewController?.view.window)
        let chromePopoverWindow = try XCTUnwrap(chromePopover.contentViewController?.view.window)
        XCTAssertTrue(editorPopoverWindow.parent === editor, "a popover is a child window")
        XCTAssertTrue(alert.window.sheetParent === editor, "the alert is a sheet")

        let all = NSApp.windows
        let whileEditing = RecordingCaptureFilter.recordableOwnWindowIDs(in: all, front: editor)
        XCTAssertTrue(whileEditing.contains(CGWindowID(editor.windowNumber)))
        XCTAssertTrue(whileEditing.contains(CGWindowID(editorPopoverWindow.windowNumber)), "the editor's popover stays in")
        XCTAssertTrue(whileEditing.contains(CGWindowID(alert.window.windowNumber)), "the alert sheet stays in, AppKit-owned or not")
        XCTAssertTrue(whileEditing.contains(CGWindowID(menu.windowNumber)), "menus opened from the editor stay in")
        XCTAssertFalse(whileEditing.contains(CGWindowID(chrome.windowNumber)))
        XCTAssertFalse(whileEditing.contains(CGWindowID(chromePopoverWindow.windowNumber)), "Command Center-style popovers stay out")

        // Working in another app (or in Shotnix's chrome): menus aren't the editor's.
        let elsewhere = RecordingCaptureFilter.recordableOwnWindowIDs(in: all, front: nil)
        XCTAssertFalse(elsewhere.contains(CGWindowID(menu.windowNumber)))
        XCTAssertTrue(elsewhere.contains(CGWindowID(alert.window.windowNumber)))
        let fromChrome = RecordingCaptureFilter.recordableOwnWindowIDs(in: all, front: chrome)
        XCTAssertFalse(fromChrome.contains(CGWindowID(menu.windowNumber)))
    }

    // MARK: Window recordings

    /// Recording one window of an app leaves its other windows out — they'd
    /// cover it where they overlap — but not its menus, popovers or sheets.
    func testWindowRecordingsHideTheAppsOtherWindows() {
        typealias Summary = RecordingCaptureFilter.WindowSummary
        let chosen = Summary(id: 1, layer: 0, title: "Report.pdf", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let others = [
            Summary(id: 2, layer: 0, title: "Budget.xlsx", frame: CGRect(x: 300, y: 200, width: 700, height: 500)),   // another window, in front
            Summary(id: 3, layer: 0, title: "Notes", frame: CGRect(x: 1400, y: 100, width: 300, height: 300)),        // elsewhere
            Summary(id: 4, layer: 0, title: "", frame: CGRect(x: 300, y: 128, width: 400, height: 200)),              // its sheet
            Summary(id: 5, layer: 0, title: nil, frame: CGRect(x: 600, y: 500, width: 200, height: 150)),             // a popover over it
            Summary(id: 6, layer: 101, title: "", frame: CGRect(x: 120, y: 120, width: 180, height: 240)),            // a menu
            Summary(id: 7, layer: 0, title: "", frame: CGRect(x: 2000, y: 900, width: 100, height: 100)),             // untitled, far away
            Summary(id: 1, layer: 0, title: "Report.pdf", frame: chosen.frame),                                      // itself
        ]
        let hidden = RecordingCaptureFilter.windowsToHide(recording: chosen, others: others)
        XCTAssertEqual(hidden, [2, 3, 7])
    }

    // MARK: Stop shortcut

    /// ⌃⌘Esc is a real system hot key while recording — and only then.
    func testControlCommandEscIsRegisteredOnlyWhileRecording() {
        func systemAcceptsIt() -> Bool {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | cmdKey), EventHotKeyID(signature: 0x5445_5354, id: 9), GetEventDispatcherTarget(), 0, &reference)
            if let reference { UnregisterEventHotKey(reference) }
            return status == noErr
        }
        XCTAssertFalse(RecordingStopHotkey.isRegistered)
        XCTAssertTrue(systemAcceptsIt(), "free before recording")

        RecordingStopHotkey.register {}
        XCTAssertTrue(RecordingStopHotkey.isRegistered)
        XCTAssertFalse(systemAcceptsIt(), "taken while recording")
        RecordingStopHotkey.register {}
        XCTAssertTrue(RecordingStopHotkey.isRegistered, "registering again replaces it")

        RecordingStopHotkey.unregister()
        XCTAssertFalse(RecordingStopHotkey.isRegistered)
        XCTAssertTrue(systemAcceptsIt(), "free again afterwards")
    }

    // MARK: Crash recovery

    func testInterruptedRecordingIsRecoveredWithItsCamera() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("Shotnix Recording.mp4")
        let camera = base.appendingPathComponent("camera.mov")
        try await VideoTestSupport.writeFakeRecording(to: video, size: CGSize(width: 320, height: 180), seconds: 1.5, fps: 30)
        try await VideoTestSupport.writeFakeRecording(to: camera, size: CGSize(width: 160, height: 90), seconds: 1.5, fps: 30)
        RecordingRecovery.save(RecordingRecoveryNote(
            videoPath: video.path, cameraPath: camera.path, cameraOffset: 0.25,
            fps: 60, nativeCursorVisible: false, audioTracks: nil, startedAt: Date()
        ), baseDirectory: base)

        let recovered = await RecordingRecovery.recoverInterruptedRecording(baseDirectory: base)
        XCTAssertEqual(recovered, video)
        XCTAssertNil(RecordingRecovery.load(baseDirectory: base), "the note is used once")
        let metadata = try XCTUnwrap(VideoDemoSidecarStore.load(for: video, baseDirectory: base))
        XCTAssertEqual(metadata.duration, 1.5, accuracy: 0.1)
        XCTAssertEqual(metadata.fps, 60)
        XCTAssertEqual(metadata.webcam?.offset, 0.25)
        XCTAssertEqual(metadata.webcam?.path, camera.path)
        XCTAssertFalse(metadata.shouldRenderCursor, "no pointer data survived the crash")

        let nothing = await RecordingRecovery.recoverInterruptedRecording(baseDirectory: base)
        XCTAssertNil(nothing)
    }

    /// A take that finishes late never deletes the recovery note of the
    /// next one, already recording.
    func testClearingANoteOnlyClearsThatRecordingsNote() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let takeA = base.appendingPathComponent("A.mp4")
        let takeB = base.appendingPathComponent("B.mp4")
        RecordingRecovery.save(RecordingRecoveryNote(
            videoPath: takeB.path, cameraPath: nil, cameraOffset: nil,
            fps: 60, nativeCursorVisible: false, audioTracks: nil, startedAt: Date()
        ), baseDirectory: base)
        RecordingRecovery.clear(ifFor: takeA, baseDirectory: base)
        XCTAssertEqual(RecordingRecovery.load(baseDirectory: base)?.videoPath, takeB.path)
        RecordingRecovery.clear(ifFor: takeB, baseDirectory: base)
        XCTAssertNil(RecordingRecovery.load(baseDirectory: base))
    }

    func testUnplayableLeftoversAreDeleted() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("broken.mp4")
        let camera = base.appendingPathComponent("broken-camera.mov")
        try Data("not a movie".utf8).write(to: video)
        try Data("not a movie either".utf8).write(to: camera)
        RecordingRecovery.save(RecordingRecoveryNote(
            videoPath: video.path, cameraPath: camera.path, cameraOffset: nil,
            fps: 60, nativeCursorVisible: true, audioTracks: [.microphone], startedAt: Date()
        ), baseDirectory: base)

        let recovered = await RecordingRecovery.recoverInterruptedRecording(baseDirectory: base)
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: camera.path))
    }

    // MARK: Messages

    func testStartFailuresSayWhatWentWrong() {
        let declined = NSError(domain: SCStreamErrorDomainName, code: -3801)
        XCTAssertTrue(RecordingEngine.startFailureMessage(for: declined).contains("Screen & System Audio Recording"))
        let diskFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(RecordingEngine.startFailureMessage(for: diskFull), "Not enough disk space to record.")
        let nestedDiskFull = NSError(domain: AVFoundationErrorDomainName, code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(RecordingEngine.isDiskFull(nestedDiskFull))
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        XCTAssertTrue(RecordingEngine.startFailureMessage(for: readOnly).contains("save folder"))
        XCTAssertEqual(RecordingEngine.startFailureMessage(for: RecordingEngine.RecordingError.windowGone), "That window closed before recording could start.")
        XCTAssertFalse(RecordingEngine.startFailureMessage(for: NSError(domain: "Other", code: 1)).contains("permission"), "no more blaming permissions for everything")
        XCTAssertEqual(RecordingEngine.durationText(42), "42 s")
        XCTAssertEqual(RecordingEngine.durationText(125), "2:05")
    }

    // MARK: Window following

    func testFollowedWindowMapsIntoTheFixedSizeVideo() {
        // Same shape: fills the frame.
        XCTAssertEqual(RecordingEngine.fittedVideoRect(sourceSize: CGSize(width: 800, height: 600), outputSize: CGSize(width: 800, height: 600)), CGRect(x: 0, y: 0, width: 1, height: 1))
        // Twice as wide: letterboxed top and bottom, centered.
        let wide = RecordingEngine.fittedVideoRect(sourceSize: CGSize(width: 1600, height: 600), outputSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(wide.width, 1, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 0.5, accuracy: 1e-9)
        XCTAssertEqual(wide.minY, 0.25, accuracy: 1e-9)
        // Narrower: pillarboxed.
        let tall = RecordingEngine.fittedVideoRect(sourceSize: CGSize(width: 400, height: 600), outputSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(tall.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tall.minX, 0.25, accuracy: 1e-9)

        // The pointer at the window's center stays at the video's center,
        // and its corner lands on the letterbox edge.
        let window = CGRect(x: 1000, y: 200, width: 800, height: 300)
        let center = VideoDemoRecordingMetadataRecorder.videoPoint(for: CGPoint(x: window.midX, y: window.midY), captureRect: window, videoRect: wide)
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
        let topLeft = VideoDemoRecordingMetadataRecorder.videoPoint(for: CGPoint(x: window.minX, y: window.maxY), captureRect: window, videoRect: wide)
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0.25, accuracy: 1e-9)
    }
}

/// Stands in for Shotnix's own window controllers (editor, preferences).
private final class ShotnixStyleController: NSWindowController {}

private let SCStreamErrorDomainName = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
private let AVFoundationErrorDomainName = "AVFoundationErrorDomain"
