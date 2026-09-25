import AVFoundation
import Foundation
import Speech

// MARK: - Line building

/// Groups timed words into short, readable caption lines.
enum VideoCaptionBuilder {
    struct Rules {
        var maxWords = 7
        var maxCharacters = 42
        var maxDuration = 4.0
        /// A silence this long always starts a new line.
        var pauseBreak = 0.6
        /// Lines linger this long after the last word (unless the next
        /// line starts sooner).
        var tail = 0.35
    }

    /// Lines appear this much before their first word.
    static let lead = 0.05

    static func lines(from words: [VideoCaptionWord], rules: Rules = Rules()) -> [VideoCaptionLine] {
        var groups: [[VideoCaptionWord]] = []
        var current: [VideoCaptionWord] = []
        for word in words where !word.text.isEmpty {
            if let last = current.last, let first = current.first {
                let characters = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let endsSentence = last.text.last.map { ".?!".contains($0) } ?? false
                let breakHere = word.start - last.end > rules.pauseBreak
                    || current.count >= rules.maxWords
                    || characters > rules.maxCharacters
                    || word.end - first.start > rules.maxDuration
                    || (endsSentence && current.count >= 3)
                if breakHere {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        // No stragglers: when a sentence's last word or two would flash up
        // alone, the two lines share the sentence evenly instead.
        for index in groups.indices.dropFirst() {
            let previous = groups[index - 1]
            let current = groups[index]
            guard current.count <= 2, previous.count >= 4,
                  let tail = previous.last, let head = current.first,
                  !(tail.text.last.map { ".?!".contains($0) } ?? false),
                  head.start - tail.end <= rules.pauseBreak else { continue }
            let joined = previous + current
            let split = joined.count / 2
            groups[index - 1] = Array(joined[..<split])
            groups[index] = Array(joined[split...])
        }

        var lines: [VideoCaptionLine] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let nextStart = index + 1 < groups.count ? max((groups[index + 1].first?.start ?? .infinity) - Self.lead, 0) : .infinity
            let end = min(last.end + rules.tail, nextStart)
            lines.append(VideoCaptionLine(
                start: max(first.start - Self.lead, 0),
                end: max(end, first.start + 0.3),
                text: group.map(\.text).joined(separator: " "),
                words: group
            ))
        }
        return lines
    }

    /// SubRip text for the edited timeline (cuts removed, speed applied).
    static func srt(lines: [VideoCaptionLine], segments: [VideoDemoTimelineSegment]) -> String {
        var output = ""
        var index = 1
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let ranges = VideoDemoProject.timelineRanges(sourceStart: line.start, sourceEnd: max(line.end, line.start + 0.1), segments: segments)
            guard let first = ranges.first, let last = ranges.last else { continue }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output += "\(index)\n\(timestamp(first.lowerBound)) --> \(timestamp(last.upperBound))\n\(text)\n\n"
            index += 1
        }
        return output
    }

    static func timestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// Splits recognizer output into words: glues stray punctuation to the
    /// previous word and spreads multi-word pieces across their time span.
    static func words(fromPieces pieces: [(text: String, start: Double, end: Double)]) -> [VideoCaptionWord] {
        var words: [VideoCaptionWord] = []
        for piece in pieces {
            let parts = piece.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }
            let totalCharacters = max(parts.reduce(0) { $0 + $1.count }, 1)
            var cursor = piece.start
            let span = max(piece.end - piece.start, 0)
            for part in parts {
                let length = span * Double(part.count) / Double(totalCharacters)
                let isPunctuation = part.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                if isPunctuation, !words.isEmpty {
                    words[words.count - 1].text += part
                    words[words.count - 1].end = max(words[words.count - 1].end, cursor + length)
                } else {
                    words.append(VideoCaptionWord(text: part, start: cursor, end: cursor + length))
                }
                cursor += length
            }
        }
        return words
    }
}

// MARK: - Transcription

/// On-device speech-to-text for a recording's sound. Nothing leaves the Mac.
enum VideoCaptionTranscriber {
    enum Stage: Equatable {
        case preparing
        case downloading(Double)
        case transcribing(Double)
    }

    enum Failure: LocalizedError {
        case noAudio
        case unsupportedLanguage(String)
        case notAllowed
        case unavailable
        case nothingHeard

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This recording has no sound to transcribe."
            case .unsupportedLanguage(let name): return "\(name) isn't supported for captions on this Mac."
            case .notAllowed: return "Speech recognition is turned off for Shotnix in System Settings → Privacy & Security."
            case .unavailable: return "Speech recognition isn't available on this Mac right now."
            case .nothingHeard: return "No speech was found in this recording."
            }
        }
    }

    struct Language: Identifiable, Hashable {
        let identifier: String
        var id: String { identifier }
        var title: String {
            Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        }
    }

    /// Languages this Mac can transcribe, the user's own first.
    static func languages() async -> [Language] {
        var identifiers: [String] = []
        if #available(macOS 26.0, *) {
            identifiers = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        }
        if identifiers.isEmpty {
            identifiers = SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) }
        }
        let preferred = Locale.current.identifier(.bcp47)
        let unique = Array(Set(identifiers))
        return unique
            .map(Language.init(identifier:))
            .sorted { a, b in
                if a.identifier == preferred { return true }
                if b.identifier == preferred { return false }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    /// Words with times in SOURCE seconds.
    static func transcribe(
        url: URL,
        languageIdentifier: String?,
        progress: @escaping @Sendable (Stage) -> Void
    ) async throws -> [VideoCaptionWord] {
        progress(.preparing)
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw Failure.noAudio }
        let duration = try await asset.load(.duration).seconds
        let locale = Locale(identifier: languageIdentifier ?? Locale.current.identifier(.bcp47))

        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await transcribeModern(asset: asset, tracks: audioTracks, duration: duration, locale: locale, progress: progress)
        }
        return try await transcribeLegacy(asset: asset, tracks: audioTracks, duration: duration, locale: locale, progress: progress)
    }

    // MARK: macOS 26

    @available(macOS 26.0, *)
    private static func transcribeModern(
        asset: AVAsset,
        tracks: [AVAssetTrack],
        duration: Double,
        locale requested: Locale,
        progress: @escaping @Sendable (Stage) -> Void
    ) async throws -> [VideoCaptionWord] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.unsupportedLanguage(Locale.current.localizedString(forIdentifier: requested.identifier) ?? requested.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]

        // The language model downloads once, then works offline.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            progress(.downloading(0))
            let observation = request.progress.observe(\.fractionCompleted) { item, _ in
                progress(.downloading(item.fractionCompleted))
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw Failure.unavailable
        }
        progress(.transcribing(0))

        let analyzer = SpeechAnalyzer(modules: modules)
        let collector = Task { () -> [(text: String, start: Double, end: Double)] in
            var pieces: [(text: String, start: Double, end: Double)] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard let range = run.audioTimeRange else {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = pieces.last {
                            pieces.append((text, last.end, last.end))
                        }
                        continue
                    }
                    pieces.append((text, range.start.seconds, range.end.seconds))
                }
                let reached = result.range.end.seconds
                if duration > 0, reached.isFinite {
                    progress(.transcribing(min(max(reached / duration, 0), 1)))
                }
            }
            return pieces
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let envelope = VideoAudioEnvelope()
        let pieces = try await withTaskCancellationHandler {
            try await analyzer.start(inputSequence: stream)
            do {
                try await VideoAudioReader.read(asset: asset, tracks: tracks, format: format) { buffer, start in
                    envelope.add(buffer, at: start.seconds)
                    continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
                }
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                throw error
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } onCancel: {
            continuation.finish()
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        let words = envelope.refineOnsets(VideoCaptionBuilder.words(fromPieces: pieces))
        guard !words.isEmpty else { throw Failure.nothingHeard }
        progress(.transcribing(1))
        return words
    }

    // MARK: Earlier macOS

    private static func transcribeLegacy(
        asset: AVAsset,
        tracks: [AVAssetTrack],
        duration: Double,
        locale: Locale,
        progress: @escaping @Sendable (Stage) -> Void
    ) async throws -> [VideoCaptionWord] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw Failure.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        guard recognizer.isAvailable else { throw Failure.unavailable }

        // Mix every sound track into one file the recognizer can read.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-captions-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw Failure.unavailable
        }
        let file = try AVAudioFile(forWriting: temporary, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let envelope = VideoAudioEnvelope()
        try await VideoAudioReader.read(asset: asset, tracks: tracks, format: format) { buffer, start in
            envelope.add(buffer, at: start.seconds)
            try? file.write(from: buffer)
        }

        progress(.transcribing(0))
        let request = SFSpeechURLRecognitionRequest(url: temporary)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let segments: [(text: String, start: Double, end: Double)] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        ($0.substring, $0.timestamp, $0.timestamp + $0.duration)
                    })
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        let words = envelope.refineOnsets(VideoCaptionBuilder.words(fromPieces: segments))
        guard !words.isEmpty else { throw Failure.nothingHeard }
        progress(.transcribing(1))
        return words
    }
}

// MARK: - Loudness

/// A 100 Hz loudness envelope of the sound, used to find where speech
/// really starts: recognizers often stretch the first word after a pause
/// back over the silence before it.
final class VideoAudioEnvelope: @unchecked Sendable {
    static let rate = 100.0
    private(set) var levels: [Float] = []

    func add(_ buffer: AVAudioPCMBuffer, at start: Double) {
        let frames = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frames > 0, sampleRate > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        func sample(_ frame: Int) -> Float {
            if let data = buffer.floatChannelData {
                return interleaved ? data[0][frame * channels] : data[0][frame]
            }
            if let data = buffer.int16ChannelData {
                return Float(interleaved ? data[0][frame * channels] : data[0][frame]) / 32768
            }
            if let data = buffer.int32ChannelData {
                return Float(interleaved ? data[0][frame * channels] : data[0][frame]) / 2_147_483_648
            }
            return 0
        }
        let window = max(Int(sampleRate / Self.rate), 1)
        var frame = 0
        while frame < frames {
            let count = min(window, frames - frame)
            var sum: Float = 0
            for index in frame..<(frame + count) {
                let value = sample(index)
                sum += value * value
            }
            let bucket = Int(((start + Double(frame) / sampleRate) * Self.rate).rounded(.down))
            if bucket >= 0 {
                if levels.count <= bucket { levels.append(contentsOf: repeatElement(0, count: bucket - levels.count + 1)) }
                levels[bucket] = max(levels[bucket], (sum / Float(count)).squareRoot())
            }
            frame += count
        }
    }

    /// Moves each word that follows a pause (or is implausibly long) to
    /// the first loud moment inside it.
    func refineOnsets(_ words: [VideoCaptionWord]) -> [VideoCaptionWord] {
        guard !levels.isEmpty, !words.isEmpty else { return words }
        let sorted = levels.sorted()
        let loud = sorted[min(Int(Double(sorted.count) * 0.9), sorted.count - 1)]
        let threshold = max(loud * 0.15, 0.004)
        var result = words
        for index in result.indices {
            let word = result[index]
            let afterPause = index == 0 || word.start - result[index - 1].end > 0.15
            let plausible = 0.2 + 0.09 * Double(word.text.count)
            guard afterPause || word.end - word.start > plausible else { continue }
            let first = max(Int(word.start * Self.rate), 0)
            let last = min(Int(word.end * Self.rate), levels.count - 1)
            guard first <= last,
                  let onset = (first...last).first(where: { levels[$0] > threshold }) else { continue }
            let time = Double(onset) / Self.rate - 0.03
            if time > word.start + 0.05 {
                result[index].start = min(time, word.end - 0.05)
            }
        }
        return result
    }
}

// MARK: - Audio reading

/// Reads a recording's sound (all tracks mixed) as PCM buffers in a given
/// format, with each buffer's start time in source seconds.
enum VideoAudioReader {
    static func read(
        asset: AVAsset,
        tracks: [AVAssetTrack],
        format: AVAudioFormat,
        handle: (AVAudioPCMBuffer, CMTime) throws -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
        switch format.commonFormat {
        case .pcmFormatFloat32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        case .pcmFormatInt32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = false
        default:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoCaptionTranscriber.Failure.unavailable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoCaptionTranscriber.Failure.unavailable }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            try handle(buffer, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        if reader.status == .failed { throw reader.error ?? VideoCaptionTranscriber.Failure.unavailable }
    }
}
