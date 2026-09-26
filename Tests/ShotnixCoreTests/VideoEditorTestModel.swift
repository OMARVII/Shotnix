import AppKit
import XCTest
@testable import ShotnixCore

/// Loaded editor models over synthesized recordings, plus key and mouse
/// events for driving them.
@MainActor
enum VideoEditorTestModel {
    struct Options {
        var seconds: Double = 6
        var size = CGSize(width: 640, height: 400)
        var audio = false
        var pointer = true
        var audioTracks: [VideoAudioKind]?
        var keystrokes: [VideoKeystrokeEvent]?
        var screenActivity: [Double]?
        var waypoints: [VideoTestSupport.Waypoint]?
    }

    static func make(in directory: URL, name: String = "rec.mp4", _ options: Options = Options()) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent(name)
        try await VideoTestSupport.writeFakeRecording(to: url, size: options.size, seconds: options.seconds, fps: 30, audioSeconds: options.audio ? options.seconds : nil)
        if options.pointer || options.audioTracks != nil || options.keystrokes != nil || options.screenActivity != nil {
            let waypoints = options.waypoints ?? [
                .init(x: 0.5, y: 0.5, arrive: 0, click: false),
                .init(x: 0.2, y: 0.3, arrive: 1.2, click: true),
                .init(x: 0.7, y: 0.6, arrive: 2.6, click: true),
            ]
            let (samples, clicks) = options.pointer ? VideoTestSupport.scriptedPointer(waypoints: waypoints, duration: options.seconds) : ([], [])
            var metadata = VideoDemoRecordingMetadata(
                videoURLPath: url.path, createdAt: Date(), duration: options.seconds,
                sourceWidth: Double(options.size.width), sourceHeight: Double(options.size.height),
                fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks,
                pointPixelScale: 2, renderCursor: true
            )
            metadata.keystrokes = options.keystrokes
            metadata.audioTracks = options.audioTracks
            metadata.screenActivity = options.screenActivity
            XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        }
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "not ready")
        return model
    }

    static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isRepeat, keyCode: code
        )!
    }

    static func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
