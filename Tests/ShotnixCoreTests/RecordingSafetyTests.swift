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

    func testOnlyShotnixsRealWindowsAreKeptInDisplayRecordings() {
        func window(titled: Bool) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: titled ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(RecordingUITestSupport.offscreen)
            window.orderFrontRegardless()
            return window
        }
        let editor = window(titled: true)
        let editorController = ShotnixStyleController(window: editor)
        let chrome = window(titled: false)          // toast, HUD, overlay…
        let framework = window(titled: true)        // e.g. Sparkle's update window
        let frameworkController = NSWindowController(window: framework)
        let plain = window(titled: true)            // a titled panel without a controller
        let hidden = window(titled: true)
        hidden.orderOut(nil)
        defer {
            [editor, chrome, framework, plain, hidden].forEach { $0.orderOut(nil) }
            _ = (editorController, frameworkController)
        }

        let kept = RecordingCaptureFilter.recordableOwnWindowIDs(in: [editor, chrome, framework, plain, hidden])
        XCTAssertEqual(kept, [CGWindowID(editor.windowNumber), CGWindowID(plain.windowNumber)])
        XCTAssertTrue(RecordingCaptureFilter.isShotnixType(editorController))
        XCTAssertFalse(RecordingCaptureFilter.isShotnixType(frameworkController))
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
