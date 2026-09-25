import XCTest
@testable import ShotnixCore

/// Recording data and drafts follow the video file: renames, moves, deep
/// folders — and never leak onto copies or a new file with the same name.
final class VideoStoreTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVideo(_ name: String, in folder: URL? = nil, bytes: Int = 1024) throws -> URL {
        let folder = folder ?? directory!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func metadata(for url: URL) -> VideoDemoRecordingMetadata {
        VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: 4, sourceWidth: 1280, sourceHeight: 800, fps: 30, nativeCursorVisible: false, cursorSamples: [VideoDemoCursorSample(time: 0, x: 0.5, y: 0.5)], clickEvents: [])
    }

    private func project(for url: URL, padding: Double) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: url, duration: 4, sourceSize: CGSize(width: 1280, height: 800))
        project.padding = padding
        return project
    }

    func testRenamedOrMovedRecordingKeepsItsDataAndEdits() throws {
        let original = try makeVideo("Recording.mp4")
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata(for: original), for: original))
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: original, padding: 0.2), for: original))

        let moved = directory.appendingPathComponent("Elsewhere/Renamed demo.mp4")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertEqual(VideoDemoSidecarStore.load(for: moved)?.cursorSamples.count, 1, "the pointer path came along")
        XCTAssertEqual(VideoDemoDraftStore.load(for: moved)?.project.padding ?? 0, 0.2, accuracy: 0.0001, "and so did the edits")
    }

    func testDeepFoldersSave() throws {
        // Well past the 255-byte file name limit the old names hit.
        let deep = directory.appendingPathComponent(String(repeating: "Ordner mit einem sehr langen Namen/", count: 6))
        let video = try makeVideo("Bildschirmaufnahme vom 25. September.mp4", in: deep)
        XCTAssertGreaterThan(video.path.utf8.count, 250)
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata(for: video), for: video))
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: video, padding: 0.3), for: video))
        XCTAssertNotNil(VideoDemoSidecarStore.load(for: video))
        XCTAssertEqual(VideoDemoDraftStore.load(for: video)?.project.padding ?? 0, 0.3, accuracy: 0.0001)
    }

    func testCopiesStartFreshAndNeverOverwriteTheOriginal() throws {
        let original = try makeVideo("Take.mp4")
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata(for: original), for: original))
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: original, padding: 0.2), for: original))
        let copy = directory.appendingPathComponent("Take copy.mp4")
        try FileManager.default.copyItem(at: original, to: copy)

        XCTAssertNotNil(VideoDemoSidecarStore.load(for: copy), "same recording, same pointer path")
        XCTAssertNil(VideoDemoDraftStore.load(for: copy), "but not the original's edits")
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: copy, padding: 0.05), for: copy))
        XCTAssertEqual(VideoDemoDraftStore.load(for: copy)?.project.padding ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(VideoDemoDraftStore.load(for: original)?.project.padding ?? 0, 0.2, accuracy: 0.0001, "the original's draft is untouched")
    }

    func testANewFileWithTheSameNameDoesntInheritEdits() throws {
        let url = try makeVideo("Demo.mp4", bytes: 1024)
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: url, padding: 0.2), for: url))
        // A new take saved over the old name (no recording ID on it).
        try FileManager.default.removeItem(at: url)
        _ = try makeVideo("Demo.mp4", bytes: 4096)
        XCTAssertNil(VideoDemoDraftStore.load(for: url))
    }

    func testDataFromEarlierVersionsIsFoundAndCarriedOver() throws {
        let url = try makeVideo("Old recording.mp4")
        let root = VideoStorageLocation.root.appendingPathComponent("Shotnix")
        // How 0.22 and earlier named the files.
        let legacy = VideoFileIdentity.legacyKey(url)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VideoMetadata"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VideoDrafts"), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata(for: url)).write(to: root.appendingPathComponent("VideoMetadata/\(legacy).json"))
        let record = VideoDemoDraftRecord(sourcePath: url.standardizedFileURL.path, savedAt: Date(), project: project(for: url, padding: 0.25))
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("VideoDrafts/\(legacy).json"))

        XCTAssertNotNil(VideoDemoSidecarStore.load(for: url))
        XCTAssertEqual(VideoDemoDraftStore.load(for: url)?.project.padding ?? 0, 0.25, accuracy: 0.0001)
        // Carried over to the recording's ID: a rename now keeps it.
        let renamed = directory.appendingPathComponent("Renamed.mp4")
        try FileManager.default.moveItem(at: url, to: renamed)
        XCTAssertNotNil(VideoDemoSidecarStore.load(for: renamed))
    }

    func testUnreadableDraftsAreSetAsideNotOverwritten() throws {
        let url = try makeVideo("Broken.mp4")
        XCTAssertTrue(VideoDemoDraftStore.save(project(for: url, padding: 0.2), for: url))
        let folder = VideoStorageLocation.root.appendingPathComponent("Shotnix/VideoDrafts")
        let key = VideoFileIdentity.idKey(try XCTUnwrap(VideoFileIdentity.id(of: url)))
        let draft = folder.appendingPathComponent(key).appendingPathExtension("json")
        try Data("{ not json".utf8).write(to: draft)
        XCTAssertNil(VideoDemoDraftStore.load(for: url))
        let asides = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(key) && $0.contains("unreadable") }
        XCTAssertEqual(asides.count, 1, "kept for recovery")
    }
}
