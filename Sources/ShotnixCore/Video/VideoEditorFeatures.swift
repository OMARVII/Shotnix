import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoCaptionJob: Equatable {
    var stage: VideoCaptionTranscriber.Stage
    var error: String?

    var title: String {
        if error != nil { return "Couldn't make captions" }
        switch stage {
        case .preparing: return "Getting ready…"
        case .downloading: return "Downloading the language model…"
        case .transcribing: return "Listening…"
        }
    }

    var fraction: Double? {
        switch stage {
        case .preparing: return nil
        case .downloading(let value), .transcribing(let value): return value
        }
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
        let url = project.sourceURL
        let language = captionLanguage.isEmpty ? nil : captionLanguage
        captionJob = VideoCaptionJob(stage: .preparing)
        let report: @Sendable (VideoCaptionTranscriber.Stage) -> Void = { [weak self] stage in
            guard let self else { return }
            Task { @MainActor in
                guard self.captionJob?.error == nil, self.captionTask != nil else { return }
                self.captionJob?.stage = stage
            }
        }
        captionTask = Task { [weak self] in
            do {
                let words = try await VideoCaptionTranscriber.transcribe(url: url, languageIdentifier: language, progress: report)
                guard let self else { return }
                self.captionTask = nil
                guard !Task.isCancelled else {
                    self.captionJob = nil
                    return
                }
                let lines = VideoCaptionBuilder.lines(from: words)
                self.mutate { project in
                    project.captions = lines
                    project.captionStyle.visible = true
                }
                self.captionJob = nil
                self.showNotice("Captions ready — \(lines.count) line\(lines.count == 1 ? "" : "s")", symbol: "captions.bubble.fill")
            } catch {
                guard let self else { return }
                self.captionTask = nil
                if Task.isCancelled || error is CancellationError {
                    self.captionJob = nil
                } else {
                    self.captionJob = VideoCaptionJob(stage: .preparing, error: error.localizedDescription)
                }
            }
        }
    }

    func cancelCaptions() {
        captionTask?.cancel()
        captionTask = nil
        captionJob = nil
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

    /// Keeps word highlighting after an edit: same word count → keep the
    /// timings; otherwise spread the new words across the line.
    static func retimedWords(for text: String, previous: [VideoCaptionWord], start: Double, end: Double) -> [VideoCaptionWord] {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return [] }
        if parts.count == previous.count {
            return zip(parts, previous).map { VideoCaptionWord(text: $0, start: $1.start, end: $1.end) }
        }
        let first = previous.first?.start ?? start
        let last = previous.last?.end ?? end
        let span = max(last - first, 0.1)
        let characters = max(parts.reduce(0) { $0 + $1.count }, 1)
        var cursor = first
        return parts.map { part in
            let length = span * Double(part.count) / Double(characters)
            defer { cursor += length }
            return VideoCaptionWord(text: part, start: cursor, end: cursor + length)
        }
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
    func setCaptionWindow(_ id: UUID, timelineStart: Double, timelineEnd: Double, moveWords: Bool) {
        let start = sourceTime(forTimeline: timelineStart)
        let end = max(sourceTime(forTimeline: timelineEnd), start + 0.2)
        mutate(coalesce: "caption-window-\(id)") { project in
            guard let index = project.captions.firstIndex(where: { $0.id == id }) else { return }
            var line = project.captions[index]
            if moveWords {
                let delta = start - line.start
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
        let start = sourceTime(forTimeline: clock.time)
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
        mutate { $0.captions = [] }
        if case .caption = selection { selection = .none }
        showNotice("Captions cleared", symbol: "trash")
    }

    func selectCaption(_ id: UUID) {
        selection = .caption(id)
        if let line = project.captions.first(where: { $0.id == id }), let time = timelineTime(forSource: line.start + 0.01) {
            seek(to: time)
        }
    }

    func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = project.sourceURL.deletingPathExtension().lastPathComponent + ".srt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = VideoCaptionBuilder.srt(lines: project.captions, segments: segments)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showNotice("Saved \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
        } catch {
            showNotice("Couldn't save the captions file", symbol: "exclamationmark.triangle.fill")
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
