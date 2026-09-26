import Foundation
import SwiftUI
import Translation

// MARK: - Model

/// The captions in another language: a text for each caption line (same
/// timing as the line it translates).
struct VideoCaptionTranslation: Codable, Equatable, Identifiable {
    struct Line: Codable, Equatable {
        /// The caption line it translates.
        var id: UUID
        var text: String
        /// The line's text when it was translated (edited since: stale).
        var sourceText: String
    }

    /// BCP-47.
    var language: String
    var lines: [Line]

    var id: String { language }
}

/// Every caption track and the one that's shown (and exported).
struct VideoCaptionTracks: Codable, Equatable {
    var translations: [VideoCaptionTranslation] = []
    /// Language of the shown track (nil: the captions as transcribed).
    var active: String?

    init() {}

    /// Line texts of the shown translation (nil: the original captions).
    var activeTranslation: [UUID: String]? {
        guard let active, let track = translations.first(where: { $0.language == active }) else { return nil }
        return Dictionary(track.lines.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    private enum CodingKeys: String, CodingKey { case translations, active }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translations = (try? c.decode([VideoCaptionTranslation].self, forKey: .translations)) ?? []
        active = try? c.decodeIfPresent(String.self, forKey: .active)
    }
}

extension VideoCaptionTranslation {
    /// Lines changed (or added) since this was made.
    func staleCount(for captions: [VideoCaptionLine]) -> Int {
        let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return captions.filter { line in
            guard let translated = byID[line.id] else { return true }
            return translated.sourceText != line.text
        }.count
    }

    static func displayName(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }
}

// MARK: - Translating

/// On-device translation of caption lines with Apple's Translation
/// framework (macOS 15 and later). Nothing is uploaded: macOS downloads a
/// language once, then translates on this Mac.
enum VideoCaptionTranslator {
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Lines worth translating (typed or transcribed, not empty).
    static func translatableLines(_ captions: [VideoCaptionLine]) -> [VideoCaptionLine] {
        captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @available(macOS 15.0, *)
    static func translate(_ captions: [VideoCaptionLine], into language: String, session: TranslationSession) async throws -> VideoCaptionTranslation {
        let lines = translatableLines(captions)
        let requests = lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        let responses = try await session.translations(from: requests)
        let byID = Dictionary(lines.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var translated: [VideoCaptionTranslation.Line] = []
        for response in responses {
            guard let identifier = response.clientIdentifier, let line = byID[identifier] else { continue }
            translated.append(VideoCaptionTranslation.Line(id: line.id, text: response.targetText, sourceText: line.text))
        }
        return VideoCaptionTranslation(language: language, lines: translated)
    }

    /// Target languages this Mac can translate into (sorted by name).
    @available(macOS 15.0, *)
    static func targetLanguages(excluding source: String?) async -> [String] {
        let languages = await LanguageAvailability().supportedLanguages
        let sourceCode = source.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        var seen = Set<String>()
        var identifiers: [String] = []
        for language in languages {
            let identifier = language.minimalIdentifier
            guard language.languageCode?.identifier != sourceCode, seen.insert(identifier).inserted else { continue }
            identifiers.append(identifier)
        }
        return identifiers.sorted { VideoCaptionTranslation.displayName($0).localizedCaseInsensitiveCompare(VideoCaptionTranslation.displayName($1)) == .orderedAscending }
    }

    enum Readiness: Equatable {
        case installed
        /// macOS downloads the language first (it asks).
        case needsDownload
        case unsupported
    }

    @available(macOS 15.0, *)
    static func readiness(from source: String, to target: String) async -> Readiness {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

// MARK: - Editor

extension VideoEditorModel {
    /// The language the captions are in (for translating from).
    var captionSourceLanguage: String {
        project.transcriptLanguage ?? (captionLanguage.isEmpty ? Locale.current.identifier(.bcp47) : captionLanguage)
    }

    func storeTranslation(_ translation: VideoCaptionTranslation) {
        mutate { project in
            project.captionTracks.translations.removeAll { $0.language == translation.language }
            project.captionTracks.translations.append(translation)
            project.captionTracks.active = translation.language
        }
        showNotice("Captions translated to \(VideoCaptionTranslation.displayName(translation.language))", symbol: "globe")
    }

    func showCaptionTrack(_ language: String?) {
        mutate { $0.captionTracks.active = language }
    }

    func removeTranslation(_ language: String) {
        mutate { project in
            project.captionTracks.translations.removeAll { $0.language == language }
            if project.captionTracks.active == language { project.captionTracks.active = nil }
        }
    }
}

/// Translate the captions and pick which language shows. Only on macOS 15
/// and later; everything runs on this Mac.
struct VideoCaptionTranslationSection: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        if #available(macOS 15.0, *) {
            VideoCaptionTranslationControls(model: model)
        }
    }
}

@available(macOS 15.0, *)
private struct VideoCaptionTranslationControls: View {
    @ObservedObject var model: VideoEditorModel
    @State private var targets: [String] = []
    @State private var target = Settings.videoCaptionTranslationTarget
    @State private var readiness: VideoCaptionTranslator.Readiness?
    @State private var configuration: TranslationSession.Configuration?
    @State private var running = false
    @State private var error: String?

    private var tracks: VideoCaptionTracks { model.project.captionTracks }

    var body: some View {
        VideoInspectorSection("Languages") {
            if !tracks.translations.isEmpty {
                HStack(spacing: 10) {
                    Text("Show")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .frame(width: 58, alignment: .leading)
                    Menu {
                        Button(VideoCaptionTranslation.displayName(model.captionSourceLanguage) + " (original)") { model.showCaptionTrack(nil) }
                        Divider()
                        ForEach(tracks.translations) { translation in
                            Button(VideoCaptionTranslation.displayName(translation.language)) { model.showCaptionTrack(translation.language) }
                        }
                    } label: {
                        Text(tracks.active.map(VideoCaptionTranslation.displayName) ?? VideoCaptionTranslation.displayName(model.captionSourceLanguage) + " (original)")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer(minLength: 0)
                    if let active = tracks.active {
                        Button {
                            model.removeTranslation(active)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .help("Remove this translation")
                        .accessibilityLabel("Remove translation")
                    }
                }
                if let active = tracks.active, let translation = tracks.translations.first(where: { $0.language == active }) {
                    let stale = translation.staleCount(for: model.project.captions)
                    if stale > 0 {
                        Label("\(stale) line\(stale == 1 ? "" : "s") changed since translating", systemImage: "exclamationmark.circle")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.orange.opacity(0.9))
                    }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(targets, id: \.self) { language in
                        Button(VideoCaptionTranslation.displayName(language)) { target = language }
                    }
                } label: {
                    Text(target.isEmpty ? "Choose a language" : VideoCaptionTranslation.displayName(target))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(targets.isEmpty || running)
                Spacer(minLength: 4)
                Button {
                    translate()
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Translate", systemImage: "globe")
                    }
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .disabled(target.isEmpty || running || readiness == .unsupported || model.project.captions.isEmpty)
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(error == nil ? VideoEditorTheme.textTertiary : Color.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await loadTargets() }
        .onChange(of: target) { _ in
            Settings.videoCaptionTranslationTarget = target
            Task { await refreshReadiness() }
        }
        .translationTask(configuration) { session in
            await run(session)
        }
    }

    private var detail: String {
        if let error { return error }
        switch readiness {
        case .unsupported?: return "This Mac can't translate between these languages."
        case .needsDownload?: return "macOS downloads \(VideoCaptionTranslation.displayName(target)) once, then translates right here — nothing is uploaded."
        default: return "A second caption track you can show, burn in, or save as subtitles. Translated on this Mac — nothing is uploaded."
        }
    }

    private func loadTargets() async {
        targets = await VideoCaptionTranslator.targetLanguages(excluding: model.captionSourceLanguage)
        if !targets.contains(target) {
            target = targets.first { $0.hasPrefix("es") } ?? targets.first ?? ""
        }
        await refreshReadiness()
    }

    private func refreshReadiness() async {
        guard !target.isEmpty else { return }
        readiness = await VideoCaptionTranslator.readiness(from: model.captionSourceLanguage, to: target)
    }

    private func translate() {
        error = nil
        running = true
        let source = Locale.Language(identifier: model.captionSourceLanguage)
        let destination = Locale.Language(identifier: target)
        if configuration?.source == source, configuration?.target == destination {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: destination)
        }
    }

    private func run(_ session: TranslationSession) async {
        defer { running = false }
        do {
            let translation = try await VideoCaptionTranslator.translate(model.project.captions, into: target, session: session)
            guard !translation.lines.isEmpty else {
                error = "Nothing to translate."
                return
            }
            model.storeTranslation(translation)
            await refreshReadiness()
        } catch is CancellationError {
            // Left the tab: nothing changes.
        } catch {
            self.error = "Couldn't translate: \(error.localizedDescription)"
        }
    }
}
