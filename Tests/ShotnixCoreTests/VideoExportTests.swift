import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotnixCore

/// End-to-end export: synthesizes a recording, runs the real exporter
/// (composition → renderer → hardware encoder / GIF) and inspects the file.
final class VideoExportTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(seconds: Double = 2) async throws -> (URL, VideoDemoProject, VideoDemoRecordingMetadata) {
        let url = directory.appendingPathComponent("source.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1280, height: 800), seconds: seconds, fps: 30)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(
            waypoints: [.init(x: 0.3, y: 0.3, arrive: 0, click: false), .init(x: 0.7, y: 0.6, arrive: seconds * 0.6, click: true)],
            duration: seconds
        )
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: 1280, sourceHeight: 800, fps: 30,
            nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2, renderCursor: true
        )
        var project = VideoDemoProject.make(sourceURL: url, duration: seconds, sourceSize: CGSize(width: 1280, height: 800))
        project.apply(metadata: metadata)
        project.zoomRegions = [VideoZoomRegion(start: 0.2, end: seconds - 0.2, scale: 2, followsCursor: true)]
        return (url, project, metadata)
    }

    func testMP4ExportMatchesSettings() async throws {
        let (_, project, metadata) = try await source()
        let output = directory.appendingPathComponent("out.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 60
        settings.endCard = false
        var reported: [Double] = []
        let lock = NSLock()
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings, progress: { value in
            lock.lock(); reported.append(value); lock.unlock()
        })

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1280, accuracy: 2)
        XCTAssertEqual(size.height, 720, accuracy: 2)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(Double(fps), 60, accuracy: 2)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        XCTAssertFalse(reported.isEmpty)
    }

    func testEndCardExtendsTheVideo() async throws {
        let (_, project, metadata) = try await source(seconds: 1.5)
        let output = directory.appendingPathComponent("card.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = true
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1.5 + VideoDemoExporter.endCardDuration, accuracy: 0.15)
    }

    func testHEVCExportAndVerticalCanvas() async throws {
        var (_, project, metadata) = try await source(seconds: 1)
        project.aspectPreset = .vertical
        let output = directory.appendingPathComponent("vertical.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.codec = .hevc
        settings.fps = 30
        settings.endCard = false
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 720, accuracy: 2)
        XCTAssertEqual(size.height, 1280, accuracy: 2)
        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC)
    }

    func testGIFExport() async throws {
        let (_, project, metadata) = try await source(seconds: 1.2)
        let output = directory.appendingPathComponent("out.gif")
        var settings = VideoExportSettings()
        settings.format = .gif
        settings.gifSize = .small
        settings.gifFPS = 15
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 12)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 480)
    }

    func testExportRespectsCutsAndSpeed() async throws {
        var (_, project, metadata) = try await source(seconds: 3)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1),
            VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 3, speed: 2),
        ]
        let output = directory.appendingPathComponent("cut.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
    }

    func testCancelStopsTheExport() async throws {
        let (_, project, metadata) = try await source(seconds: 3)
        let output = directory.appendingPathComponent("cancel.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p1080
        settings.endCard = false
        do {
            try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings, shouldCancel: { true })
            XCTFail("export should have been cancelled")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testAudioSurvivesCutsSpeedAndAShortAudioTrack() async throws {
        let url = directory.appendingPathComponent("withaudio.mp4")
        // Audio ends 0.3s before the video — common in real recordings.
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 3, fps: 30, audioSeconds: 2.7)
        var project = VideoDemoProject.make(sourceURL: url, duration: 3, sourceSize: CGSize(width: 640, height: 400))
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1),
            VideoDemoTimelineClip(sourceStart: 1.5, sourceEnd: 3, speed: 1.5),
        ]
        let output = directory.appendingPathComponent("audio-out.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: settings)
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first, "the export keeps its sound")
        let range = try await audio.load(.timeRange)
        // 1s + (1.5s → 1.2s of audio at 1.5×) ≈ 1.8s of sound.
        XCTAssertGreaterThan(range.duration.seconds, 1.5)
    }

    func testOutputSizesAndEstimates() {
        var settings = VideoExportSettings()
        settings.resolution = .p2160
        XCTAssertEqual(settings.outputSize(canvas: CGSize(width: 1920, height: 1080)), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(settings.outputSize(canvas: CGSize(width: 1080, height: 1920)), CGSize(width: 2160, height: 3840))
        settings.resolution = .p1080
        XCTAssertEqual(settings.outputSize(canvas: CGSize(width: 1440, height: 1080)), CGSize(width: 1440, height: 1080))
        settings.format = .gif
        settings.gifSize = .medium
        XCTAssertEqual(settings.outputSize(canvas: CGSize(width: 1920, height: 1080)), CGSize(width: 720, height: 406))

        var mp4 = VideoExportSettings()
        mp4.quality = .studio
        let studio = mp4.estimatedBytes(duration: 60, canvas: CGSize(width: 1920, height: 1080), hasAudio: true)
        mp4.quality = .web
        let web = mp4.estimatedBytes(duration: 60, canvas: CGSize(width: 1920, height: 1080), hasAudio: true)
        XCTAssertGreaterThan(studio, web * 3)
        mp4.codec = .hevc
        XCTAssertLessThan(mp4.estimatedBytes(duration: 60, canvas: CGSize(width: 1920, height: 1080), hasAudio: true), web)
    }
}
