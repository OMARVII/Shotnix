import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoCaptionJob: Equatable {
    var stage: VideoCaptionTranscriber.Stage
    var error: String?
    /// The fix is a switch in System Settings.
    var needsPrivacySettings = false
    var started = Date()

    var title: String {
        if error != nil { return "Couldn't make captions" }
        switch stage {
        case .preparing: return "Getting ready…"
        case .downloading: return "Downloading the language model…"
        case .transcribing: return "Listening…"
        }
    }

    /// nil until there's real progress to show (the bar runs without a
    /// value until then, next to the time spent so far).
    var fraction: Double? {
        switch stage {
        case .preparing: return nil
        case .downloading(let value), .transcribing(let value): return value > 0.005 ? value : nil
        }
    }

    /// "0:42" since it started.
    func elapsed(at now: Date = Date()) -> String {
        let seconds = max(Int(now.timeIntervalSince(started)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Captions

extension VideoEditorModel {
    var selectedCaptionID: UUID? {
        if case .caption(let id) = selection { return id }
        return nil
    }

    func loadCaptionLanguages() {
        guard captionLanguages.isEmpty else { return }
        Task {
            let languages = await VideoCaptionTranscriber.languages()
            captionLanguages = languages
        }
    }

    var captionLanguageTitle: String {
        if captionLanguage.isEmpty { return Self.systemLanguageTitle }
        return Locale.current.localizedString(forIdentifier: captionLanguage) ?? captionLanguage
    }

    /// "English (United States)" — the Mac's own language.
    static var systemLanguageTitle: String {
        let locale = Locale.current
        if let title = locale.localizedString(forIdentifier: locale.identifier(.bcp47)), !title.isEmpty { return title }
        if let code = locale.language.languageCode?.identifier, let title = locale.localizedString(forLanguageCode: code) { return title }
        return "English"
    }

    /// Transcribes the narration on this Mac and lays it out as captions.
    func generateCaptions() {
        guard captionTask == nil else { return }
        guard hasAudio else {
            captionJob = VideoCaptionJob(stage: .preparing, error: VideoCaptionTranscriber.Failure.noAudio.localizedDescription)
            return
        }
        let snapshot = project
        let source = transcriptionSource
        let language = captionLanguage.isEmpty ? nil : captionLanguage
        // Each run has its own token: a cancelled run that finishes late
        // never touches the one that replaced it.
        let token = UUID()
        captionToken = token
        captionJob = VideoCaptionJob(stage: .preparing)
        let report: @Sendable (VideoCaptionTranscriber.Stage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard let self, self.captionToken == token, self.captionJob?.error == nil else { return }
                self.captionJob?.stage = stage
            }
        }
        // Quitting asks, then lets the transcript finish (it lands in the
        // draft); Cancel stops it.
        AppTermination.end(captionQuitToken)
        captionQuitToken = AppTermination.begin("Transcribing “\(project.sourceURL.deletingPathExtension().lastPathComponent)”", asksBeforeQuit: true) { [weak self] done in
            if self?.captionTask == nil { done() }
        }
        captionTask = Task { [weak self] in
            do {
                // The voice of every recording in the video, in order
                // (VideoProjectSources.swift).
                let result = try await VideoSourcesTranscription.transcribe(project: snapshot, primary: source, languageIdentifier: language, progress: report)
                guard let self, self.captionToken == token else { return }
                self.captionTask = nil
                self.captionToken = nil
                self.endCaptionQuitToken()
                guard !Task.isCancelled else {
                    self.captionJob = nil
                    return
                }
                let lines = VideoCaptionBuilder.lines(from: result.words)
                let firstTranscript = !self.project.captions.contains { !$0.words.isEmpty }
                self.mutate(label: "Transcribe") { project in
                    project.captions = lines
                    project.transcriptLanguage = result.language
                    // A first transcript shows up as captions; a new one
                    // keeps whatever you chose.
                    if firstTranscript { project.captionStyle.visible = true }
                }
                self.captionJob = nil
                self.validateSelection()
                self.showNotice("Captions ready — \(lines.count) line\(lines.count == 1 ? "" : "s")", symbol: "captions.bubble.fill")
            } catch {
                guard let self, self.captionToken == token else { return }
                self.captionTask = nil
                self.captionToken = nil
                self.endCaptionQuitToken()
                if Task.isCancelled || error is CancellationError {
                    self.captionJob = nil
                } else {
                    let failure = error as? VideoCaptionTranscriber.Failure
                    self.captionJob = VideoCaptionJob(stage: .preparing, error: error.localizedDescription, needsPrivacySettings: failure?.needsPrivacySettings ?? false)
                }
            }
        }
    }

    /// The microphone alone (cleaned up when that's ready), not the Mac's
    /// sound mixed in.
    var transcriptionSource: VideoCaptionTranscriber.Source {
        let voiceStart = voiceTrackIndex.flatMap { index in
            playback.source.flatMap { $0.audioRanges.indices.contains(index) ? $0.audioRanges[index].start.seconds : nil }
        } ?? 0
        return VideoCaptionTranscriber.source(
            recording: project.sourceURL,
            kinds: audioKinds,
            enhancedVoice: enhancedVoiceReady ? enhancedVoiceURL : nil,
            voiceStart: voiceStart.isFinite ? voiceStart : 0
        )
    }

    /// Real transcribed words (typed caption lines don't count).
    var hasTranscript: Bool {
        project.captions.contains { !$0.words.isEmpty }
    }

    /// A narrated recording nobody has transcribed yet: the editor offers
    /// captions and edit-by-text (until it's waved away for this video).
    var suggestsTranscript: Bool {
        isReady && hasAudio && voiceTrackIndex != nil && project.captions.isEmpty && captionJob == nil
            && !Settings.videoTranscribeHintDismissed.contains(project.sourcePath)
    }

    func dismissTranscriptSuggestion() {
        Settings.videoTranscribeHintDismissed.append(project.sourcePath)
        objectWillChange.send()
    }

    /// A new transcript replaces every line — ask first when there are any.
    func transcribeAgain() {
        guard captionTask == nil else { return }
        guard !project.captions.isEmpty else {
            generateCaptions()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Transcribe again?"
        alert.informativeText = "This replaces all \(project.captions.count) caption line\(project.captions.count == 1 ? "" : "s"), including any you edited or typed, with a new transcript in \(captionLanguageTitle)."
        alert.addButton(withTitle: "Transcribe Again")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        captionJob = nil
        generateCaptions()
    }

    func cancelCaptions() {
        captionTask?.cancel()
        captionTask = nil
        captionToken = nil
        captionJob = nil
        endCaptionQuitToken()
    }

    private func endCaptionQuitToken() {
        AppTermination.end(captionQuitToken)
        captionQuitToken = nil
    }

    func updateCaption(_ id: UUID, text: String) {
        mutate(coalesce: "caption-text-\(id)") { project in
            guard let index = project.captions.firstIndex(where: { $0.id == id }),
                  project.captions[index].text != text else { return }
            let line = project.captions[index]
            project.captions[index].text = text
            project.captions[index].words = Self.retimedWords(for: text, previous: line.words, start: line.start, end: line.end)
        }
    }

    /// Keeps word timings through an edit: words that survived it (matched
    /// ignoring case and punctuation) keep their real times, a word typed
    /// over another takes that word's time, and only the rest is estimated
    /// — inside the time of the words it replaced, so cutting by text later
    /// still lands on the voice.
    nonisolated static func retimedWords(for text: String, previous: [VideoCaptionWord], start: Double, end: Double) -> [VideoCaptionWord] {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // A typed line has no voice under it: it stays without word timings
        // (it never becomes transcript you could cut the video with).
        guard !parts.isEmpty, !previous.isEmpty else { return [] }
        func key(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        }
        let anchors = commonSubsequence(previous.map { key($0.text) }, parts.map(key))
        var result: [VideoCaptionWord] = []
        var lastOld = -1
        var lastNew = -1
        for (oldIndex, newIndex) in anchors + [(previous.count, parts.count)] {
            let replaced = Array(previous[(lastOld + 1)..<oldIndex])
            let typed = Array(parts[(lastNew + 1)..<newIndex])
            if !typed.isEmpty {
                if replaced.count == typed.count {
                    result += zip(typed, replaced).map { VideoCaptionWord(text: $0, start: $1.start, end: $1.end) }
                } else {
                    // The replaced words' time, or the silence between the
                    // neighbours for a word that was only added.
                    let lower = replaced.first?.start ?? (lastOld >= 0 ? previous[lastOld].end : previous[0].start)
                    let upper = replaced.last?.end ?? (oldIndex < previous.count ? previous[oldIndex].start : previous[previous.count - 1].end)
                    result += spread(typed, from: lower, to: max(upper, lower))
                }
            }
            if newIndex < parts.count {
                result.append(VideoCaptionWord(text: parts[newIndex], start: previous[oldIndex].start, end: previous[oldIndex].end))
            }
            lastOld = oldIndex
            lastNew = newIndex
        }
        return result
    }

    /// Words across a span, each as long as its share of the characters.
    private nonisolated static func spread(_ words: [String], from lower: Double, to upper: Double) -> [VideoCaptionWord] {
        let characters = max(words.reduce(0) { $0 + $1.count }, 1)
        var cursor = lower
        return words.map { word in
            let length = (upper - lower) * Double(word.count) / Double(characters)
            defer { cursor += length }
            return VideoCaptionWord(text: word, start: cursor, end: cursor + length)
        }
    }

    /// Index pairs of the longest common subsequence (in order).
    nonisolated static func commonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    func setCaptionTiming(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        mutate(coalesce: "caption-time-\(id)") { project in
            guard let index = project.captions.firstIndex(where: { $0.id == id }) else { return }
            var line = project.captions[index]
            if let start { line.start = min(max(start, 0), line.end - 0.2) }
            if let end { line.end = max(min(end, sourceDuration), line.start + 0.2) }
            project.captions[index] = line
        }
    }

    /// Retimes a line from timeline times (a drag on the captions lane).
    func setCaptionWindow(_ id: UUID, timelineStart: Double, timelineEnd: Double, moveWords: Bool, coalesce: String? = nil) {
        let window = sourceWindow(timelineStart: timelineStart, timelineEnd: timelineEnd)
        let start = window.lowerBound
        let end = max(window.upperBound, start + 0.2)
        // Where the line starts on screen now, in the recording: if its first
        // words were cut, that's after the cut, not the line's own start.
        let shownStart = plan.captions.first { $0.id == id }.map { placementSourceTime(forTimeline: $0.start) }
        mutate(coalesce: coalesce ?? "caption-window-\(id)") { project in
            guard let index = project.captions.firstIndex(where: { $0.id == id }) else { return }
            var line = project.captions[index]
            if moveWords {
                let delta = start - (shownStart ?? line.start)
                line.words = line.words.map { VideoCaptionWord(text: $0.text, start: $0.start + delta, end: $0.end + delta) }
            }
            line.start = start
            line.end = end
            project.captions[index] = line
            project.captions.sort { $0.start < $1.start }
        }
    }

    func deleteCaption(_ id: UUID) {
        mutate { $0.captions.removeAll { $0.id == id } }
        if selection == .caption(id) { selection = .none }
        showNotice("Caption removed", symbol: "trash")
    }

    /// Adds an empty line at the playhead, ready to type.
    func addCaptionAtPlayhead() {
        let start = placementSourceTime(forTimeline: clock.time)
        let nextStart = project.captions.map(\.start).filter { $0 > start + 0.05 }.min() ?? sourceDuration
        let line = VideoCaptionLine(start: start, end: max(min(start + 2.5, nextStart), start + 0.5), text: "New caption")
        mutate { project in
            project.captions.append(line)
            project.captions.sort { $0.start < $1.start }
            project.captionStyle.visible = true
        }
        selection = .caption(line.id)
    }

    func clearCaptions() {
        mutate(label: "Remove Captions") {
            $0.captions = []
            $0.transcriptLanguage = nil
        }
        if case .caption = selection { selection = .none }
        showNotice("Transcript and captions removed — ⌘Z to undo", symbol: "trash")
    }

    func selectCaption(_ id: UUID) {
        selection = .caption(id)
        if let line = project.captions.first(where: { $0.id == id }), let time = timelineTime(forSource: line.start + 0.01) {
            seek(to: time)
        }
    }

    /// File ▸ Save Subtitles and the command palette (VideoCaptionStyles.swift).
    func exportSRT() {
        exportSubtitles(.srt)
    }
}

// MARK: - Edit by text

extension VideoEditorModel {
    func isIncluded(sourceTime: Double) -> Bool {
        segment(containingSource: sourceTime) != nil
    }

    func isIncluded(_ word: VideoTranscriptWord) -> Bool {
        isIncluded(sourceTime: (word.start + word.end) / 2)
    }

    /// Source spans for runs of consecutive word indices.
    private func ranges(forWords indices: IndexSet) -> [ClosedRange<Double>] {
        let words = transcriptWords
        var ranges: [ClosedRange<Double>] = []
        var run: [Int] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            let next = last + 1 < words.count ? words[last + 1] : nil
            if let range = VideoTranscript.cutRange(for: words[first...last], next: next) { ranges.append(range) }
            run = []
        }
        for index in indices where words.indices.contains(index) {
            if let last = run.last, index != last + 1 { flush() }
            run.append(index)
        }
        flush()
        return ranges
    }

    /// Cuts words out of the video (select them in the transcript, ⌫).
    func cutWords(_ indices: IndexSet) {
        let words = transcriptWords
        let kept = IndexSet(indices.filter { words.indices.contains($0) && isIncluded(words[$0]) })
        let ranges = ranges(forWords: kept)
        guard !ranges.isEmpty else { return }
        var ok = true
        mutate(label: kept.count == 1 ? "Cut Word" : "Cut Words") { ok = $0.removeSourceRanges(ranges, totalDuration: sourceDuration) }
        guard ok else {
            showNotice("A video needs at least one clip", symbol: "exclamationmark.triangle")
            return
        }
        showNotice("Cut \(kept.count) word\(kept.count == 1 ? "" : "s") — ⌘Z to undo", symbol: "scissors")
    }

    /// Puts cut words back.
    func restoreWords(_ indices: IndexSet) {
        let ranges = ranges(forWords: indices)
        guard !ranges.isEmpty else { return }
        mutate(label: indices.count == 1 ? "Restore Word" : "Restore Words") { project in
            for range in ranges { project.restoreSourceRange(range, totalDuration: sourceDuration) }
        }
        showNotice("Restored \(indices.count) word\(indices.count == 1 ? "" : "s")", symbol: "arrow.uturn.backward")
    }

    /// Shortens one silence to a short breath.
    /// ⌫ on a pause shortens it; ⌫ on a shortened one puts it back.
    func shortenPause(before index: Int) {
        let words = transcriptWords
        guard index > 0, words.indices.contains(index) else { return }
        let start = words[index - 1].end + 0.2
        let end = words[index].start - 0.2
        guard end - start > 0.05 else { return }
        if !isIncluded(sourceTime: (start + end) / 2) {
            mutate(label: "Restore Pause") { $0.restoreSourceRange(start...end, totalDuration: sourceDuration) }
            showNotice("Pause restored", symbol: "arrow.uturn.backward")
            return
        }
        mutate(label: "Shorten Pause") { $0.removeSourceRanges([start...end], totalDuration: sourceDuration) }
        showNotice("Pause shortened", symbol: "scissors")
    }

    var fillerRanges: [ClosedRange<Double>] {
        VideoTranscript.fillerRanges(words: transcriptWords) { isIncluded(sourceTime: $0) }
    }

    var fillerCount: Int {
        transcriptWords.filter { $0.isFiller && isIncluded($0) }.count
    }

    var pauseRanges: [ClosedRange<Double>] {
        VideoTranscript.pauseRanges(words: transcriptWords, busy: activityTimes) { isIncluded(sourceTime: $0) }
    }

    func removeFillers() {
        let ranges = fillerRanges
        guard !ranges.isEmpty else {
            showNotice("No ums or uhs left", symbol: "checkmark.circle")
            return
        }
        let count = fillerCount
        let before = timelineDuration
        mutate(label: "Remove Ums") { $0.removeSourceRanges(ranges, totalDuration: sourceDuration) }
        showNotice("Removed \(count) filler word\(count == 1 ? "" : "s") — \(Self.format(max(before - timelineDuration, 0))) shorter", symbol: "wand.and.stars")
    }

    func shortenPauses() {
        let ranges = pauseRanges
        guard !ranges.isEmpty else {
            showNotice("No long pauses to shorten", symbol: "checkmark.circle")
            return
        }
        let before = timelineDuration
        mutate(label: "Shorten Pauses") { $0.removeSourceRanges(ranges, totalDuration: sourceDuration) }
        showNotice("Shortened \(ranges.count) pause\(ranges.count == 1 ? "" : "s") — \(Self.format(max(before - timelineDuration, 0))) shorter", symbol: "wand.and.stars")
    }

    /// ⌘F from anywhere: the Captions tab, on its transcript, find bar open.
    func findInTranscript() {
        guard hasTranscript else {
            showNotice("Transcribe the narration to search its words", symbol: "magnifyingglass")
            return
        }
        inspectorTab = .captions
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
        wantsTranscriptFind = true
    }

    /// Plays from a word (or the next moment still in the video).
    func seek(toWord word: VideoTranscriptWord) {
        if let time = timelineTime(forSource: word.start + 0.01) {
            seek(to: time)
        } else if let next = segments.first(where: { $0.clip.sourceStart >= word.start }) {
            seek(to: next.timelineStart)
        }
    }
}

// MARK: - Sound

extension VideoEditorModel {
    var voiceTrackIndex: Int? { VideoAudioKind.voiceTrackIndex(in: audioKinds) }
    var hasSeparateVoiceAndSystem: Bool { audioKinds.contains(.microphone) && audioKinds.contains(.system) }
    /// Any recording in the video has a voice to clean up.
    var canEnhanceVoice: Bool { (voiceTrackIndex != nil || project.appendedSourceHasVoice) && VideoVoiceEnhancer.isAvailable }

    /// M: the preview goes quiet; the video's own sound (and the export)
    /// is untouched.
    func togglePreviewMute() {
        previewMuted.toggle()
        showNotice(
            previewMuted ? "Preview muted — the export keeps its sound" : "Preview sound on",
            symbol: previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        )
    }

    /// Why an export would come out silent though the recording has sound
    /// (nil when it won't).
    var exportSoundWarning: String? {
        guard hasAudio else { return nil }
        if project.audio.muted { return "Mute video is on (Audio tab) — this export will have no sound." }
        let kinds = audioKinds + project.sources.filter { !$0.isPrimary }.flatMap(\.audioKinds)
        if project.audio.isSilent(kinds: kinds) { return "Every sound level is at 0 (Audio tab) — this export will have no sound." }
        if !segments.isEmpty, segments.allSatisfy(\.clip.muted) { return "Every clip is muted — this export will have no sound." }
        return nil
    }

    private var enhancedVoiceURL: URL? {
        voiceTrackIndex.map { VideoVoiceEnhancer.cacheURL(for: project.sourceURL, trackIndex: $0) }
    }

    /// This recording's cleaned-up voice is ready (added recordings each
    /// have their own — see `voiceTargets`).
    var enhancedVoiceReady: Bool {
        enhancedVoiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The toggle (or an undo) changed: process if needed, then swap sources.
    func enhanceVoiceChanged() {
        if project.audio.enhanceVoice { startVoiceEnhancementIfNeeded() }
        Task { await refreshAudioSources() }
    }

    /// Runs voice enhancement once per recording (the result is cached).
    @discardableResult
    func startVoiceEnhancementIfNeeded() -> Task<Bool, Never>? {
        if let voiceTask { return voiceTask }
        // Every recording's voice (added recordings too), one after another.
        let pending = project.voiceTargets(primaryKinds: audioKinds).filter { !$0.isReady }
        guard project.audio.enhanceVoice, !pending.isEmpty else { return nil }
        voiceJob = 0
        voiceError = nil
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in
                if self.voiceTask != nil { self.voiceJob = value }
            }
        }
        // The cleaned-up voice is a cache (it runs again next time), so a
        // quit stops it — unless an export is waiting for it. Registered
        // first, and ended with the work itself, editor or not.
        AppTermination.end(voiceQuitToken)
        let token = AppTermination.begin("Cleaning up the voice in “\(project.sourceURL.deletingPathExtension().lastPathComponent)”", asksBeforeQuit: true) { [weak self] done in
            guard let self, self.voiceTask != nil else { return done() }
            if !self.isExporting { self.voiceTask?.cancel() }
        }
        voiceQuitToken = token
        let task = Task { [weak self] () -> Bool in
            defer { AppTermination.end(token) }
            do {
                try await VideoVoiceEnhancer.enhance(pending, progress: report)
                guard let self else { return false }
                self.voiceTask = nil
                self.voiceJob = nil
                self.endVoiceQuitToken()
                await self.refreshAudioSources()
                if self.project.audio.enhanceVoice {
                    self.showNotice("Voice enhanced — background noise removed", symbol: "waveform")
                }
                return true
            } catch {
                guard let self else { return false }
                self.voiceTask = nil
                self.voiceJob = nil
                self.endVoiceQuitToken()
                if !(error is CancellationError) {
                    self.voiceError = error.localizedDescription
                }
                return false
            }
        }
        voiceTask = task
        return task
    }

    func endVoiceQuitToken() {
        AppTermination.end(voiceQuitToken)
        voiceQuitToken = nil
    }

    /// Rebuilds the sound sources (e.g. the enhanced voice became ready).
    func refreshAudioSources() async {
        guard let source = playback.source else { return }
        let sources = await VideoAudioSource.resolved(from: source, kinds: audioKinds, enhanceVoice: project.audio.enhanceVoice)
        playback.setAudioSources(sources)
        await reloadSourceAudio()
        if let moved = playback.apply(segments: segments, audio: project.audio, keepSourceTime: sourceTime(forTimeline: clock.time), extras: editExtras), !isPlaying {
            clock.time = moved
        }
    }
}

// MARK: - Camera

extension VideoEditorModel {
    /// The camera footage recorded with this video, if it's still on disk.
    var webcamRecording: VideoWebcamRecording? {
        guard let webcam = recording?.webcam, FileManager.default.fileExists(atPath: webcam.path) else { return nil }
        return webcam
    }

    /// Camera footage this video was recorded with that's gone from disk
    /// (moved or deleted) — not the same as a recording without a camera.
    var missingWebcamFile: URL? {
        guard let webcam = recording?.webcam, !FileManager.default.fileExists(atPath: webcam.path) else { return nil }
        return webcam.url
    }
}

// MARK: - Recent exports

extension VideoEditorModel {
    /// This recording's exports that are still on disk, newest first.
    var recentExports: [VideoDemoRecentExport] {
        VideoDemoRecentExportStore.load(for: project.sourceURL).filter { FileManager.default.fileExists(atPath: $0.exportPath) }
    }
}

// MARK: - Camera layouts

extension VideoEditorModel {
    var selectedCameraLayoutID: UUID? {
        if case .cameraLayout(let id) = selection { return id }
        return nil
    }

    /// Timeline stretches of the camera layouts (for the lane).
    var cameraLayoutSpans: [(region: VideoCameraLayoutRegion, start: Double, end: Double)] {
        project.cameraLayouts.compactMap { region in
            let ranges = VideoDemoProject.timelineRanges(sourceStart: region.start, sourceEnd: region.end, segments: segments)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return (region, first.lowerBound, last.upperBound)
        }
    }

    /// Adds a layout at the playhead, fitted into the free space there.
    func addCameraLayout(_ layout: VideoCameraLayoutRegion.Layout, duration: Double = 3) {
        guard hasWebcamFootage else { return }
        var start = placementSourceTime(forTimeline: clock.time)
        let others = project.cameraLayouts.sorted { $0.start < $1.start }
        // Step past every layout the playhead sits in — they can run end
        // to end, so one step may land inside the next.
        while let inside = others.first(where: { start >= $0.start - 0.001 && start < $0.end - 0.001 }) {
            start = inside.end
        }
        let next = others.first(where: { $0.start >= start - 0.001 })?.start ?? sourceDuration
        let end = min(start + duration, next)
        guard end - start >= VideoCameraLayoutRegion.minimumDuration else {
            showNotice("No room here — move the playhead", symbol: "exclamationmark.triangle")
            return
        }
        let region = VideoCameraLayoutRegion(start: start, end: end, layout: layout)
        mutate { project in
            project.cameraLayouts.append(region)
            project.cameraLayouts.sort { $0.start < $1.start }
            project.webcam.visible = true
        }
        selection = .cameraLayout(region.id)
    }

    /// Full-screen camera for the first and last seconds.
    func addCameraIntroOutro(length preferred: Double = 3) {
        guard hasWebcamFootage else { return }
        // Short takes get a shorter intro and outro, with some screen between.
        guard let first = segments.first, let last = segments.last, let span = sourceSpanOnTimeline else { return }
        let length = min(preferred, (timelineDuration - 1) / 2, (span.upperBound - span.lowerBound - 1) / 2)
        guard length >= VideoCameraLayoutRegion.minimumDuration else {
            showNotice("Too short for an intro and outro", symbol: "exclamationmark.triangle")
            return
        }
        // Each stays in the clip that opens (or closes) the video — clips
        // may be in any order.
        let intro = sourceWindow(timelineStart: first.timelineStart, timelineEnd: first.timelineStart + length)
        let outroStart = max(last.clip.sourceEnd - length * last.clip.normalizedSpeed, last.clip.sourceStart)
        let outro = outroStart...last.clip.sourceEnd
        mutate(label: "Intro and Outro") { project in
            project.cameraLayouts.removeAll { $0.end > intro.lowerBound && $0.start < intro.upperBound || $0.end > outro.lowerBound && $0.start < outro.upperBound }
            project.cameraLayouts.append(VideoCameraLayoutRegion(start: intro.lowerBound, end: intro.upperBound, layout: .fullscreen))
            project.cameraLayouts.append(VideoCameraLayoutRegion(start: outro.lowerBound, end: outro.upperBound, layout: .fullscreen))
            project.cameraLayouts.sort { $0.start < $1.start }
            project.webcam.visible = true
        }
        showNotice("Full-screen camera for your intro and outro", symbol: "person.crop.rectangle")
    }

    /// Moves/resizes a layout from timeline times; it slides against its
    /// neighbours instead of overlapping them.
    func setCameraLayoutWindow(_ id: UUID, timelineStart: Double, timelineEnd: Double, moving: Bool, coalesce: String? = nil) {
        guard let current = project.cameraLayouts.first(where: { $0.id == id }) else { return }
        let window = sourceWindow(timelineStart: timelineStart, timelineEnd: timelineEnd)
        var start = window.lowerBound
        var end = window.upperBound
        let others = project.cameraLayouts.filter { $0.id != id }
        let previousEnd = others.filter { $0.end <= current.start + 0.001 }.map(\.end).max() ?? 0
        let nextStart = others.filter { $0.start >= current.end - 0.001 }.map(\.start).min() ?? sourceDuration
        let length = end - start
        if moving {
            if start < previousEnd { start = previousEnd; end = start + length }
            if end > nextStart { end = nextStart; start = max(end - length, previousEnd) }
        } else {
            start = max(start, previousEnd)
            end = min(end, nextStart)
        }
        guard end - start >= VideoCameraLayoutRegion.minimumDuration * 0.5 else { return }
        mutate(coalesce: coalesce ?? "camera-layout-\(id)") { project in
            guard let index = project.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            project.cameraLayouts[index].start = start
            project.cameraLayouts[index].end = end
            project.cameraLayouts.sort { $0.start < $1.start }
        }
    }

    func setCameraLayout(_ id: UUID, to layout: VideoCameraLayoutRegion.Layout) {
        mutate { project in
            guard let index = project.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            project.cameraLayouts[index].layout = layout
        }
    }

    func deleteCameraLayout(_ id: UUID) {
        mutate { $0.cameraLayouts.removeAll { $0.id == id } }
        if selection == .cameraLayout(id) { selection = .none }
        showNotice("Camera layout removed", symbol: "trash")
    }

    func selectCameraLayout(_ id: UUID) {
        selection = .cameraLayout(id)
        if let span = cameraLayoutSpans.first(where: { $0.region.id == id }) {
            seek(to: min(span.start + min(1, (span.end - span.start) / 2), span.end))
        }
    }
}

// MARK: - Annotation style

extension VideoEditorModel {
    /// Recolors an annotation; new ones of that kind start with this color.
    func setOverlayColor(_ id: UUID, _ color: VideoRGBA?, coalesce: String? = nil) {
        guard let overlay = project.overlayEffects.first(where: { $0.id == id }) else { return }
        updateOverlay(id, coalesce: coalesce ?? "color-\(id)") { $0.color = color }
        VideoOverlayStyleMemory.setColor(color, for: overlay.kind)
    }

    func setOverlayThickness(_ id: UUID, _ thickness: VideoOverlayThickness) {
        guard let overlay = project.overlayEffects.first(where: { $0.id == id }) else { return }
        updateOverlay(id) { $0.thickness = thickness }
        VideoOverlayStyleMemory.setThickness(thickness, for: overlay.kind)
    }

    /// A spotlight's shape; new spotlights start with the last one picked.
    func setOverlayShape(_ id: UUID, _ shape: VideoOverlayShape) {
        updateOverlay(id) { $0.shape = shape }
        VideoOverlayStyleMemory.shape = shape
    }

    /// Turns an arrow around (tail and head swap places).
    func flipArrow(_ id: UUID) {
        updateOverlay(id) { effect in
            let points = effect.arrowPoints
            effect.setArrow(tail: points.head, head: points.tail)
        }
    }
}

// MARK: - Aspect & reframe

extension VideoEditorModel {
    /// Switching a wide recording to a narrow shape fills the frame and
    /// follows the pointer (letterboxing a screen into a phone frame makes
    /// it unreadable); the aspect menu turns that off.
    func setAspect(_ preset: VideoDemoProject.AspectPreset) {
        let wasNarrow = project.canReframe
        // Following the cursor needs its recorded path.
        let canFollow = !project.cursorSamples.isEmpty
        setStyle { project in
            project.apply(aspectPreset: preset)
            if project.canReframe, !wasNarrow, canFollow { project.reframe = true }
        }
        if project.reframeActive, !wasNarrow {
            showNotice("Filling the frame — the view follows your cursor", symbol: "arrow.left.and.right.square")
        }
    }
}

// MARK: - Keyboard shortcuts

extension VideoEditorModel {
    func deleteKeystroke(_ id: UUID) {
        mutate { $0.keystrokes.removeAll { $0.id == id } }
        if selection == .keystroke(id) { selection = .none }
        showNotice("Shortcut hidden", symbol: "keyboard")
    }

    func selectKeystroke(_ id: UUID) {
        selection = .keystroke(id)
        if let event = project.keystrokes.first(where: { $0.id == id }), let time = timelineTime(forSource: event.time) {
            seek(to: time + 0.2)
        }
    }
}
