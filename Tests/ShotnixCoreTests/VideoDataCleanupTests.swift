import Foundation
import XCTest
@testable import ShotnixCore

/// The leftover-data sweep removes only what belongs to recordings that
/// are gone for good.
final class VideoDataCleanupTests: XCTestCase {
    private var root: URL!
    private var previousRoot: URL?
    private var recordings: URL!
    private var trash: URL!
    private var clipboard: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-cleanup-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Support", isDirectory: true)
        recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        trash = base.appendingPathComponent("Trash", isDirectory: true)
        clipboard = base.appendingPathComponent("Clipboard", isDirectory: true)
        for folder in [root, recordings, trash, clipboard] {
            try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
        }
        previousRoot = VideoStorageLocation.overrideRoot
        VideoStorageLocation.overrideRoot = root
        VideoDataCleanup.trashOverride = trash
        VideoDataCleanup.clipboardExportsOverride = clipboard
    }

    override func tearDownWithError() throws {
        VideoStorageLocation.overrideRoot = previousRoot
        VideoDataCleanup.trashOverride = nil
        VideoDataCleanup.clipboardExportsOverride = nil
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private var support: URL { root.appendingPathComponent("Shotnix", isDirectory: true) }

    private func folder(_ name: String) throws -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func age(_ url: URL, days: Double = 3) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
    }

    private func write(_ text: String, to url: URL, old: Bool = true) throws {
        try Data(text.utf8).write(to: url)
        if old { try age(url) }
    }

    /// A recording with a draft and a sidecar (pointing at camera footage).
    @discardableResult
    private func recording(_ name: String, exists: Bool = true, draftExtra: String = "", old: Bool = true) throws -> (video: URL, key: String, camera: URL, voice: URL) {
        let video = recordings.appendingPathComponent(name)
        try Data(repeating: 1, count: 1000).write(to: video)
        let id = VideoFileIdentity.ensureID(of: video) ?? UUID().uuidString
        let key = VideoFileIdentity.idKey(id)
        let camera = try folder("VideoCameras").appendingPathComponent("\(name)-cam.mov")
        try write("camera", to: camera)
        let voice = VideoVoiceEnhancer.cacheURL(for: video, trackIndex: 0)
        try FileManager.default.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("voice", to: voice)
        try write(#"{"sourcePath":"\#(video.path)","savedAt":0,"project":{}\#(draftExtra)}"#, to: try folder("VideoDrafts").appendingPathComponent("\(key).json"), old: old)
        try write(#"{"videoURLPath":"\#(video.path)","webcam":{"path":"\#(camera.path)","offset":0,"width":1280,"height":720}}"#, to: try folder("VideoMetadata").appendingPathComponent("\(key).json"), old: old)
        if !exists { try FileManager.default.removeItem(at: video) }
        return (video, key, camera, voice)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testOnlyDataOfRecordingsGoneForGoodIsRemoved() throws {
        let asset = try folder("VideoAssets").appendingPathComponent("11111111-logo.png")
        try write("png", to: asset)
        let orphanAsset = try folder("VideoAssets").appendingPathComponent("22222222-song.m4a")
        try write("m4a", to: orphanAsset)

        let kept = try recording("kept.mp4", draftExtra: #","image":"\#(asset.path)""#)
        let gone = try recording("gone.mp4", exists: false, draftExtra: #","music":"\#(orphanAsset.path)""#)
        // In the Trash: it could still come back.
        let trashed = try recording("trashed.mp4")
        try FileManager.default.moveItem(at: trashed.video, to: trash.appendingPathComponent("trashed.mp4"))
        // Moved elsewhere: Spotlight finds it by name, the ID matches.
        let moved = try recording("moved.mp4")
        let elsewhere = recordings.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let movedTo = elsewhere.appendingPathComponent("moved.mp4")
        try FileManager.default.moveItem(at: moved.video, to: movedTo)
        // Gone, but its draft was written a minute ago: left alone.
        let fresh = try recording("fresh.mp4", exists: false, old: false)
        // On a drive that isn't plugged in.
        let unplugged = try folder("VideoDrafts").appendingPathComponent("id-\(UUID().uuidString).json")
        try write(#"{"sourcePath":"/Volumes/NoSuchDrive-\#(UUID().uuidString)/talk.mp4","savedAt":0,"project":{}}"#, to: unplugged)
        // Camera footage no recording points to.
        let stray = try folder("VideoCameras").appendingPathComponent("stray.mov")
        try write("stray", to: stray)
        // Clipboard exports: an old one and today's.
        let oldExport = clipboard.appendingPathComponent("Shotnix Video old.mp4")
        try write("old", to: oldExport)
        let newExport = clipboard.appendingPathComponent("Shotnix Video new.mp4")
        try write("new", to: newExport, old: false)

        let before = VideoDataCleanup.usage()
        XCTAssertGreaterThan(before, 0)
        let finder: VideoDataCleanup.Finder = { name in name == "moved.mp4" ? [movedTo] : [] }
        let report = VideoDataCleanup.sweep(finder: finder)

        let drafts = support.appendingPathComponent("VideoDrafts")
        let metadata = support.appendingPathComponent("VideoMetadata")
        // Gone: its draft, data, camera footage, voice, and song.
        XCTAssertFalse(exists(drafts.appendingPathComponent("\(gone.key).json")))
        XCTAssertFalse(exists(metadata.appendingPathComponent("\(gone.key).json")))
        XCTAssertFalse(exists(gone.camera))
        XCTAssertFalse(exists(orphanAsset))
        XCTAssertFalse(exists(stray))
        XCTAssertFalse(exists(oldExport))
        // Everything that might still be wanted stays.
        for record in [kept, trashed, moved, fresh] {
            XCTAssertTrue(exists(drafts.appendingPathComponent("\(record.key).json")), "draft of \(record.video.lastPathComponent)")
            XCTAssertTrue(exists(metadata.appendingPathComponent("\(record.key).json")), "data of \(record.video.lastPathComponent)")
            XCTAssertTrue(exists(record.camera), "camera of \(record.video.lastPathComponent)")
        }
        XCTAssertTrue(exists(kept.voice), "the cleaned-up voice of a recording you still have")
        XCTAssertTrue(exists(asset), "a picture a live draft uses")
        XCTAssertTrue(exists(unplugged), "a recording on an unplugged drive")
        XCTAssertTrue(exists(newExport), "today's clipboard export")
        XCTAssertGreaterThanOrEqual(report.removedFiles, 6)
        XCTAssertLessThan(VideoDataCleanup.usage(), before)

        // Running again finds nothing more.
        XCTAssertEqual(VideoDataCleanup.sweep(finder: finder).removedFiles, 0)
    }

    func testSpotlightMatchesOnlyTheSameRecording() throws {
        let original = recordings.appendingPathComponent("demo.mp4")
        try Data(repeating: 2, count: 500).write(to: original)
        let id = try XCTUnwrap(VideoFileIdentity.ensureID(of: original))
        let other = recordings.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let impostor = other.appendingPathComponent("demo.mp4")
        try Data(repeating: 3, count: 500).write(to: impostor)
        _ = VideoFileIdentity.ensureID(of: impostor)
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(VideoDataCleanup.recordingExists(path: original.path, key: VideoFileIdentity.idKey(id), size: 500, finder: { _ in [impostor] }), "a different file with the same name doesn't count")
    }
}
