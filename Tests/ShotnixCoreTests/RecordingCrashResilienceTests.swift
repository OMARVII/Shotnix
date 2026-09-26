import AVFoundation
import XCTest
@testable import ShotnixCore

/// A recording whose process dies mid-take — a crash, a force quit, power
/// loss — must still play. The test runs a writer in a child process (this
/// same test, started again by the test runner), kills it without warning,
/// and opens what reached the disk.
final class RecordingCrashResilienceTests: XCTestCase {
    private static let childKey = "SHOTNIX_CRASH_WRITER_OUTPUT"

    func testKilledRecordingStillPlays() async throws {
        if let output = ProcessInfo.processInfo.environment[Self.childKey] {
            try Self.writeUntilKilled(to: URL(fileURLWithPath: output))
        }

        let runner = ProcessInfo.processInfo.arguments.first ?? ""
        guard runner.hasSuffix("/xctest"), FileManager.default.isExecutableFile(atPath: runner) else {
            throw XCTSkip("needs the xctest runner to start the writer in a child process (got \(runner))")
        }
        let bundle = Bundle(for: Self.self).bundlePath
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString).mp4")
        let progress = url.appendingPathExtension("progress")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: progress)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = ["-XCTest", "ShotnixCoreTests.RecordingCrashResilienceTests/testKilledRecordingStillPlays", bundle]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childKey] = url.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        // Five seconds of recording on disk, then no warning at all.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, process.isRunning {
            if let text = try? String(contentsOf: progress, encoding: .utf8), let seconds = Double(text), seconds >= 5 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(process.isRunning, "the writer child exited early")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)

        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "an interrupted recording opens")
        let duration = try await asset.load(.duration).seconds
        // Fragments every 2 s: at most the last couple of seconds are lost.
        XCTAssertGreaterThanOrEqual(duration, 2.9)
        let frames = try await RecordingTestBuffers.videoFrameTimes(url)
        XCTAssertGreaterThanOrEqual(frames.count, 85)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "the microphone track survives too")
    }

    /// The child: the recorder's own writer and append path, fed in real time.
    private static func writeUntilKilled(to url: URL) throws -> Never {
        let handles = try RecordingEngine.makeWriter(
            url: url,
            format: RecordingVideoFormat(codec: .h264, width: 320, height: 180),
            fps: 30,
            quality: .balanced,
            microphone: true,
            systemAudio: false
        )
        let core = RecordingWriterCore()
        core.begin(handles: handles, frameDuration: CMTime(value: 1, timescale: 30), onFirstFrame: { _ in }, onWriterFailure: {})
        let progress = url.appendingPathExtension("progress")
        let origin = CACurrentMediaTime()
        var audioTime = origin
        var frame = 0
        while true {
            let host = origin + Double(frame) / 30
            while CACurrentMediaTime() < host { usleep(1_000) }
            core.appendVideo(RecordingTestBuffers.video(at: host, width: 320, height: 180, shade: UInt8(40 + frame % 180)))
            while audioTime < host + 1.0 / 30 {
                core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 480, channels: 1, planar: false) { t in Float(sin(t * 2 * .pi * 440)) * 0.3 }, to: .microphone)
                audioTime += 480.0 / 48_000
            }
            frame += 1
            if frame % 15 == 0 {
                try? String(Double(frame) / 30).write(to: progress, atomically: true, encoding: .utf8)
            }
        }
    }
}
