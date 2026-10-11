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
    /// Part of the filler the word before starts: Japanese arrives one
    /// character at a time, so えーと is three words.
    var continuesFiller = false
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
        // Not 那个 or 就是, "ну" or "типа": real words people also hesitate with.
        case "zh": set.formUnion(["嗯", "呃", "额", "唔", "嗯嗯", "呃呃"])
        case "ru": set.formUnion(["э", "ээ", "эээ", "э-э", "э-э-э", "эм", "эмм", "мм", "ммм", "хм"])
        case "uk": set.formUnion(["е", "ее", "еее", "е-е", "е-е-е", "ем", "емм", "мм", "ммм", "хм"])
        // Not あの, その or まあ: real words people also hesitate with. The
        // drawn-out あのー and そのー are only ever hesitation. えと is
        // えっと as the recognizer often writes it.
        case "ja": set.formUnion(["えー", "えーと", "えーっと", "えっと", "えと", "ええと", "ええっと", "うーん", "んー", "あー", "あのー", "そのー"])
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
        words.sort { $0.start < $1.start }
        markSpelledFillers(&words, fillers: fillers)
        return words
    }

    /// Recognizers write Japanese one character at a time: えーと arrives as
    /// え, ー, と (or えー, と once joined into words). There a filler is a run
    /// of words that spells one and stands on its own, with punctuation or a
    /// pause on both sides, so the え and と of 考えと are never one. The
    /// longest spelling wins: えーと is one filler, not えー and a stray と.
    static func markSpelledFillers(_ words: inout [VideoTranscriptWord], fillers: Set<String>) {
        let longest = fillers.map(\.count).max() ?? 0
        func endsPhrase(_ word: VideoTranscriptWord) -> Bool { word.text.last?.isPunctuation ?? false }
        func paused(_ before: VideoTranscriptWord, _ after: VideoTranscriptWord) -> Bool { after.start - before.end >= 0.1 }
        func apart(_ index: Int) -> Bool { index == 0 || index == words.count || endsPhrase(words[index - 1]) || paused(words[index - 1], words[index]) }
        var start = 0
        while start < words.count {
            var length = 0
            if apart(start) {
                var spelled = ""
                for end in start..<min(words.count, start + longest) {
                    let word = words[end]
                    guard let first = word.text.first, VideoCaptionBuilder.isUnspaced(first), end == start || !apart(end) else { break }
                    spelled += word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                    if end > start, apart(end + 1), fillers.contains(spelled) { length = end - start + 1 }
                }
            }
            for index in start..<start + length {
                words[index].isFiller = true
                words[index].continuesFiller = index > start
            }
            start += max(length, 1)
        }
    }

    /// The source span to remove for a run of consecutive words: the words
    /// plus the silence up to the next word (a short breath is kept), and
    /// never into the next word itself.
    static func cutRange(for run: ArraySlice<VideoTranscriptWord>, next: VideoTranscriptWord?) -> ClosedRange<Double>? {
        guard let first = run.first, let last = run.last else { return nil }
        let start = max(first.start - 0.02, 0)
        var end = last.end + 0.02
        if let next {
            if next.start - last.end < 0.8 { end = max(end, next.start - 0.06) }
            end = min(end, max(next.start, last.end))
        }
        return end - start > 0.05 ? start...end : nil
    }

    /// The span to cut for `words[run]`, moved onto the run's own sound
    /// when the recording's waveform is known: the recognizer's times sit
    /// on a coarse grid and can be off by a whole word, more so over
    /// background noise.
    static func cutRange(words: [VideoTranscriptWord], run: ClosedRange<Int>, sound: VideoWaveform?) -> ClosedRange<Double>? {
        guard words.indices.contains(run.lowerBound), words.indices.contains(run.upperBound) else { return nil }
        let next = run.upperBound + 1 < words.count ? words[run.upperBound + 1] : nil
        guard let timed = cutRange(for: words[run], next: next) else { return nil }
        guard let sound else { return timed }
        if let cut = sound.cut(words: words, run: run) { return cut }
        // Its sound runs into its neighbours': the timed cut, its edges off
        // the sound they'd split, reaching at most a little past the words.
        let kept = sound.keepingWords(timed)
        let start = max(kept.lowerBound, timed.lowerBound - 0.1)
        let end = min(kept.upperBound, timed.upperBound + 0.1)
        return start < end ? start...end : timed
    }

    /// Each filler still in the video, with its words and the span its cut
    /// removes.
    static func fillerCuts(words: [VideoTranscriptWord], sound: VideoWaveform? = nil, isIncluded: (Double) -> Bool) -> [(run: ClosedRange<Int>, range: ClosedRange<Double>)] {
        var cuts: [(run: ClosedRange<Int>, range: ClosedRange<Double>)] = []
        for (index, word) in words.enumerated() where word.isFiller && !word.continuesFiller && isIncluded((word.start + word.end) / 2) {
            var last = index
            while words.indices.contains(last + 1), words[last + 1].continuesFiller { last += 1 }
            if let range = cutRange(words: words, run: index...last, sound: sound) {
                cuts.append((index...last, range))
            }
        }
        return cuts
    }

    /// Filler words that are still in the video.
    static func fillerRanges(words: [VideoTranscriptWord], sound: VideoWaveform? = nil, isIncluded: (Double) -> Bool) -> [ClosedRange<Double>] {
        merge(fillerCuts(words: words, sound: sound, isIncluded: isIncluded).map(\.range))
    }

    /// Silences between words longer than `minimum`, shortened to `keep` —
    /// only where nothing happens on screen (no clicks, no shortcuts, the
    /// pointer at rest), so a pause spent doing the demo is never cut.
    static func pauseRanges(
        words: [VideoTranscriptWord],
        minimum: Double = 1.0,
        keep: Double = 0.4,
        busy: [Double],
        sound: VideoWaveform? = nil,
        isIncluded: (Double) -> Bool
    ) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for (a, b) in zip(words, words.dropFirst()) {
            let gap = b.start - a.end
            guard gap > minimum else { continue }
            var start = a.end + keep / 2
            var end = b.start - keep / 2
            guard end - start > 0.2, isIncluded((start + end) / 2) else { continue }
            // Leave pauses where the screen is busy.
            if let first = firstIndex(in: busy, atLeast: start - 0.2), busy[first] <= end + 0.2 { continue }
            // Only ever the silence: a word timed early or late keeps its sound.
            if let sound {
                let kept = sound.keepingWords(start...end, canGrow: false)
                start = kept.lowerBound
                end = kept.upperBound
                guard end - start > 0.2 else { continue }
            }
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

    /// Moments of on-screen activity (sorted): the pointer moving (more
    /// than `pointerStep` between samples), clicks, shortcuts, and bursts
    /// of screen changes (typing, scrolling — recordings made since the
    /// recorder watched the screen; nil for older ones).
    static func activityTimes(
        cursor: [VideoDemoCursorSample],
        clicks: [VideoDemoClickEvent],
        keystrokes: [VideoKeystrokeEvent],
        screen: [Double]? = nil,
        pointerStep: Double = 0.004
    ) -> [Double] {
        var times: [Double] = []
        var previous: VideoDemoCursorSample?
        for sample in cursor {
            if let previous {
                let dx = sample.x - previous.x
                let dy = sample.y - previous.y
                if dx * dx + dy * dy > pointerStep * pointerStep { times.append(sample.time) }
            }
            previous = sample
        }
        for click in clicks {
            times.append(click.time)
            times.append(click.time + click.pressDuration)
        }
        times.append(contentsOf: keystrokes.map(\.time))
        if let screen { times.append(contentsOf: screenBusyTimes(screen)) }
        return times.sorted()
    }

    /// Screen changes that come in bursts. A lone change — a text cursor
    /// blinking, a clock ticking over — isn't someone working; typing and
    /// scrolling change the screen several times a second.
    static func screenBusyTimes(_ samples: [Double], within gap: Double = 0.35) -> [Double] {
        let sorted = samples.sorted()
        return sorted.indices.filter { index in
            (index > 0 && sorted[index] - sorted[index - 1] <= gap)
                || (index + 1 < sorted.count && sorted[index + 1] - sorted[index] <= gap)
        }.map { sorted[$0] }
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
    /// (and merge when they meet), or it returns as its own clip. Clips keep
    /// their order on the timeline (they may have been moved around).
    mutating func restoreSourceRange(_ range: ClosedRange<Double>, totalDuration: Double) {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, totalDuration)
        guard upper - lower > 0.01 else { return }
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        let epsilon = 0.02
        // Neighbours in the recording bound how far a clip can grow.
        let bySource = clips.indices.sorted { clips[$0].sourceStart < clips[$1].sourceStart }
        for (rank, index) in bySource.enumerated() {
            let previousEnd = rank > 0 ? clips[bySource[rank - 1]].sourceEnd : 0
            let nextStart = rank + 1 < bySource.count ? clips[bySource[rank + 1]].sourceStart : totalDuration
            if abs(clips[index].sourceEnd - lower) <= epsilon || (clips[index].sourceEnd >= lower && clips[index].sourceEnd < upper && clips[index].sourceStart < lower) {
                clips[index].sourceEnd = min(max(clips[index].sourceEnd, upper), nextStart)
            }
            if abs(clips[index].sourceStart - upper) <= epsilon || (clips[index].sourceStart <= upper && clips[index].sourceStart > lower && clips[index].sourceEnd > upper) {
                clips[index].sourceStart = max(min(clips[index].sourceStart, lower), previousEnd)
            }
        }
        // Still uncovered (restored in the middle of a gap): its own clip,
        // right after the clip it follows in the recording.
        let covered = clips.contains { $0.sourceStart <= lower + epsilon && $0.sourceEnd >= upper - epsilon }
        if !covered {
            let before = clips.indices.filter { clips[$0].sourceStart <= lower + epsilon }.max { clips[$0].sourceStart < clips[$1].sourceStart }
            clips.insert(VideoDemoTimelineClip(sourceStart: lower, sourceEnd: upper), at: before.map { $0 + 1 } ?? 0)
        }
        // Merge timeline neighbours that now meet seamlessly in the recording.
        var merged: [VideoDemoTimelineClip] = []
        for clip in clips {
            if var last = merged.last,
               clip.sourceStart >= last.sourceStart,
               clip.sourceStart <= last.sourceEnd + epsilon,
               abs(last.normalizedSpeed - clip.normalizedSpeed) < 0.001,
               last.muted == clip.muted {
                last.sourceEnd = max(last.sourceEnd, clip.sourceEnd)
                last.fadeOut = clip.fadeOut
                merged[merged.count - 1] = last
            } else if let last = merged.last, clip.sourceStart > last.sourceStart, clip.sourceStart < last.sourceEnd {
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

    /// Moves a clip to another place in the video (the recording itself
    /// stays as it is).
    @discardableResult
    mutating func moveClip(id: UUID, toIndex index: Int, totalDuration: Double) -> Bool {
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard let from = clips.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(index, 0), clips.count - 1)
        guard target != from else { return false }
        clips.insert(clips.remove(at: from), at: target)
        timelineClips = clips
        ensureTimeline(totalDuration: totalDuration)
        return true
    }
}

// MARK: - Keeping cuts off words

extension VideoDemoProject {
    /// Moves cut words onto the span their cut took when the recognizer
    /// had them elsewhere, so the transcript (which goes by a word's
    /// middle) shows them cut and they put back the same span.
    mutating func retime(_ words: [VideoTranscriptWord], into range: ClosedRange<Double>) {
        for word in words where !range.contains((word.start + word.end) / 2) {
            guard let line = captions.firstIndex(where: { $0.id == word.lineID }),
                  captions[line].words.indices.contains(word.index) else { continue }
            let start = min(max(word.start, range.lowerBound), range.upperBound - 0.02)
            captions[line].words[word.index].start = start
            captions[line].words[word.index].end = max(min(word.end, range.upperBound), start + 0.01)
        }
    }
}

extension VideoWaveform {
    /// Stretches of sound touching `window`, whole.
    func sounds(touching window: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let rate = Self.bucketsPerSecond
        func sounding(_ index: Int) -> Bool { peaks.indices.contains(index) && peaks[index] > quiet }
        var first = max(Int((window.lowerBound * rate).rounded(.down)), 0)
        var last = min(Int((window.upperBound * rate).rounded(.down)), peaks.count - 1)
        guard first <= last else { return [] }
        while sounding(first), sounding(first - 1) { first -= 1 }
        while sounding(last), sounding(last + 1) { last += 1 }
        var stretches: [ClosedRange<Double>] = []
        var open: Int?
        for index in first...(last + 1) {
            if index <= last, sounding(index) {
                if open == nil { open = index }
            } else if let start = open {
                stretches.append(Double(start) / rate...Double(index) / rate)
                open = nil
            }
        }
        return stretches
    }

    /// The span to cut for `words[run]`, from the sound itself: each
    /// stretch of sound near it belongs to the word whose time overlaps it
    /// most (the run, the word before, the word after, or words further
    /// out), never the run's when it covers most of a neighbour's time,
    /// and a single word takes the stretch nearest its middle. The cut
    /// takes the run's sound and the silence after it up to a breath
    /// before the next word, and never touches sound that stays. Nil when
    /// none of the sound is the run's: it runs into its neighbours.
    func cut(words: [VideoTranscriptWord], run: ClosedRange<Int>) -> ClosedRange<Double>? {
        guard peaks.count > 1, words.indices.contains(run.lowerBound), words.indices.contains(run.upperBound) else { return nil }
        let first = words[run.lowerBound]
        let last = words[run.upperBound]
        let previous = run.lowerBound > 0 ? words[run.lowerBound - 1] : nil
        let next = run.upperBound + 1 < words.count ? words[run.upperBound + 1] : nil
        let own = first.start...max(last.end, first.start)
        let before = previous.map { $0.start...max($0.end, $0.start) }
        let after = next.map { $0.start...max($0.end, $0.start) }
        let window = min(previous?.start ?? first.start - 0.5, first.start)...max(next?.end ?? last.end + 0.5, last.end)
        func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>?) -> Double {
            guard let b else { return 0 }
            return max(min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound), 0)
        }
        func coversMost(_ stretch: ClosedRange<Double>, of word: ClosedRange<Double>?) -> Bool {
            guard let word else { return false }
            return overlap(stretch, word) > 0.5 * (word.upperBound - word.lowerBound)
        }
        enum Owner { case run, previous, next, further }
        var owned: [(stretch: ClosedRange<Double>, owner: Owner)] = []
        for stretch in sounds(touching: window) {
            let ours = overlap(stretch, own)
            let earlier = overlap(stretch, before)
            let later = overlap(stretch, after)
            let further = max(window.lowerBound - stretch.lowerBound, 0) + max(stretch.upperBound - window.upperBound, 0)
            if ours > 0, ours >= max(earlier, later, further), !coversMost(stretch, of: before), !coversMost(stretch, of: after) {
                owned.append((stretch, .run))
            } else if earlier > 0, earlier >= max(later, further) {
                owned.append((stretch, .previous))
            } else if later > 0, later >= further {
                owned.append((stretch, .next))
            } else {
                owned.append((stretch, .further))
            }
        }
        var mine = owned.filter { $0.owner == .run }.map(\.stretch)
        let middle = (first.start + last.end) / 2
        func distance(_ stretch: ClosedRange<Double>) -> Double { max(stretch.lowerBound - middle, middle - stretch.upperBound, 0) }
        if mine.isEmpty {
            // Timed off its own sound: a stretch the word before has after
            // its main one, or the word after has before its main one.
            var spare: [ClosedRange<Double>] = []
            let earlier = owned.filter { $0.owner == .previous }.map(\.stretch)
            if let main = earlier.max(by: { overlap($0, before) < overlap($1, before) }) {
                spare += earlier.filter { $0.lowerBound >= main.upperBound }
            }
            let later = owned.filter { $0.owner == .next }.map(\.stretch)
            if let main = later.max(by: { overlap($0, after) < overlap($1, after) }) {
                spare += later.filter { $0.upperBound <= main.lowerBound }
            }
            if let nearest = spare.filter({ max($0.lowerBound - own.upperBound, own.lowerBound - $0.upperBound, 0) <= 0.3 }).min(by: { distance($0) < distance($1) }) {
                mine = [nearest]
            }
        } else if run.count == 1, mine.count > 1 {
            let nearest = mine.firstIndex(of: mine.min { distance($0) < distance($1) }!)!
            var kept = nearest...nearest
            // A Chinese or Japanese word of several characters has stops
            // inside (えーと): it keeps its sound on toward a side where it
            // stands apart, after punctuation or a pause, as its characters
            // did before they were joined into a word.
            if first.text.count > 1, first.text.first.map(VideoCaptionBuilder.isUnspaced) == true {
                func apart(_ before: VideoTranscriptWord?, _ after: VideoTranscriptWord?) -> Bool {
                    guard let before, let after else { return true }
                    return before.text.last?.isPunctuation == true || after.start - before.end >= 0.08
                }
                if apart(previous, first) { kept = 0...kept.upperBound }
                if apart(last, next) { kept = kept.lowerBound...(mine.count - 1) }
            }
            mine = Array(mine[kept])
        }
        guard let lower = mine.first?.lowerBound, let upper = mine.last?.upperBound else { return nil }
        let others = owned.map(\.stretch).filter { !mine.contains($0) }
        let kept = others.filter { $0.upperBound <= lower }.map(\.upperBound).max() ?? 0
        let following = others.filter { $0.lowerBound >= upper }.map(\.lowerBound).min() ?? .infinity
        let start = max(lower - 0.02, kept, 0)
        // A soft "s" or "f" starting the next word sits under the quiet
        // level, so the breath kept before its loud part is a bit longer.
        var end = upper + 0.02
        if following - upper < 0.8 { end = max(end, following - 0.1) }
        end = min(end, following)
        return start < end ? start...end : nil
    }

    /// The quietest moment within 60 ms of `time`.
    func quietest(near time: Double) -> Double {
        let rate = Self.bucketsPerSecond
        let center = Int((time * rate).rounded(.down))
        let window = (center - 3...center + 3).filter { peaks.indices.contains($0) }
        guard let index = window.min(by: { peaks[$0] < peaks[$1] || (peaks[$0] == peaks[$1] && abs($0 - center) < abs($1 - center)) }) else { return time }
        return (Double(index) + 0.5) / rate
    }

    /// Moves a cut's edges off the sound they'd split: an edge inside a
    /// stretch of sound takes all of it when most of it is in the cut,
    /// and stops short of it otherwise. Where words run together with no
    /// silence, an edge splits at the quietest moment nearby instead.
    /// `canGrow: false` only ever shrinks the cut (a shortened pause never
    /// takes a word's sound).
    func keepingWords(_ range: ClosedRange<Double>, canGrow: Bool = true) -> ClosedRange<Double> {
        guard peaks.count > 1 else { return range }
        let rate = Self.bucketsPerSecond
        func bucket(_ time: Double) -> Int { Int((time * rate).rounded(.down)) }
        func loud(_ index: Int) -> Bool { peaks.indices.contains(index) && peaks[index] > quiet }
        func sound(around time: Double) -> ClosedRange<Double>? {
            guard loud(bucket(time)) else { return nil }
            return sounds(touching: time...time).first
        }
        func hasSound(_ start: Double, _ end: Double) -> Bool {
            let from = bucket(start)
            let to = bucket(end - 0.001)
            return from <= to && (from...to).contains(where: loud)
        }
        var start = range.lowerBound
        var end = range.upperBound
        if let around = sound(around: start), around.upperBound <= end {
            let inside = around.upperBound - start
            start = canGrow && inside > start - around.lowerBound ? around.lowerBound : around.upperBound
        }
        if let around = sound(around: end), around.lowerBound >= start {
            let inside = end - around.lowerBound
            end = canGrow && inside > around.upperBound - end ? around.upperBound : around.lowerBound
        }
        if canGrow, !hasSound(start, end), hasSound(range.lowerBound, range.upperBound) {
            start = sound(around: range.lowerBound) == nil ? start : quietest(near: range.lowerBound)
            end = sound(around: range.upperBound) == nil ? end : quietest(near: range.upperBound)
        }
        if !canGrow {
            start = max(start, range.lowerBound)
            end = min(end, range.upperBound)
        }
        return start < end ? start...end : range
    }
}
