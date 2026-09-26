import AVFoundation
import XCTest
@testable import ShotnixCore

/// Recording time: t=0 at the first frame, pauses cut out, and every audio
/// track kept in step with the picture.
final class RecordingTimelineTests: XCTestCase {

    // MARK: Timeline

    func testTimeStartsAtTheFirstFrame() {
        var timeline = RecordingTimeline()
        XCTAssertNil(timeline.time(at: 100))
        XCTAssertEqual(timeline.duration(at: 100), 0)
        timeline.start(at: 100)
        timeline.start(at: 105) // only the first frame counts
        XCTAssertEqual(timeline.time(at: 100), 0)
        XCTAssertEqual(timeline.time(at: 102.5), 2.5)
        XCTAssertEqual(timeline.time(at: 99.5), -0.5, "captured before the first frame")
        XCTAssertEqual(timeline.duration(at: 103), 3)
    }

    func testPausesAreCutOut() {
        var timeline = RecordingTimeline()
        timeline.start(at: 10)
        timeline.pause(at: 12)
        XCTAssertTrue(timeline.isPaused)
        XCTAssertNil(timeline.time(at: 12.5), "nothing captured while paused is kept")
        XCTAssertEqual(timeline.duration(at: 20), 2, "the clock stops while paused")
        timeline.resume(at: 15)
        XCTAssertFalse(timeline.isPaused)
        XCTAssertEqual(timeline.time(at: 11), 1, "before the pause: unchanged")
        XCTAssertNil(timeline.time(at: 14.9))
        XCTAssertEqual(timeline.time(at: 15)!, 2, accuracy: 1e-9, "picks up exactly where the pause began")
        XCTAssertEqual(timeline.time(at: 16)!, 3, accuracy: 1e-9)

        timeline.pause(at: 17)
        timeline.resume(at: 18.5)
        XCTAssertEqual(timeline.time(at: 19)!, 19 - 10 - 3 - 1.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.duration(at: 20), 20 - 10 - 4.5, accuracy: 1e-9)
    }

    func testPauseBeforeTheFirstFrameIsNotSubtracted() {
        var timeline = RecordingTimeline()
        timeline.pause(at: 5)
        timeline.resume(at: 6)
        timeline.start(at: 7)
        XCTAssertEqual(timeline.time(at: 8), 1)
        // A pause that straddles t=0 only counts from t=0.
        var straddling = RecordingTimeline()
        straddling.pause(at: 9)
        straddling.start(at: 10)
        straddling.resume(at: 11)
        XCTAssertEqual(straddling.time(at: 12)!, 1, accuracy: 1e-9)
    }

    func testReanchorMovesTimeZero() {
        var timeline = RecordingTimeline()
        timeline.start(at: 1)
        timeline.reanchor(to: 1.25)
        XCTAssertEqual(timeline.time(at: 2.25), 1)
    }

    // MARK: Audio placement

    func testAudioBeforeTheFirstFrameIsDroppedOrTrimmed() {
        // Entirely before t=0: dropped.
        XCTAssertNil(RecordingAudioPlacement.place(start: -0.3, duration: 0.02, written: 0))
        // Straddling t=0: trimmed exactly, so voice lines up with the picture.
        XCTAssertEqual(RecordingAudioPlacement.place(start: -0.012, duration: 0.021, written: 0), RecordingAudioPlacement(silence: 0, trim: 0.012))
        // Starting late (system audio often does): silence up to it.
        XCTAssertEqual(RecordingAudioPlacement.place(start: 0.2, duration: 0.021, written: 0), RecordingAudioPlacement(silence: 0.2, trim: 0))
    }

    func testDropoutsBecomeSilenceAndOverlapsAreTrimmed() {
        // A second of missing buffers: filled, so later audio doesn't slide earlier.
        XCTAssertEqual(RecordingAudioPlacement.place(start: 5, duration: 0.02, written: 4), RecordingAudioPlacement(silence: 1, trim: 0))
        // Overlapping what's written by more than the tolerance: the overlap is cut.
        let overlap = RecordingAudioPlacement.place(start: 3.9, duration: 0.2, written: 4)
        XCTAssertEqual(overlap?.silence, 0)
        XCTAssertEqual(overlap?.trim ?? 0, 0.1, accuracy: 1e-9)
        // Clock drift within tolerance: left alone.
        XCTAssertEqual(RecordingAudioPlacement.place(start: 4.01, duration: 0.02, written: 4), RecordingAudioPlacement(silence: 0, trim: 0))
        XCTAssertEqual(RecordingAudioPlacement.place(start: 3.99, duration: 0.02, written: 4), RecordingAudioPlacement(silence: 0, trim: 0))
        // Already written in full: dropped.
        XCTAssertNil(RecordingAudioPlacement.place(start: 3, duration: 0.5, written: 4))
    }

    // MARK: Audio buffers

    func testSilenceAndTrimmedBuffersForMicAndSystemFormats() throws {
        for (channels, planar) in [(1, false), (2, true), (2, false)] {
            let format = RecordingTestBuffers.audioFormat(channels: channels, planar: planar)
            let silence = try XCTUnwrap(RecordingAudioBuffers.silence(frames: 4800, format: format, at: CMTime(value: 960, timescale: 48_000)))
            XCTAssertEqual(CMSampleBufferGetNumSamples(silence), 4800)
            XCTAssertEqual(silence.presentationTimeStamp.seconds, 0.02, accuracy: 1e-9)
            let silentChannels = RecordingTestBuffers.channels(of: silence)
            XCTAssertEqual(silentChannels.count, channels)
            XCTAssertTrue(silentChannels.allSatisfy { $0.allSatisfy { $0 == 0 } })

            // A ramp, so the first kept sample tells where the cut landed.
            let ramp = RecordingTestBuffers.audio(at: 1, frames: 1024, channels: channels, planar: planar) { t in Float((t - 1) * 48_000) / 1024 }
            let trimmed = try XCTUnwrap(RecordingAudioBuffers.dropping(frames: 100, from: ramp, at: .zero))
            XCTAssertEqual(CMSampleBufferGetNumSamples(trimmed), 924)
            for channel in RecordingTestBuffers.channels(of: trimmed) {
                XCTAssertEqual(channel.first ?? -1, 100 / 1024, accuracy: 1e-6, "planar=\(planar) channels=\(channels)")
                XCTAssertEqual(channel.last ?? -1, 1023 / 1024, accuracy: 1e-6)
            }
            XCTAssertNil(RecordingAudioBuffers.dropping(frames: 1024, from: ramp, at: .zero), "nothing left")
        }
    }

    func testFrameDropsAreReportedOnceWhenTheyLast() {
        var drops = RecordingFrameDrops()
        var reports = 0
        // A few isolated drops: a hiccup, not worth a warning.
        for frame in 0..<300 {
            if drops.record(dropped: frame % 50 == 0, at: Double(frame) / 60) { reports += 1 }
        }
        XCTAssertEqual(reports, 0)
        // Every third frame dropped for a while: reported, once.
        for frame in 300..<900 {
            if drops.record(dropped: frame % 3 == 0, at: Double(frame) / 60) { reports += 1 }
        }
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(drops.dropped, 6 + 200)
        XCTAssertEqual(drops.appended + drops.dropped, 900)
    }

    // MARK: Writer core, end to end

    /// Sound captured before the first frame used to be stamped t=0 and
    /// played first, pushing everything after it late.
    func testAudioBeforeTheFirstFrameDoesNotDelayTheVoice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preroll-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let handles = try RecordingEngine.makeWriter(url: url, format: RecordingVideoFormat(codec: .h264, width: 64, height: 36), fps: 30, quality: .balanced, microphone: true, systemAudio: true)
        let core = RecordingWriterCore()
        core.begin(handles: handles, frameDuration: CMTime(value: 1, timescale: 30), onFirstFrame: { _ in }, onWriterFailure: {})

        let origin = 1_000.0
        // Loud before the first frame, silent until a tone at t=0.5.
        let sound: (Double) -> Float = { t in
            if t < origin { return Float(sin(t * 2 * .pi * 1_000)) * 0.8 }
            return t - origin >= 0.5 && t - origin < 0.8 ? Float(sin(t * 2 * .pi * 440)) * 0.6 : 0
        }
        var audioTime = origin - 0.6
        while audioTime < origin {
            core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 1024, channels: 1, planar: false, value: sound), to: .microphone)
            core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 1024, channels: 2, planar: true, value: sound), to: .system)
            audioTime += 1024.0 / 48_000
        }
        for frame in 0..<60 {
            let host = origin + Double(frame) / 30
            RecordingTestBuffers.waitUntilReady(handles.videoInput)
            core.appendVideo(RecordingTestBuffers.video(at: host))
            while audioTime < host + 1.0 / 30 {
                RecordingTestBuffers.waitUntilReady(handles.microphoneInput)
                RecordingTestBuffers.waitUntilReady(handles.systemAudioInput)
                core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 1024, channels: 1, planar: false, value: sound), to: .microphone)
                core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 1024, channels: 2, planar: true, value: sound), to: .system)
                audioTime += 1024.0 / 48_000
            }
        }
        let end = core.appendFinalStaticFrame(at: origin + 2)
        XCTAssertEqual(end, 2, accuracy: 1e-6)
        core.padAudio(to: end)
        core.deactivate()
        handles.videoInput.markAsFinished()
        handles.microphoneInput?.markAsFinished()
        handles.systemAudioInput?.markAsFinished()
        await handles.writer.finishWriting()
        XCTAssertEqual(handles.writer.status, .completed, "\(String(describing: handles.writer.error))")

        for track in [0, 1] {
            let samples = try await RecordingTestBuffers.decodeAudio(url, track: track)
            let onsets = RecordingTestBuffers.onsets(in: samples)
            XCTAssertEqual(onsets.count, 1, "track \(track): only the tone, none of the pre-roll (\(onsets))")
            XCTAssertEqual(onsets.first ?? -1, 0.5, accuracy: 0.02, "track \(track): the tone starts where it was heard")
            XCTAssertEqual(Double(samples.count) / 48_000, 2, accuracy: 0.1, "track \(track) spans the recording")
        }
    }

    /// A microphone gone for seconds: its track is kept up with silence as
    /// the video runs, and its sound lands in place when it comes back.
    func testALongMicrophoneGapIsFilledAsTheVideoRuns() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-gap-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let handles = try RecordingEngine.makeWriter(url: url, format: RecordingVideoFormat(codec: .h264, width: 64, height: 36), fps: 30, quality: .balanced, microphone: true, systemAudio: false)
        let core = RecordingWriterCore()
        core.begin(handles: handles, frameDuration: CMTime(value: 1, timescale: 30), onFirstFrame: { _ in }, onWriterFailure: {})

        let origin = 800.0
        let beep: (Double) -> Float = { t in
            let local = t - origin
            return local >= 4.2 && local < 4.25 ? Float(sin(t * 2 * .pi * 660)) * 0.7 : 0
        }
        var audioTime = origin
        var lagDuringGap = 0.0
        for frame in 0..<150 {
            let host = origin + Double(frame) / 30
            RecordingTestBuffers.waitUntilReady(handles.videoInput)
            RecordingTestBuffers.waitUntilReady(handles.microphoneInput)
            core.appendVideo(RecordingTestBuffers.video(at: host))
            let local = host - origin
            if local > 1.5, local < 4 {
                lagDuringGap = max(lagDuringGap, local - core.writtenAudio(for: .microphone))
            }
            while audioTime < host + 1.0 / 30 {
                // Nothing from the microphone between 1 s and 4 s.
                let silentStretch = audioTime - origin >= 1 && audioTime - origin < 4
                if !silentStretch {
                    core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 480, channels: 1, planar: false, value: beep), to: .microphone)
                }
                audioTime += 480.0 / 48_000
            }
        }
        XCTAssertLessThan(lagDuringGap, 1.1, "the track never fell more than about a second behind")
        let end = core.appendFinalStaticFrame(at: origin + 5)
        core.padAudio(to: end)
        core.deactivate()
        handles.videoInput.markAsFinished()
        handles.microphoneInput?.markAsFinished()
        await handles.writer.finishWriting()
        XCTAssertEqual(handles.writer.status, .completed)
        let samples = try await RecordingTestBuffers.decodeAudio(url)
        let onsets = RecordingTestBuffers.onsets(in: samples)
        XCTAssertEqual(onsets.count, 1, "\(onsets)")
        XCTAssertEqual(onsets.first ?? -1, 4.2, accuracy: 0.02)
        XCTAssertEqual(Double(samples.count) / 48_000, 5, accuracy: 0.1)
    }

    /// A microphone dropout and a pause: later audio stays where the picture
    /// is, and the paused stretch is gone from video, audio and activity.
    func testDropoutsAndPausesKeepEverythingAligned() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gaps-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let handles = try RecordingEngine.makeWriter(url: url, format: RecordingVideoFormat(codec: .h264, width: 64, height: 36), fps: 30, quality: .balanced, microphone: true, systemAudio: false)
        let core = RecordingWriterCore()
        core.begin(handles: handles, frameDuration: CMTime(value: 1, timescale: 30), onFirstFrame: { _ in }, onWriterFailure: {})

        let origin = 500.0
        // Short beeps at 2.0 s (after a dropout) and 2.9 s (after a pause).
        let beep: (Double) -> Float = { t in
            let local = t - origin
            let inBeep = (local >= 2.0 && local < 2.05) || (local >= 2.9 && local < 2.95)
            return inBeep ? Float(sin(t * 2 * .pi * 880)) * 0.7 : 0
        }
        var audioTime = origin
        var paused = false
        var resumed = false
        for frame in 0..<90 {
            let host = origin + Double(frame) / 30
            if !paused, host >= origin + 2.3 { core.pause(at: origin + 2.3); paused = true }
            if !resumed, host >= origin + 2.8 { core.resume(at: origin + 2.8); resumed = true }
            RecordingTestBuffers.waitUntilReady(handles.videoInput)
            // The whole frame changes around the beeps; nothing else moves.
            let local = host - origin
            let active = (local >= 1.95 && local < 2.05) || (local >= 2.85 && local < 2.95)
            let dirty = active ? [CGRect(x: 0, y: 0, width: 64, height: 36)] : []
            core.appendVideo(RecordingTestBuffers.video(at: host, shade: active ? 250 : 128), dirtyRects: dirty, pixelsPerPoint: 0.5)
            while audioTime < host + 1.0 / 30 {
                let local = audioTime - origin
                // The microphone delivers nothing from 1.0 to 1.5 s.
                if !(local >= 1.0 && local < 1.5) {
                    RecordingTestBuffers.waitUntilReady(handles.microphoneInput)
                    core.appendAudio(RecordingTestBuffers.audio(at: audioTime, frames: 480, channels: 1, planar: false, value: beep), to: .microphone)
                }
                audioTime += 480.0 / 48_000
            }
        }
        let end = core.appendFinalStaticFrame(at: origin + 3)
        XCTAssertEqual(end, 2.5, accuracy: 1e-6, "3 s minus the half-second pause")
        core.padAudio(to: end)
        let activity = core.screenActivity
        core.deactivate()
        handles.videoInput.markAsFinished()
        handles.microphoneInput?.markAsFinished()
        await handles.writer.finishWriting()
        XCTAssertEqual(handles.writer.status, .completed, "\(String(describing: handles.writer.error))")

        let samples = try await RecordingTestBuffers.decodeAudio(url)
        let onsets = RecordingTestBuffers.onsets(in: samples)
        XCTAssertEqual(onsets.count, 2, "\(onsets)")
        XCTAssertEqual(onsets.first ?? -1, 2.0, accuracy: 0.02, "the dropout didn't pull later audio earlier")
        XCTAssertEqual(onsets.last ?? -1, 2.4, accuracy: 0.02, "after the pause: 2.9 s minus 0.5 s")
        XCTAssertEqual(Double(samples.count) / 48_000, 2.5, accuracy: 0.1)

        let frames = try await RecordingTestBuffers.videoFrameTimes(url)
        XCTAssertEqual(frames.first ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(frames.last ?? -1, 2.5, accuracy: 0.04, "the video ends at the stop moment, minus the pause")
        XCTAssertEqual(frames.count, 75, accuracy: 2)
        let gaps = zip(frames, frames.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual(gaps.max() ?? 1, 1.0 / 30 + 0.002, "the pause leaves no hole in the video")
        XCTAssertGreaterThan(gaps.min() ?? 0, 1.0 / 30 - 0.002, "and no doubled frame at the cut")

        // Screen activity uses the same clock: both bursts, the second retimed.
        XCTAssertFalse(activity.isEmpty)
        XCTAssertTrue(activity.contains { abs($0 - 1.97) < 0.06 }, "\(activity)")
        XCTAssertTrue(activity.contains { abs($0 - 2.37) < 0.06 }, "\(activity)")
        XCTAssertFalse(activity.contains { $0 > 2.5 }, "\(activity)")
        XCTAssertTrue(zip(activity, activity.dropFirst()).allSatisfy { $1 - $0 >= 0.1 - 1e-6 })
    }
}
