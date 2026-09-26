import AVFoundation
import SwiftUI

/// A soft click on every recorded mouse click.
struct VideoClickSoundSettings: Codable, Equatable {
    var enabled = false
    var volume = 0.6

    init(enabled: Bool = false, volume: Double = 0.6) {
        self.enabled = enabled
        self.volume = volume
    }

    private enum CodingKeys: String, CodingKey { case enabled, volume }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.6
    }
}

/// The click itself: synthesized once (a short, rounded "tock" — a damped
/// body tone, a brighter tick on top, a breath of noise), written as plain
/// PCM so it lands exactly on the click with no encoder delay.
enum VideoClickSound {
    static let sampleRate = 48_000.0
    static let length = 0.045
    static let version = 1

    /// Mono samples, peak about −6 dBFS.
    static func samples() -> [Float] {
        let count = Int(length * sampleRate)
        var generator = SeededNoise(seed: 0x5107)
        var output = [Float](repeating: 0, count: count)
        var peak: Float = 0
        for index in 0..<count {
            let t = Double(index) / sampleRate
            // A quick attack avoids a pop on the very first sample.
            let attack = min(t / 0.0012, 1)
            let body = sin(2 * .pi * 1_650 * t) * exp(-t * 170)
            let tick = sin(2 * .pi * 4_300 * t) * exp(-t * 650)
            let noise = generator.next() * exp(-t * 900) * 0.35
            let value = Float(attack * (0.62 * body + 0.3 * tick + noise))
            output[index] = value
            peak = max(peak, abs(value))
        }
        let scale = peak > 0 ? 0.5 / peak : 1
        return output.map { $0 * scale }
    }

    /// The click as a file (made on first use).
    static func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-click-v\(version).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw VideoDemoExportError.exportFailed("Couldn't make the click sound.")
        }
        let values = samples()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)), let data = buffer.floatChannelData else {
            throw VideoDemoExportError.exportFailed("Couldn't make the click sound.")
        }
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: values.count) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("shotnix-click-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        // Another editor may have written it meanwhile: either copy is fine.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: temporary, to: url)
        }
        try? FileManager.default.removeItem(at: temporary)
        return url
    }

    /// Timeline moments of the clicks still in the video (cut ones are
    /// silent; the ones the crop hides stay silent too).
    static func times(project: VideoDemoProject, segments: [VideoDemoTimelineSegment]) -> [Double] {
        project.clicksInsideCrop
            .compactMap { VideoDemoProject.timelineTimeIfIncluded(sourceTime: $0.time, segments: segments) }
            .sorted()
    }

    private struct SeededNoise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        }
    }
}

/// The click, ready to go into an edit.
struct VideoClickSoundInput {
    let file: VideoAudioFile
    /// Timeline seconds of each click.
    let times: [Double]
    let volume: Double

    struct StructureKey: Equatable {
        let times: [Double]
    }

    var structureKey: StructureKey { StructureKey(times: times) }

    /// One track with a click at every time; clicks closer than the sound
    /// is long cut the earlier one short.
    func insert(into composition: AVMutableComposition, duration: Double) -> AVMutableCompositionTrack? {
        guard !times.isEmpty,
              let clicks = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var inserted = false
        let usable = times.filter { $0 >= 0 && $0 < duration - 0.005 }
        for (index, time) in usable.enumerated() {
            let next = index + 1 < usable.count ? usable[index + 1] : duration
            let length = min(VideoClickSound.length, next - time, duration - time)
            guard length > 0.003 else { continue }
            do {
                try clicks.insertTimeRange(CMTimeRange(start: .zero, duration: VideoCompositionBuilder.time(length)), of: file.track, at: VideoCompositionBuilder.time(time))
                inserted = true
            } catch {
                continue
            }
        }
        guard inserted else {
            composition.removeTrack(clicks)
            return nil
        }
        return clicks
    }
}

/// Click sounds, in the Audio tab.
struct VideoClickSoundSection: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VideoInspectorSection("Click sounds") {
            VideoToggleRow(
                title: "Play a click on each click",
                detail: model.project.clickEvents.isEmpty
                    ? "No clicks were recorded in this video"
                    : "\(model.project.clickEvents.count) recorded click\(model.project.clickEvents.count == 1 ? "" : "s") — in the preview and the export",
                isOn: Binding(get: { model.project.clickSounds.enabled }, set: { value in model.setStyle { $0.clickSounds.enabled = value } })
            )
            .disabled(model.project.clickEvents.isEmpty && !model.project.clickSounds.enabled)
            if model.project.clickSounds.enabled {
                VideoSliderRow(
                    title: "Click volume",
                    value: Binding(get: { model.project.clickSounds.volume }, set: { value in model.setStyle(coalesce: "click-volume") { $0.clickSounds.volume = value } }),
                    range: 0...1,
                    defaultValue: 0.6,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingEnded: { model.endGesture() }
                )
            }
        }
    }
}
