import Foundation

/// One spoken word of the recording, in SOURCE time.
struct VideoTranscriptWord: Equatable {
    let text: String
    let start: Double
    let end: Double
    /// Where it came from (caption line + word index).
    let lineID: UUID
    let index: Int
    /// "um", "uh", "erm"… in the transcript's language.
    var isFiller = false
}

enum VideoTranscript {
    /// Hesitation sounds for a language (BCP-47; nil = English). Only
    /// sounds that are never real words there: "um" is "a" in Portuguese,
    /// "er" is "he"/"is" in German, Dutch, and the Nordic languages.
    static func fillers(for language: String?) -> Set<String> {
        var set: Set<String> = ["uh", "uhh", "uhm", "uhmm", "umm", "ummm", "erm", "ehm", "hmm", "hm", "mm", "mhm", "mmm"]
        let code = language.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        switch code {
        case "en": set.formUnion(["um", "er", "err", "ah", "ahh", "eh"])
        case "de": set.formUnion(["äh", "ähm", "öh", "öhm"])
        case "fr": set.formUnion(["euh", "heu"])
        case "es", "it": set.formUnion(["eh"])
        case "pt": set.formUnion(["hã", "ahn", "hum"])
        case "nl": set.formUnion(["eh", "uh"])
        default: break
        }
        return set
    }

    static func isFiller(_ text: String, fillers: Set<String>) -> Bool {
        fillers.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// Every word of the captions, in time order.
    static func words(from captions: [VideoCaptionLine], language: String? = nil) -> [VideoTranscriptWord] {
        let fillers = fillers(for: language)
        var words: [VideoTranscriptWord] = []
        // Only spoken words: a typed caption line has no timing in the voice,
        // so it's never offered for cutting.
        for line in captions where !line.words.isEmpty {
            for (index, word) in line.words.enumerated() {
                words.append(VideoTranscriptWord(text: word.text, start: word.start, end: word.end, lineID: line.id, index: index, isFiller: isFiller(word.text, fillers: fillers)))
            }
        }
        return words.sorted { $0.start < $1.start }
    }

    /// The source span to remove for a run of consecutive words: the words
    /// plus the silence up to the next word (a short breath is kept).
    static func cutRange(for run: ArraySlice<VideoTranscriptWord>, next: VideoTranscriptWord?) -> ClosedRange<Double>? {
        guard let first = run.first, let last = run.last else { return nil }
        let start = max(first.start - 0.02, 0)
        var end = last.end + 0.02
        if let next, next.start - last.end < 0.8 {
            end = max(end, next.start - 0.06)
        }
        return end - start > 0.05 ? start...end : nil
    }

    /// Filler words that are still in the video.
    static func fillerRanges(words: [VideoTranscriptWord], isIncluded: (Double) -> Bool) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for (index, word) in words.enumerated() where word.isFiller && isIncluded((word.start + word.end) / 2) {
            if let range = cutRange(for: words[index...index], next: index + 1 < words.count ? words[index + 1] : nil) {
                ranges.append(range)
            }
        }
        return merge(ranges)
    }

    /// Silences between words longer than `minimum`, shortened to `keep` —
    /// only where nothing happens on screen (no clicks, no shortcuts, the
    /// pointer at rest), so a pause spent doing the demo is never cut.
    static func pauseRanges(
        words: [VideoTranscriptWord],
        minimum: Double = 1.0,
        keep: Double = 0.4,
        busy: [Double],
        isIncluded: (Double) -> Bool
    ) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for (a, b) in zip(words, words.dropFirst()) {
            let gap = b.start - a.end
            guard gap > minimum else { continue }
            let start = a.end + keep / 2
            let end = b.start - keep / 2
            guard end - start > 0.2, isIncluded((start + end) / 2) else { continue }
            // Leave pauses where the screen is busy.
            if let first = firstIndex(in: busy, atLeast: start - 0.2), busy[first] <= end + 0.2 { continue }
            ranges.append(start...end)
        }
        return merge(ranges)
    }

    /// Binary search: first element ≥ value.
    static func firstIndex(in sorted: [Double], atLeast value: Double) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count ? low : nil
    }

    /// Moments of on-screen activity (sorted).
    static func activityTimes(cursor: [VideoDemoCursorSample], clicks: [VideoDemoClickEvent], keystrokes: [VideoKeystrokeEvent]) -> [Double] {
        var times: [Double] = []
        var previous: VideoDemoCursorSample?
        for sample in cursor {
            if let previous {
                let dx = sample.x - previous.x
                let dy = sample.y - previous.y
                if dx * dx + dy * dy > 0.004 * 0.004 { times.append(sample.time) }
            }
            previous = sample
        }
        for click in clicks {
            times.append(click.time)
            times.append(click.time + click.pressDuration)
        }
        times.append(contentsOf: keystrokes.map(\.time))
        return times.sorted()
    }

    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Cutting and restoring source ranges

extension VideoDemoProject {
    /// Removes spans of the RECORDING from the timeline (splitting clips as
    /// needed). Returns false when nothing would be left.
    @discardableResult
    mutating func removeSourceRanges(_ ranges: [ClosedRange<Double>], totalDuration: Double) -> Bool {
        let cuts = VideoTranscript.merge(ranges)
        guard !cuts.isEmpty else { return true }
        var result: [VideoDemoTimelineClip] = []
        for clip in normalizedTimelineClips(totalDuration: totalDuration) {
            var pieces = [clip]
            for cut in cuts {
                var next: [VideoDemoTimelineClip] = []
                for piece in pieces {
                    guard cut.upperBound > piece.sourceStart, cut.lowerBound < piece.sourceEnd else {
                        next.append(piece)
                        continue
                    }
                    if cut.lowerBound - piece.sourceStart >= Self.minimumClipDuration {
                        var before = piece
                        before.sourceEnd = cut.lowerBound
                        before.fadeOut = 0
                        next.append(before)
                    }
                    if piece.sourceEnd - cut.upperBound >= Self.minimumClipDuration {
                        var after = piece
                        after.id = next.contains(where: { $0.id == piece.id }) ? UUID() : piece.id
                        after.sourceStart = cut.upperBound
                        after.fadeIn = 0
                        next.append(after)
                    }
                }
                pieces = next
            }
            result.append(contentsOf: pieces)
        }
        guard !result.isEmpty else { return false }
        timelineClips = result
        ensureTimeline(totalDuration: totalDuration)
        return true
    }

    /// Puts a span of the recording back: neighbouring clips grow over it
    /// (and merge when they meet), or it returns as its own clip.
    mutating func restoreSourceRange(_ range: ClosedRange<Double>, totalDuration: Double) {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, totalDuration)
        guard upper - lower > 0.01 else { return }
        var clips = normalizedTimelineClips(totalDuration: totalDuration).sorted { $0.sourceStart < $1.sourceStart }
        let epsilon = 0.02
        // Grow clips that touch the restored span.
        for index in clips.indices {
            if abs(clips[index].sourceEnd - lower) <= epsilon || (clips[index].sourceEnd >= lower && clips[index].sourceEnd < upper && clips[index].sourceStart < lower) {
                let nextStart = index + 1 < clips.count ? clips[index + 1].sourceStart : totalDuration
                clips[index].sourceEnd = min(max(clips[index].sourceEnd, upper), nextStart)
            }
            if abs(clips[index].sourceStart - upper) <= epsilon || (clips[index].sourceStart <= upper && clips[index].sourceStart > lower && clips[index].sourceEnd > upper) {
                let previousEnd = index > 0 ? clips[index - 1].sourceEnd : 0
                clips[index].sourceStart = max(min(clips[index].sourceStart, lower), previousEnd)
            }
        }
        // Still uncovered (restored in the middle of a gap): its own clip.
        let covered = clips.contains { $0.sourceStart <= lower + epsilon && $0.sourceEnd >= upper - epsilon }
        if !covered {
            clips.append(VideoDemoTimelineClip(sourceStart: lower, sourceEnd: upper))
            clips.sort { $0.sourceStart < $1.sourceStart }
        }
        // Merge clips that now meet seamlessly.
        var merged: [VideoDemoTimelineClip] = []
        for clip in clips {
            if var last = merged.last,
               clip.sourceStart <= last.sourceEnd + epsilon,
               abs(last.normalizedSpeed - clip.normalizedSpeed) < 0.001,
               last.muted == clip.muted {
                last.sourceEnd = max(last.sourceEnd, clip.sourceEnd)
                last.fadeOut = clip.fadeOut
                merged[merged.count - 1] = last
            } else if let last = merged.last, clip.sourceStart < last.sourceEnd {
                var trimmed = clip
                trimmed.sourceStart = last.sourceEnd
                if trimmed.sourceDuration >= Self.minimumClipDuration { merged.append(trimmed) }
            } else {
                merged.append(clip)
            }
        }
        timelineClips = merged
        ensureTimeline(totalDuration: totalDuration)
    }
}
