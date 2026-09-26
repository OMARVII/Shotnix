import AVFoundation
import XCTest
@testable import ShotnixCore

/// The export flow around the encoder: where files are written, what
/// happens on failure, ranges, captions left out of the picture, plain
/// failure messages, and the background queue.
final class VideoExportFlowTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recording(seconds: Double = 2) async throws -> VideoDemoProject {
        let url = directory.appendingPathComponent("source.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: seconds, fps: 30)
        }
        var project = VideoDemoProject.make(sourceURL: url, duration: seconds, sourceSize: CGSize(width: 640, height: 400))
        project.cursor.visible = false
        return project
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains("shotnix-partial") }
    }

    // MARK: Files

    func testExportReplacesAnExistingFileInPlace() async throws {
        let project = try await recording()
        let output = directory.appendingPathComponent("out.mp4")
        try Data("an older export".utf8).write(to: output)
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "the new video replaced the old file")
        XCTAssertTrue(leftovers().isEmpty, "no half-written file is left behind: \(leftovers())")
    }

    func testAFailedExportLeavesTheExistingFileAlone() async throws {
        let project = try await recording()
        let output = directory.appendingPathComponent("keep.mp4")
        let old = Data("keep me".utf8)
        try old.write(to: output)
        do {
            try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings(), shouldCancel: { true })
            XCTFail("the export was cancelled")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), old, "the existing file is untouched")
        XCTAssertTrue(leftovers().isEmpty)
    }

    func testTheWorkingFileSitsNextToTheDestination() {
        let destination = directory.appendingPathComponent("Movie.mp4")
        let temporary = VideoExportFiles.temporaryURL(beside: destination, fileExtension: "mp4")
        XCTAssertEqual(temporary.deletingLastPathComponent().path, directory.path, "same folder, same disk")
        XCTAssertTrue(temporary.lastPathComponent.hasPrefix("."), "hidden while it's written")
        XCTAssertEqual(temporary.pathExtension, "mp4")
        let unwritable = URL(fileURLWithPath: "/System/Movie.mp4")
        XCTAssertEqual(VideoExportFiles.temporaryURL(beside: unwritable, fileExtension: "mp4").deletingLastPathComponent().standardizedFileURL.path, FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    func testNotEnoughSpaceStopsBeforeStarting() {
        let url = directory.appendingPathComponent("big.mp4")
        XCTAssertThrowsError(try VideoExportFiles.checkSpace(for: url, needed: 2_000_000_000, available: 500_000_000)) { error in
            let message = VideoExportFailure.message(for: error)
            XCTAssertTrue(message.contains("free space"), message)
            XCTAssertTrue(message.contains("another drive"), message)
        }
        XCTAssertNoThrow(try VideoExportFiles.checkSpace(for: url, needed: 100_000_000, available: 5_000_000_000))
        XCTAssertNotNil(VideoExportFiles.availableBytes(at: url))
    }

    // MARK: Range

    func testRangeExportKeepsJustThatPart() async throws {
        let project = try await recording(seconds: 3)
        let output = directory.appendingPathComponent("range.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings(), range: .timeline(1.0...2.2))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1.2, accuracy: 0.1)

        // The part's first frame is the timeline's frame at 1.0 s.
        let trimmed = project.trimmed(toTimeline: 1.0...2.2, totalDuration: 3)
        XCTAssertEqual(trimmed.musicOffset, 1.0, accuracy: 0.001)
        XCTAssertEqual(trimmed.project.timelineClips.first?.sourceStart ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(trimmed.project.timelineDuration(totalDuration: 3), 1.2, accuracy: 0.01)
    }

    func testRangeKeepsTheCardsItReaches() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/r.mp4"), duration: 6, sourceSize: CGSize(width: 1280, height: 720))
        project.cards.intro = VideoTitleCard(enabled: true, title: "Hi", duration: 2)
        project.cards.outro = VideoTitleCard(enabled: true, title: "Bye", duration: 2)
        // Timeline: intro 0–2, clips 2–8, outro 8–10.
        let opening = project.trimmed(toTimeline: 0...4, totalDuration: 6).project
        XCTAssertTrue(opening.cards.intro.enabled)
        XCTAssertFalse(opening.cards.outro.enabled)
        XCTAssertEqual(opening.timelineDuration(totalDuration: 6), 4, accuracy: 0.01)
        let middle = project.trimmed(toTimeline: 3...6, totalDuration: 6).project
        XCTAssertFalse(middle.cards.intro.enabled)
        XCTAssertFalse(middle.cards.outro.enabled)
        XCTAssertEqual(middle.timelineDuration(totalDuration: 6), 3, accuracy: 0.01)
        let closing = project.trimmed(toTimeline: 7...10, totalDuration: 6).project
        XCTAssertTrue(closing.cards.outro.enabled)
        XCTAssertEqual(closing.timelineDuration(totalDuration: 6), 3, accuracy: 0.01)
    }

    func testARangeStartingInsideTheIntroCarriesOnItsAnimation() async throws {
        var project = try await recording(seconds: 3)
        project.cards.intro = VideoTitleCard(enabled: true, title: "Hello there", subtitle: "A quick tour", duration: 3)
        project.cards.outro = VideoTitleCard(enabled: true, title: "Thanks", duration: 2)
        // Timeline: intro 0–3, clips 3–6, outro 6–8. The range: 1.2–7.
        let total = 3.0
        let part = project.trimmed(toTimeline: 1.2...7.0, totalDuration: total).project
        XCTAssertEqual(part.cards.intro.skip, 1.2, accuracy: 0.001)
        XCTAssertEqual(part.timelineLeadIn, 1.8, accuracy: 0.001, "exactly the part of the intro the range covers")
        XCTAssertEqual(part.timelineDuration(totalDuration: total), 5.8, accuracy: 0.001)
        XCTAssertEqual(part.cards.intro.fullLength, 3, "the card's own clock is kept")

        // Frame for frame what the whole video shows at the same moments —
        // the title mid-rise, the dissolve into the video, the cut outro.
        let size = CGSize(width: 640, height: 400)
        let source = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85)).cropped(to: CGRect(origin: .zero, size: size))
        let wholePlan = VideoDemoExporter.makePlan(project: project, sourceDuration: total, recording: nil)
        let partPlan = VideoDemoExporter.makePlan(project: part, sourceDuration: total, recording: nil)
        let renderer = VideoFrameRenderer()
        func pixels(_ image: CIImage) -> [UInt8] {
            let cgImage = VideoRenderContext.shared.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
            var data = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            let context = CGContext(data: &data, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            return data
        }
        /// Share of pixels that visibly differ.
        func difference(_ a: CIImage, _ b: CIImage) -> Double {
            let left = pixels(a), right = pixels(b)
            var differing = 0
            for index in stride(from: 0, to: left.count, by: 4) where (0..<3).contains(where: { abs(Int(left[index + $0]) - Int(right[index + $0])) > 20 }) {
                differing += 1
            }
            return Double(differing) / Double(left.count / 4)
        }
        for (wholeTime, partTime) in [(1.3, 0.1), (1.7, 0.5), (2.8, 1.6), (6.3, 5.1), (6.9, 5.7)] {
            let whole = renderer.render(source: source, timelineTime: wholeTime, plan: wholePlan, outputSize: size)
            let cut = renderer.render(source: source, timelineTime: partTime, plan: partPlan, outputSize: size)
            XCTAssertLessThan(difference(whole, cut), 0.001, "the range at \(partTime) s shows the video at \(wholeTime) s")
        }
        // Starting the card over would show the title only beginning to rise.
        let restarted = renderer.render(source: source, timelineTime: 0.1, plan: wholePlan, outputSize: size)
        let carriedOn = renderer.render(source: source, timelineTime: 0.1, plan: partPlan, outputSize: size)
        XCTAssertGreaterThan(difference(restarted, carriedOn), 0.005, "the check can tell a restarted card apart")

        // The file is exactly the range.
        let output = directory.appendingPathComponent("from-the-intro.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings(), range: .timeline(1.2...7.0))
        let length = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(length, 5.8, accuracy: 0.1)

        // A range with nothing but a card in it isn't a video of its own.
        XCTAssertTrue(project.isOnlyCard(0.5...2.5, totalDuration: total))
        XCTAssertTrue(project.isOnlyCard(6.2...7.8, totalDuration: total))
        XCTAssertFalse(project.isOnlyCard(1.2...7.0, totalDuration: total))
        do {
            try await VideoDemoExporter.export(project: project, destinationURL: directory.appendingPathComponent("card-only.mp4"), settings: VideoInspection.mp4Settings(), range: .timeline(0.5...2.5))
            XCTFail("a card on its own isn't exported")
        } catch {
            XCTAssertTrue(VideoExportFailure.message(for: error).contains("only a title card"), VideoExportFailure.message(for: error))
        }
    }

    // MARK: Captions

    func testCaptionsCanBeLeftOutOfThePicture() async throws {
        var project = try await recording()
        project.padding = 0
        project.captions = [VideoCaptionLine(start: 0, end: 2, text: "Burned in or not")]
        project.captionStyle.visible = true
        var settings = VideoInspection.mp4Settings()
        let burned = directory.appendingPathComponent("burned.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: burned, settings: settings)
        settings.burnCaptions = false
        let clean = directory.appendingPathComponent("clean.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: clean, settings: settings)
        // The caption pill darkens the bottom middle of the frame.
        let withCaption = VideoInspection.color(of: try VideoInspection.frame(of: burned, at: 1.0), x: 0.5, y: 0.91, radius: 40)
        let without = VideoInspection.color(of: try VideoInspection.frame(of: clean, at: 1.0), x: 0.5, y: 0.91, radius: 40)
        XCTAssertGreaterThan(without.r + without.g + without.b, withCaption.r + withCaption.g + withCaption.b + 0.3, "burned in \(withCaption) vs left out \(without)")
    }

    // MARK: GIF

    func testGIFMemoryCapAndALighterSuggestion() {
        var settings = VideoExportSettings()
        settings.format = .gif
        settings.gifSize = .large
        settings.gifFPS = 24
        let canvas = CGSize(width: 1920, height: 1080)
        XCTAssertGreaterThan(settings.gifWorkingBytes(duration: 900, canvas: canvas), VideoExportSettings.gifMemoryLimit, "a 15-minute large GIF can't be made")
        XCTAssertLessThan(settings.gifWorkingBytes(duration: 5, canvas: canvas), VideoExportSettings.gifMemoryLimit)
        let lighter = settings.lighterGIF(duration: 20, canvas: canvas)
        XCTAssertNotNil(lighter)
        if let lighter {
            XCTAssertLessThanOrEqual(lighter.estimatedBytes(duration: 20, canvas: canvas, hasAudio: false), 25_000_000)
        }
        XCTAssertNil(settings.lighterGIF(duration: 3_000, canvas: canvas), "nothing fits an hour")
    }

    // MARK: Failure messages

    func testFailuresReadInPlainWords() {
        XCTAssertEqual(VideoExportFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), VideoExportFailure.diskFull)
        XCTAssertEqual(VideoExportFailure.message(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), VideoExportFailure.diskFull)
        XCTAssertEqual(VideoExportFailure.message(for: VideoDemoExportError.system(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue))), VideoExportFailure.diskFull)
        XCTAssertEqual(VideoExportFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)), VideoExportFailure.noPermission)
        XCTAssertEqual(VideoExportFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)), VideoExportFailure.readOnly)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertEqual(VideoExportFailure.message(for: wrapped), VideoExportFailure.diskFull, "the reason underneath counts")
        let unknown = VideoExportFailure.message(for: NSError(domain: "Other", code: 7, userInfo: [NSLocalizedDescriptionKey: "Something odd"]))
        XCTAssertTrue(unknown.contains("Something odd") && unknown.contains("Try again"), unknown)
        XCTAssertEqual(VideoExportFailure.message(for: VideoDemoExportError.cancelled), "Export cancelled.")
    }

    // MARK: Background queue

    @MainActor
    private func wait(for job: VideoExportQueue.Job, timeout: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !job.isDone {
            if Date() > deadline { XCTFail("export didn't finish"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testExportsQueueRunInTheBackgroundAndHoldQuitting() async throws {
        var project = try await recording()
        project.captions = [VideoCaptionLine(start: 0.2, end: 1.5, text: "Subtitles too")]
        var settings = VideoInspection.mp4Settings()
        settings.subtitles = .vtt
        let queue = VideoExportQueue.shared
        let first = queue.enqueue(project: project, recording: nil, settings: settings, destination: directory.appendingPathComponent("first.mp4"), toClipboard: false)
        let second = queue.enqueue(project: project, recording: nil, settings: VideoInspection.mp4Settings(), destination: directory.appendingPathComponent("second.mp4"), toClipboard: false)
        XCTAssertTrue(AppTermination.isBusy, "quitting waits for the exports")
        XCTAssertTrue(AppTermination.asksBeforeQuit, "and asks first")
        XCTAssertEqual(second.state, .queued, "one at a time")
        try await wait(for: first)
        try await wait(for: second)
        guard case .finished(let bytes) = first.state else { return XCTFail("first: \(first.state)") }
        XCTAssertGreaterThan(bytes, 0)
        guard case .finished = second.state else { return XCTFail("second: \(second.state)") }
        XCTAssertFalse(AppTermination.isBusy)
        XCTAssertLessThanOrEqual(first.startedAt ?? .distantFuture, second.startedAt ?? .distantPast)
        let vtt = directory.appendingPathComponent("first.vtt")
        let text = try String(contentsOf: vtt, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("WEBVTT"), "subtitles are saved next to the video")
        XCTAssertTrue(text.contains("Subtitles too"))
        queue.dismiss(first)
        queue.dismiss(second)
    }

    @MainActor
    func testAQueuedExportCanBeCancelledBeforeItStarts() async throws {
        let project = try await recording()
        let queue = VideoExportQueue.shared
        let running = queue.enqueue(project: project, recording: nil, settings: VideoInspection.mp4Settings(), destination: directory.appendingPathComponent("a.mp4"), toClipboard: false)
        let waiting = queue.enqueue(project: project, recording: nil, settings: VideoInspection.mp4Settings(), destination: directory.appendingPathComponent("b.mp4"), toClipboard: false)
        queue.cancel(waiting)
        XCTAssertEqual(waiting.state, .cancelled)
        try await wait(for: running)
        XCTAssertFalse(FileManager.default.exists(directory.appendingPathComponent("b.mp4")))
        queue.dismiss(running)
        queue.dismiss(waiting)
    }

    @MainActor
    func testTheEditorKeepsWorkingWhileItsSnapshotExports() async throws {
        let project = try await recording()
        VideoDemoDraftStore.delete(for: project.sourceURL)
        let model = VideoEditorModel(videoURL: project.sourceURL)
        await model.load()
        model.exportSettings = VideoInspection.mp4Settings()
        model.isExportPresented = true
        model.enqueueExport(to: directory.appendingPathComponent("snap.mp4"), settings: model.exportSettings, toClipboard: false)
        let job = try XCTUnwrap(model.exportJobs.last)
        let background = job.project.background
        // Editing right away changes the editor, not the running export.
        model.setStyle { $0.background = .color(VideoRGBA(1, 0, 0)) }
        XCTAssertEqual(job.project.background, background)
        XCTAssertNotEqual(model.project.background, background)
        if case .running = model.exportPhase {} else { XCTFail("the sheet shows it running") }
        try await wait(for: job)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard case .finished = model.exportPhase else { return XCTFail("\(model.exportPhase)") }
        // With the sheet closed the result stays in the pill; ⌘E starts fresh.
        model.closeExportSheet()
        XCTAssertEqual(model.exportPhase, .idle)
        VideoExportQueue.shared.dismiss(job)
        model.stop()
        VideoDemoDraftStore.delete(for: project.sourceURL)
    }
}

private extension FileManager {
    func exists(_ url: URL) -> Bool { fileExists(atPath: url.path) }
}
