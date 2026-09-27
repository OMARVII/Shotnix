import AppKit
import AVFoundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import XCTest
@testable import ShotnixCore

/// A long recording, start to finish, watching the app's memory: a real
/// 5-minute screen recording of a Retina area (3010 × 1716 pixels at 60 fps,
/// like the recording that grew the editor to 77 GB), then the editor on it:
/// playing, scrubbing, editing, and a high-quality export. Opt-in, and it
/// needs Screen Recording permission for the test runner:
///
///   SHOTNIX_MEMORY_DIR=/path swift test --filter EditorMemoryValidationTests
///
/// Put something moving on the built-in display while it records (the
/// recording leaves out this process's own windows). The recording is kept
/// in the folder, so the editor part can run again on it; a memory log for
/// each run goes next to it. SHOTNIX_MEMORY_SECONDS shortens the recording;
/// SHOTNIX_MEMORY_FPS and SHOTNIX_MEMORY_QUALITY pick other settings, and
/// SHOTNIX_MEMORY_SCREEN=main records the whole main display instead.
@MainActor
final class EditorMemoryValidationTests: XCTestCase {
    private var folder: URL!
    private var recording: URL { folder.appendingPathComponent("recording.mp4") }
    private var metadataURL: URL { folder.appendingPathComponent("recording-metadata.json") }

    override func setUp() async throws {
        try await super.setUp()
        guard let path = ProcessInfo.processInfo.environment["SHOTNIX_MEMORY_DIR"] else {
            throw XCTSkip("Set SHOTNIX_MEMORY_DIR to run the long-recording memory validation")
        }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        VideoTestStorage.isolate()
    }

    // MARK: Recording

    func test1RecordsFiveMinutesOfARetinaArea() async throws {
        guard !FileManager.default.fileExists(atPath: recording.path) else {
            throw XCTSkip("\(recording.path) exists: delete it to record again")
        }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("needs Screen Recording permission") }
        let wholeMainDisplay = ProcessInfo.processInfo.environment["SHOTNIX_MEMORY_SCREEN"] == "main"
        guard let screen = wholeMainDisplay ? NSScreen.screens.first : NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else {
            throw XCTSkip("needs a Retina display")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["SHOTNIX_MEMORY_SECONDS"] ?? "") ?? 300

        var displayAssertion: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Shotnix memory validation" as CFString, &displayAssertion)
        defer { IOPMAssertionRelease(displayAssertion) }

        let suiteName = "ShotnixCoreTests.EditorMemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        Settings.defaults = defaults
        defer {
            Settings.defaults = .standard
            defaults.removePersistentDomain(forName: suiteName)
        }
        let takes = folder.appendingPathComponent("takes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        XCTAssertTrue(Settings.setAutoSaveLocation(takes.path))
        Settings.recordingMicrophone = false
        Settings.recordingSystemAudio = false
        Settings.recordingCamera = false
        Settings.recordingKeystrokes = false
        Settings.openVideoEditorAfterRecording = false
        // The defaults unless SHOTNIX_MEMORY_FPS / SHOTNIX_MEMORY_QUALITY say otherwise.
        Settings.recordingFPS = Int(ProcessInfo.processInfo.environment["SHOTNIX_MEMORY_FPS"] ?? "") ?? 60
        Settings.recordingQuality = ProcessInfo.processInfo.environment["SHOTNIX_MEMORY_QUALITY"] ?? "high"

        // 1505 × 858 points: 3010 × 1716 pixels, the reported recording's size.
        let area = wholeMainDisplay ? screen.frame : CGRect(x: screen.frame.minX + 3, y: screen.frame.minY + 60, width: 1505, height: 858)
        let engine = RecordingEngine()
        var finished: FinishedRecording?
        engine.recordingFinishedHandler = { finished = $0 }
        let log = MemoryLog(url: folder.appendingPathComponent("memory-recording.csv"))
        await engine.startRecording(rect: area, on: screen)
        guard engine.elapsedSeconds != nil else { throw XCTSkip("ScreenCaptureKit didn't start a stream") }

        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(nanoseconds: 500_000_000)
            log.sample("recording")
        }
        engine.stopRecording()
        let deadline = Date().addingTimeInterval(120)
        while finished == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            log.sample("saving")
        }
        let url = try XCTUnwrap(finished?.url, "the recording didn't finish")
        // The pointer path and activity go along: the editor run restores
        // them (each run's app data is its own).
        let metadata = try XCTUnwrap(VideoDemoSidecarStore.load(for: url))
        try JSONEncoder().encode(metadata).write(to: metadataURL)
        try FileManager.default.moveItem(at: url, to: recording)
        try? FileManager.default.removeItem(at: takes)

        let track = try await XCTUnwrapAsync(await AVURLAsset(url: recording).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, wholeMainDisplay ? CGSize(width: area.width * screen.backingScaleFactor, height: area.height * screen.backingScaleFactor) : CGSize(width: 3010, height: 1716))
        let duration = try await AVURLAsset(url: recording).load(.duration).seconds
        XCTAssertEqual(duration, seconds, accuracy: 2)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: recording.path)[.size] as? Int) ?? 0
        print(String(format: "[memory] recorded %.1f MB, %.1f Mbps", Double(bytes) / 1_048_576, Double(bytes) * 8 / duration / 1_000_000))
        log.finish()
        print("[memory] recording: \(recording.path), \(Int(duration)) s, peak \(log.peakDescription)")
        XCTAssertLessThan(log.peak, 2 << 30, "recording stays under 2 GB")
    }

    // MARK: Editing

    func test2EditsAndExportsItWithinBoundedMemory() async throws {
        guard FileManager.default.fileExists(atPath: recording.path) else { throw XCTSkip("record first (test1)") }
        if let data = try? Data(contentsOf: metadataURL) {
            let metadata = try JSONDecoder().decode(VideoDemoRecordingMetadata.self, from: data)
            XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: recording))
        }
        UserDefaults.standard.set(true, forKey: "videoEditorTipsDismissed")
        let log = MemoryLog(url: folder.appendingPathComponent("memory-editor.csv"))
        var peaks: [(String, UInt64)] = []
        /// Runs `step` every 0.1 s for `seconds`, sampling memory every 0.5 s.
        func phase(_ name: String, seconds: Double, step: (Double) -> Void = { _ in }) async throws {
            let start = Date()
            var peak: UInt64 = 0
            var lastSample = Date.distantPast
            while Date().timeIntervalSince(start) < seconds {
                step(Date().timeIntervalSince(start))
                try await Task.sleep(nanoseconds: 100_000_000)
                if Date().timeIntervalSince(lastSample) >= 0.5 {
                    peak = max(peak, log.sample(name))
                    lastSample = Date()
                }
            }
            peaks.append((name, peak))
            print(String(format: "[memory] %@: peak %.0f MB, now %.0f MB", name, Double(peak) / 1_048_576, Double(MemoryLog.footprint) / 1_048_576))
        }

        log.sample("start")
        let controller = VideoDemoEditorWindowController(videoURL: recording)
        controller.showWindow(nil)
        let model = controller.model
        defer { controller.window?.close() }

        // Opening: the filmstrip and waveform load; then it sits there.
        try await phase("open", seconds: 20)
        XCTAssertTrue(model.isReady, model.loadError ?? "the editor didn't load")
        let duration = model.timelineDuration
        XCTAssertGreaterThan(duration, 60)
        try await phase("idle", seconds: 30)

        model.togglePlay()
        try await phase("play", seconds: 60)
        model.togglePlay()

        // Scrubbing back and forth across the whole recording, then letting go.
        try await phase("scrub", seconds: 20) { elapsed in
            let sweep = (elapsed / 5).truncatingRemainder(dividingBy: 2)
            model.seek(to: duration * (sweep < 1 ? sweep : 2 - sweep), fast: true)
        }
        model.seek(to: duration / 2)

        // Edits: a cut, zooms, a text, sped-up idle stretches, then playing
        // the edit.
        model.seek(to: 40)
        try await phase("edit", seconds: 2)
        model.splitAtPlayhead()
        for time in stride(from: 20.0, to: min(duration - 10, 240), by: 55) {
            _ = model.addZoom(at: time)
        }
        model.addOverlay(.text)
        model.speedUpIdle()
        try await phase("edit", seconds: 10)
        model.seek(to: 0)
        model.togglePlay()
        try await phase("play edit", seconds: 45)
        model.togglePlay()

        // The export: 4K, 60 fps, Studio quality.
        let exported = folder.appendingPathComponent("export.mp4")
        try? FileManager.default.removeItem(at: exported)
        let settings = VideoExportSettings(format: .mp4, resolution: .p2160, fps: 60, quality: .studio, codec: .h264)
        model.enqueueExport(to: exported, settings: settings, toClipboard: false)
        let job = try XCTUnwrap(model.exportJobs.last)
        let exportStart = Date()
        var exportPeak: UInt64 = 0
        while !job.isDone, Date().timeIntervalSince(exportStart) < 1800 {
            try await Task.sleep(nanoseconds: 500_000_000)
            exportPeak = max(exportPeak, log.sample("export"))
        }
        peaks.append(("export", exportPeak))
        print(String(format: "[memory] export: %.0f s, peak %.0f MB, state %@", Date().timeIntervalSince(exportStart), Double(exportPeak) / 1_048_576, "\(job.state)"))
        guard case .finished = job.state else { return XCTFail("export didn't finish: \(job.state)") }
        let track = try await XCTUnwrapAsync(await AVURLAsset(url: exported).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        print("[memory] exported \(Int(size.width))×\(Int(size.height)), \(((try? FileManager.default.attributesOfItem(atPath: exported.path)[.size] as? Int) ?? 0) / 1_048_576) MB")

        try await phase("after", seconds: 20)
        log.finish()
        print("[memory] editor peak \(log.peakDescription); log: \(folder.appendingPathComponent("memory-editor.csv").path)")
        // Real headroom on an 18 GB Mac. The report: 77 GB.
        XCTAssertLessThan(log.peak, 4 << 30, "the editor stays under 4 GB: \(peaks.map { "\($0.0) \($0.1 >> 20) MB" })")
    }
}

/// The process's footprint (what macOS's memory limit counts, compressed
/// memory included), sampled to a CSV.
final class MemoryLog {
    private let handle: FileHandle?
    private let start = Date()
    private(set) var peak: UInt64 = 0

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("seconds,phase,footprint_mb\n".utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @discardableResult
    func sample(_ phase: String) -> UInt64 {
        let value = Self.footprint
        peak = max(peak, value)
        let line = String(format: "%.1f,%@,%.0f\n", Date().timeIntervalSince(start), phase, Double(value) / 1_048_576)
        handle?.write(Data(line.utf8))
        return value
    }

    var peakDescription: String { String(format: "%.0f MB", Double(peak) / 1_048_576) }

    func finish() { try? handle?.close() }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, message, file: file, line: line)
}
