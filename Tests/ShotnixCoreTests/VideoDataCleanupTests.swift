import Foundation
import XCTest
@testable import ShotnixCore

/// Leftover video data: the quiet daily sweep never takes the data of a
/// recording that's merely not found today (renamed, moved, on a drive
/// that isn't plugged in, somewhere Spotlight doesn't look) — only after
/// 30 days missing on every sweep. Clean Up lists what it would remove.
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

    private struct Made {
        let video: URL
        let key: String
        let camera: URL
        let voice: URL
        var draft: URL
        var sidecar: URL
        var files: [URL] { [draft, sidecar, camera] }
    }

    /// A recording with a draft and its own data (pointing at camera
    /// footage), all written days ago.
    @discardableResult
    private func recording(_ name: String, in place: URL? = nil, bookmark: Bool = false, draft: Bool = true, draftExtra: String = "", old: Bool = true) throws -> Made {
        let video = (place ?? recordings).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000 + name.count).write(to: video)
        let id = VideoFileIdentity.ensureID(of: video) ?? UUID().uuidString
        let key = VideoFileIdentity.idKey(id)
        let camera = try folder("VideoCameras").appendingPathComponent("\(name)-cam.mov")
        try write("camera", to: camera)
        let voice = VideoVoiceEnhancer.cacheURL(for: video, trackIndex: 0)
        try FileManager.default.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("voice", to: voice)
        let mark = bookmark ? (try video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)).base64EncodedString() : nil
        let draftURL = try folder("VideoDrafts").appendingPathComponent("\(key).json")
        if draft {
            let bookmarkField = mark.map { #","sourceBookmark":"\#($0)""# } ?? ""
            try write(#"{"sourcePath":"\#(video.path)","savedAt":0,"project":{}\#(bookmarkField)\#(draftExtra)}"#, to: draftURL, old: old)
        }
        let sidecar = try folder("VideoMetadata").appendingPathComponent("\(key).json")
        try write(#"{"videoURLPath":"\#(video.path)","webcam":{"path":"\#(camera.path)","offset":0,"width":1280,"height":720}}"#, to: sidecar, old: old)
        return Made(video: video, key: key, camera: camera, voice: voice, draft: draftURL, sidecar: sidecar)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: The quiet sweep

    func testTheQuietSweepKeepsRenamedMovedAndUnreachableRecordings() throws {
        // Renamed in Finder where it was (the ID stamp goes along).
        let renamed = try recording("Shotnix Recording 1.mov")
        let renamedTo = recordings.appendingPathComponent("Product demo.mov")
        try FileManager.default.moveItem(at: renamed.video, to: renamedTo)
        // Moved to a folder Spotlight doesn't index — its draft's bookmark follows.
        let followed = try recording("Walkthrough.mov", bookmark: true)
        let hidden = recordings.appendingPathComponent("Not indexed", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: followed.video, to: hidden.appendingPathComponent("Walkthrough final.mov"))
        // Moved and renamed where Spotlight looks (found by size, then ID).
        let spotted = try recording("Onboarding.mov")
        let elsewhere = recordings.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let spottedAt = elsewhere.appendingPathComponent("Onboarding v2.mov")
        try FileManager.default.moveItem(at: spotted.video, to: spottedAt)
        // Moved out of sight with nothing to follow (a drive since
        // unplugged, a folder Spotlight skips): not found today.
        let unseen = try recording("Old talk.mov")
        let away = recordings.deletingLastPathComponent().appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: unseen.video, to: away.appendingPathComponent("Old talk.mov"))
        // Saved on a drive that isn't plugged in.
        let unplugged = try folder("VideoDrafts").appendingPathComponent("id-\(UUID().uuidString).json")
        try write(#"{"sourcePath":"/Volumes/NoSuchDrive-\#(UUID().uuidString)/talk.mov","savedAt":0,"project":{}}"#, to: unplugged)
        // Things only Clean Up may touch.
        let strayCamera = try folder("VideoCameras").appendingPathComponent("stray.mov")
        try write("stray", to: strayCamera)
        let strayVoice = try folder("VideoAudio").appendingPathComponent("stray.m4a")
        try write("voice", to: strayVoice)
        let unusedPicture = try folder("VideoAssets").appendingPathComponent("unused.png")
        try write("png", to: unusedPicture)
        // Clipboard exports: an old one and today's.
        let oldExport = clipboard.appendingPathComponent("Shotnix Video old.mp4")
        try write("old", to: oldExport)
        let newExport = clipboard.appendingPathComponent("Shotnix Video new.mp4")
        try write("new", to: newExport, old: false)

        let size = Int64(1000 + "Onboarding.mov".count)
        let finder = VideoDataCleanup.Finder(byName: { _ in [] }, bySize: { $0 == size ? [spottedAt] : [] })
        let report = VideoDataCleanup.sweep(finder: finder)

        for made in [renamed, followed, spotted, unseen] {
            for file in made.files { XCTAssertTrue(exists(file), "\(file.lastPathComponent) of \(made.video.lastPathComponent) stays") }
            XCTAssertTrue(exists(made.voice), "its cleaned-up voice stays")
        }
        XCTAssertTrue(exists(unplugged), "a recording on a drive that isn't plugged in keeps its data")
        XCTAssertTrue(exists(strayCamera) && exists(strayVoice) && exists(unusedPicture), "only Clean Up removes those")
        XCTAssertFalse(exists(oldExport), "old clipboard exports go")
        XCTAssertTrue(exists(newExport), "today's stays")
        XCTAssertEqual(report.removedFiles, 1)

        // Found ones aren't counted as missing; the one out of sight is, from today.
        XCTAssertNil(VideoDataCleanup.missingSince(renamed.key), "found by its ID where it was")
        XCTAssertNil(VideoDataCleanup.missingSince(followed.key), "found through its bookmark")
        XCTAssertNil(VideoDataCleanup.missingSince(spotted.key), "found by Spotlight")
        XCTAssertNotNil(VideoDataCleanup.missingSince(unseen.key), "missing from today")
    }

    func testDataGoesOnlyAfterThirtyDaysMissingOnEverySweep() throws {
        let gone = try recording("Deleted.mov")
        try FileManager.default.removeItem(at: gone.video)
        let back = try recording("Comes back.mov")
        let parked = recordings.deletingLastPathComponent().appendingPathComponent("parked.mov")
        try FileManager.default.moveItem(at: back.video, to: parked)

        let start = Date()
        VideoDataCleanup.sweep(now: start, finder: .nowhere)
        VideoDataCleanup.sweep(now: start.addingTimeInterval(29 * 86_400), finder: .nowhere)
        for file in gone.files + back.files { XCTAssertTrue(exists(file), "\(file.lastPathComponent): 29 days missing isn't enough") }

        // The other one turns up again: its count starts over.
        try FileManager.default.moveItem(at: parked, to: back.video)
        VideoDataCleanup.sweep(now: start.addingTimeInterval(29.5 * 86_400), finder: .nowhere)
        XCTAssertNil(VideoDataCleanup.missingSince(back.key))
        try FileManager.default.moveItem(at: back.video, to: parked)

        let report = VideoDataCleanup.sweep(now: start.addingTimeInterval(31 * 86_400), finder: .nowhere)
        for file in gone.files { XCTAssertFalse(exists(file), "\(file.lastPathComponent): missing on every sweep for 30 days") }
        for file in back.files { XCTAssertTrue(exists(file), "\(file.lastPathComponent): seen a day ago") }
        XCTAssertEqual(report.removedFiles, 3)
        XCTAssertTrue(exists(gone.voice), "the quiet sweep leaves cleaned-up voice to Clean Up")
    }

    // MARK: Saved paths

    @MainActor
    func testOpeningOrAddingARecordingPointsItsDataToWhereItIsNow() async throws {
        let original = recordings.appendingPathComponent("Screen take.mp4")
        try await VideoTestSupport.writeFakeRecording(to: original, size: CGSize(width: 320, height: 200), seconds: 1, fps: 30)
        let metadata = VideoDemoRecordingMetadata(videoURLPath: original.path, createdAt: Date(), duration: 1, sourceWidth: 320, sourceHeight: 200, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [])
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: original))
        let renamed = recordings.appendingPathComponent("Launch video.mp4")
        try FileManager.default.moveItem(at: original, to: renamed)

        let model = VideoEditorModel(videoURL: renamed)
        let saved = try XCTUnwrap(VideoDemoSidecarStore.load(for: renamed))
        XCTAssertEqual(saved.videoURLPath, VideoFileIdentity.canonicalURL(renamed).path, "opened: its data points to the new name")
        XCTAssertNotNil(saved.bookmark)
        model.stop()

        // Added to another video from its new place.
        let host = recordings.appendingPathComponent("Host.mp4")
        try await VideoTestSupport.writeFakeRecording(to: host, size: CGSize(width: 320, height: 200), seconds: 1, fps: 30)
        let moved = recordings.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let addedURL = moved.appendingPathComponent("Launch video.mp4")
        try FileManager.default.moveItem(at: renamed, to: addedURL)
        VideoDemoDraftStore.delete(for: host)
        let editor = VideoEditorModel(videoURL: host)
        await editor.load()
        let appended = await editor.appendVideo(addedURL)
        XCTAssertTrue(appended)
        XCTAssertEqual(VideoDemoSidecarStore.load(for: addedURL)?.videoURLPath, VideoFileIdentity.canonicalURL(addedURL).path, "added: its data points there too")
        editor.stop()
        VideoDemoDraftStore.delete(for: host)
    }

    // MARK: Clean Up

    func testCleanUpSaysExactlyWhatGoesAndRemovesOnlyThat() throws {
        let gone = try recording("Gone for good.mov")
        try FileManager.default.removeItem(at: gone.video)
        let renamed = try recording("Before.mov")
        try FileManager.default.moveItem(at: renamed.video, to: recordings.appendingPathComponent("After.mov"))
        let strayCamera = try folder("VideoCameras").appendingPathComponent("stray.mov")
        try write("stray", to: strayCamera)
        let unusedPicture = try folder("VideoAssets").appendingPathComponent("11111111-unused.png")
        try write("png", to: unusedPicture)
        // Only an open editor's undo history still uses this song.
        let undoneSong = try folder("VideoAssets").appendingPathComponent("22222222-song.m4a")
        try write("m4a", to: undoneSong)
        let oldExport = clipboard.appendingPathComponent("Shotnix Video old.mp4")
        try write("old", to: oldExport)

        let plan = VideoDataCleanup.plan(finder: .nowhere, inUse: [undoneSong.path])
        func paths(_ urls: [URL]) -> [String] { urls.map { $0.resolvingSymlinksInPath().path } }
        XCTAssertEqual(plan.missingRecordings.map(\.name), ["Gone for good.mov"], "the renamed one is found by its ID")
        XCTAssertEqual(paths(plan.unusedCameraFootage), paths([strayCamera]))
        XCTAssertEqual(paths(plan.unusedAssets), paths([unusedPicture]), "a song undo can bring back stays")
        XCTAssertEqual(paths(plan.oldClipboardExports), paths([oldExport]))
        XCTAssertTrue(plan.summary.contains("“Gone for good.mov” (was in Recordings)"), plan.summary)
        XCTAssertTrue(plan.summary.contains("Camera footage no recording uses"), plan.summary)
        XCTAssertTrue(plan.summary.contains("Pictures and songs no video uses"), plan.summary)
        XCTAssertTrue(plan.summary.contains("Clipboard exports older than a day"), plan.summary)

        VideoDataCleanup.perform(plan)
        for file in gone.files { XCTAssertFalse(exists(file), file.lastPathComponent) }
        XCTAssertFalse(exists(gone.voice), "its cleaned-up voice")
        XCTAssertFalse(exists(strayCamera))
        XCTAssertFalse(exists(unusedPicture))
        XCTAssertFalse(exists(oldExport))
        for file in renamed.files { XCTAssertTrue(exists(file), "\(file.lastPathComponent) of the renamed recording stays") }
        XCTAssertTrue(exists(undoneSong))
        XCTAssertTrue(VideoDataCleanup.plan(finder: .nowhere, inUse: [undoneSong.path]).isEmpty, "nothing more to remove")
    }

    func testAJustAddedPictureWaitsForItsDraft() throws {
        // A logo last touched long ago, added to an edit no draft has saved yet.
        let logo = recordings.appendingPathComponent("logo.png")
        try write("png", to: logo)
        try age(logo, days: 400)
        let stored = try VideoAssetStore.importFile(logo)
        XCTAssertTrue(stored.path.hasPrefix(support.path), "copied into the app's own folder")
        XCTAssertFalse(VideoDataCleanup.plan(finder: .nowhere).unusedAssets.contains(stored), "the copy counts as new, so the grace day covers it")
    }

    func testSpotlightMatchesOnlyTheSameRecording() throws {
        let original = try recording("demo.mov", draft: false)
        let other = recordings.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let impostor = other.appendingPathComponent("demo.mov")
        try Data(repeating: 3, count: 1008).write(to: impostor)
        _ = VideoFileIdentity.ensureID(of: impostor)
        try FileManager.default.removeItem(at: original.video)
        let known = try XCTUnwrap(VideoDataCleanup.recordings().first { $0.key == original.key })
        let finder = VideoDataCleanup.Finder(byName: { _ in [impostor] }, bySize: { _ in [impostor] })
        XCTAssertEqual(VideoDataCleanup.locate(known, finder: finder), .missing, "a different file with the same name and size doesn't count")
    }
}
