import AppKit
import SwiftUI

struct VideoExportSheet: View {
    @ObservedObject var model: VideoEditorModel

    /// Which part of the timeline to export.
    enum RangeMode: Hashable {
        case whole
        case selection
        case custom
    }

    /// Opens on this range choice instead of the usual one (snapshots).
    var initialRange: RangeMode?

    @State private var rangeMode: RangeMode = .whole
    @State private var customStart = 0.0
    @State private var customEnd = 0.0

    private var settings: VideoExportSettings { model.exportSettings }
    private var canvas: CGSize { model.exportCanvas }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                Group {
                    switch model.exportPhase {
                    case .running(let progress, let started, let destination, let clipboard),
                         .exporting(let progress, let started, let destination, let clipboard):
                        runningView(progress: progress, started: started, destination: destination, clipboard: clipboard).padding(20)
                    case .finished(let url, let bytes, let copied):
                        finishedView(url: url, bytes: bytes, copied: copied).padding(20)
                    case .failed(let message):
                        failedView(message).padding(20)
                    case .idle:
                        // Scrolls in short windows instead of spilling out.
                        ViewThatFits(in: .vertical) {
                            optionsView.padding(20)
                            ScrollView { optionsView.padding(20) }
                        }
                    }
                }
            }
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.105)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
            .overlay(alignment: .top) { VideoOverlayNotice(model: model) }
            // Room above for the message that sits over the sheet.
            .padding(.top, 52)
            .padding(.bottom, 20)
        }
        .onAppear(perform: prepareRange)
    }

    /// Closing never stops an export: it carries on in the background.
    private func close() {
        model.closeExportSheet()
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark").frame(width: 26, height: 26)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help(showsExport ? L("Hide — the export keeps going (Esc)") : L("Close (Esc)"))
            .accessibilityLabel(L("Close"))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    /// A background export is on show (hiding the sheet leaves it going).
    private var showsExport: Bool {
        if case .exporting = model.exportPhase { return true }
        return false
    }

    private var title: String {
        switch model.exportPhase {
        case .idle: return L("Export")
        case .running(_, _, _, let clipboard), .exporting(_, _, _, let clipboard): return clipboard ? L("Preparing to copy…") : L("Exporting…")
        case .finished(_, _, let copied): return copied ? L("Copied to clipboard") : L("Export complete")
        case .failed: return L("Export failed")
        }
    }

    // MARK: Range

    private var selectedRange: VideoDemoTimelineRange? {
        if case .range(let range) = model.selection, range.duration >= 0.1 { return range.normalized }
        return nil
    }

    private func prepareRange() {
        customStart = 0
        customEnd = model.timelineDuration
        if let selected = selectedRange {
            rangeMode = .selection
            customStart = selected.start
            customEnd = selected.end
        } else {
            rangeMode = .whole
        }
        if let initialRange { rangeMode = initialRange }
    }

    /// The part to export (nil: all of it).
    private var exportRange: ClosedRange<Double>? {
        switch rangeMode {
        case .whole: return nil
        case .selection: return selectedRange.map { $0.start...$0.end }
        case .custom:
            let start = min(max(customStart, 0), model.timelineDuration)
            let end = min(max(customEnd, start), model.timelineDuration)
            return end - start >= 0.1 ? start...end : nil
        }
    }

    private var rangeIsOnlyCard: Bool {
        exportRange.map { model.project.isOnlyCard($0, totalDuration: model.sourceDuration) } ?? false
    }

    private var exportDuration: Double {
        exportRange.map { $0.upperBound - $0.lowerBound } ?? model.timelineDuration
    }

    // MARK: Options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VideoSegmented(options: VideoExportSettings.Format.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.format)

            if settings.format == .mp4 {
                row(L("Resolution")) {
                    VideoSegmented(options: VideoExportSettings.Resolution.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.resolution)
                }
                row(L("Frame rate")) {
                    // "fps" is the same in every language.
                    VideoSegmented(options: VideoExportSettings.frameRates.map { ($0, "\($0) fps") }, selection: $model.exportSettings.fps)
                }
                row(L("Quality")) {
                    VStack(alignment: .leading, spacing: 5) {
                        VideoSegmented(options: VideoExportSettings.Quality.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.quality)
                        note(settings.quality.detail)
                    }
                }
                row(L("Encoding")) {
                    VStack(alignment: .leading, spacing: 5) {
                        VideoSegmented(options: VideoExportSettings.Codec.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.codec)
                        note(settings.codec.detail)
                    }
                }
            } else {
                row(L("Size")) {
                    VideoSegmented(options: VideoExportSettings.GIFSize.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.gifSize)
                }
                row(L("Frame rate")) {
                    VideoSegmented(options: VideoExportSettings.gifFrameRates.map { ($0, "\($0) fps") }, selection: $model.exportSettings.gifFPS)
                }
            }

            row(L("Range")) {
                VStack(alignment: .leading, spacing: 6) {
                    VideoSegmented(options: [(RangeMode.whole, L("Whole video")), (.selection, L("Selection")), (.custom, L("In & out"))], selection: $rangeMode)
                        .disabled(model.timelineDuration < 0.2)
                    switch rangeMode {
                    case .whole:
                        EmptyView()
                    case .selection:
                        if let selected = selectedRange {
                            let start = VideoEditorModel.timecode(selected.start)
                            let end = VideoEditorModel.timecode(selected.end)
                            note(L("\(start) → \(end) — the part you ⇧-dragged on the timeline"))
                        } else {
                            note(L("⇧-drag on the timeline to select a part first."))
                        }
                    case .custom:
                        mark(.in, time: $customStart)
                        mark(.out, time: $customEnd)
                    }
                    if rangeIsOnlyCard {
                        note(L("That part is only a title card — include a moment of the video to export it."))
                    }
                }
            }

            if !model.project.captions.isEmpty {
                row(L("Captions")) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Captions hidden in the editor are never burned in.
                        let shown = model.project.captionStyle.visible
                        Toggle(L("Burn captions into the video"), isOn: Binding(
                            get: { shown && model.exportSettings.burnCaptions },
                            set: { model.exportSettings.burnCaptions = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .disabled(!shown)
                        if !shown {
                            note(L("Captions are hidden in the editor (Captions tab → Show captions)."))
                        }
                        HStack(spacing: 8) {
                            Text(L("Subtitles file"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(VideoEditorTheme.textSecondary)
                            VideoSegmented(options: [(VideoSubtitleFormat?.none, L("None")), (.srt, ".srt"), (.vtt, ".vtt")], selection: $model.exportSettings.subtitles)
                                .frame(width: 180)
                        }
                        note(captionsNote(burned: shown && model.exportSettings.burnCaptions))
                    }
                }
            }

            if settings.format == .mp4 {
                VideoToggleRow(title: L("End card"), detail: L("A 2-second “Made with Shotnix” outro on your background — your own outro card is in Style"), isOn: $model.exportSettings.endCard)
            } else {
                note(L("GIFs embed anywhere — READMEs, pull requests, docs. Keep them short: they get big fast."))
            }

            summary

            HStack(spacing: 10) {
                Button {
                    export(toClipboard: true)
                } label: {
                    Label(L("Copy"), systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help(L("Export and put the file on the clipboard — paste it into Slack, Mail, or Finder"))
                .disabled(!canExport)
                Button {
                    export(toClipboard: false)
                } label: {
                    Label(L("Export…"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
            }
        }
    }

    private func export(toClipboard: Bool) {
        model.beginExport(toClipboard: toClipboard, range: exportRange.map { .timeline($0) } ?? .whole)
    }

    /// A GIF over the memory cap can't be made; a missing selection has
    /// nothing to export.
    private var canExport: Bool {
        if rangeMode != .whole, exportRange == nil { return false }
        if rangeIsOnlyCard { return false }
        if settings.format == .gif, gifWorkingBytes > VideoExportSettings.gifMemoryLimit { return false }
        return model.isReady
    }

    private var gifWorkingBytes: Int64 {
        settings.gifWorkingBytes(duration: exportDuration, canvas: canvas)
    }

    /// The two ends of an "In & out" range.
    enum Mark {
        case `in`, out

        var title: String { self == .in ? L("In") : L("Out") }
        var earlier: String { self == .in ? L("In earlier") : L("Out earlier") }
        var later: String { self == .in ? L("In later") : L("Out later") }

        func toPlayhead(_ timecode: String) -> String {
            self == .in ? L("Set the in point to the playhead (\(timecode))") : L("Set the out point to the playhead (\(timecode))")
        }

        static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

        /// Wide enough for both titles, so the rows line up (26 points
        /// fit "In" and "Out").
        static var titleWidth: CGFloat {
            let widest = [Mark.in, .out].map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return max(26, ceil(widest))
        }
    }

    private func mark(_ mark: Mark, time: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(mark.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .frame(width: Mark.titleWidth, alignment: .leading)
            Button { time.wrappedValue = max(time.wrappedValue - 0.1, 0) } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .accessibilityLabel(mark.earlier)
            Text(VideoEditorModel.timecode(time.wrappedValue))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(VideoEditorTheme.textPrimary)
                .frame(minWidth: 56)
            Button { time.wrappedValue = min(time.wrappedValue + 0.1, model.timelineDuration) } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .accessibilityLabel(mark.later)
            Button(L("At playhead")) { time.wrappedValue = model.clock.time }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help(mark.toPlayhead(VideoEditorModel.timecode(model.clock.time)))
        }
    }

    /// What happens to the captions, in one sentence.
    private func captionsNote(burned: Bool) -> String {
        let file = settings.subtitles != nil
        if burned {
            return file ? L("Captions are drawn into the picture, and a subtitles file is saved next to the video.") : L("Captions are drawn into the picture.")
        }
        return file ? L("A clean picture plus a subtitles file to upload.") : L("No captions in the picture — add a subtitles file to upload them separately.")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(VideoEditorTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String, color: Color = Color.yellow.opacity(0.85)) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .frame(width: 78, alignment: .leading)
                .padding(.top, 5)
            content()
        }
    }

    private var summary: some View {
        let size = settings.outputSize(canvas: canvas)
        let duration = exportDuration
        let endCard = settings.format == .mp4 && settings.endCard
        let bytes = settings.estimatedBytes(duration: duration, canvas: canvas, hasAudio: model.hasAudio || model.project.music != nil || model.project.clickSounds.enabled)
        var parts = ["\(Int(size.width))×\(Int(size.height))", "\(settings.effectiveFrameRate) fps"]
        if settings.format == .mp4 { parts.append(settings.codec.title) }
        parts.append(VideoEditorModel.timecode(duration + (endCard ? VideoDemoExporter.endCardDuration : 0)))
        let sourceShort = min(model.project.sourceWidth, model.project.sourceHeight)
        let stageShort = min(model.project.stageRect(in: canvas).width, model.project.stageRect(in: canvas).height)
        let outputScale = min(size.width, size.height) / max(min(canvas.width, canvas.height), 1)
        let upscaled = settings.format == .mp4 && sourceShort > 0 && Double(stageShort * outputScale) > sourceShort * 1.15
        let free = VideoExportFiles.availableBytes(at: URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true).appendingPathComponent("export.mp4"))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                Text(verbatim: "≈ \(VideoEditorModel.formatBytes(bytes))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            // What's in it, so nothing surprises.
            note(contents(endCard: endCard))
            if upscaled {
                warning(L("Larger than the recording — text may look softer than at a lower resolution."))
            }
            // An export that would come out silent says so (and can turn
            // the sound back on).
            VideoExportSoundWarning(model: model)
            if let free, free < bytes + 200_000_000 {
                let space = VideoEditorModel.formatBytes(free)
                warning(L("Only \(space) free on your disk — this may not fit. Free up space or save to another drive."))
            }
            if settings.format == .gif {
                gifWarnings
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.28)))
    }

    private func contents(endCard: Bool) -> String {
        var pieces: [String] = []
        if model.project.cards.intro.enabled { pieces.append(L("intro card")) }
        if model.project.cards.outro.enabled { pieces.append(L("outro card")) }
        if model.project.music != nil { pieces.append(L("music")) }
        if !model.project.captions.isEmpty { pieces.append(settings.burnCaptions && model.project.captionStyle.visible ? L("captions burned in") : L("no captions in the picture")) }
        if settings.format == .mp4 { pieces.append(endCard ? L("“Made with Shotnix” end card (2s)") : L("no end card")) }
        if let range = exportRange {
            let start = VideoEditorModel.timecode(range.lowerBound)
            let end = VideoEditorModel.timecode(range.upperBound)
            pieces.insert(L("\(start)–\(end) only"), at: 0)
        }
        // A list of what's in it, joined two at a time (Chinese uses "、").
        let list = pieces.isEmpty ? L("the video") : pieces.dropFirst().reduce(pieces[0]) { L("\($0), \($1)") }
        return L("Includes: \(list)")
    }

    @ViewBuilder
    private var gifWarnings: some View {
        let working = gifWorkingBytes
        let estimate = settings.estimatedBytes(duration: exportDuration, canvas: canvas, hasAudio: false)
        let memory = VideoEditorModel.formatBytes(working)
        if working > VideoExportSettings.gifMemoryLimit {
            // A GIF keeps every frame in memory until it's written.
            warning(L("Too long for a GIF at this size — it would need about \(memory) of memory. Make it lighter, export a part, or choose MP4."), color: Color(red: 1, green: 0.55, blue: 0.5))
            lighterButton
        } else if working > 1_500_000_000 || estimate > 40_000_000 {
            let size = VideoEditorModel.formatBytes(estimate)
            warning(L("A big GIF — about \(size) and \(memory) of memory to make. A smaller size, fewer fps, or MP4 is lighter."))
            lighterButton
        }
    }

    @ViewBuilder
    private var lighterButton: some View {
        if let lighter = settings.lighterGIF(duration: exportDuration, canvas: canvas), lighter.gifSize != settings.gifSize || lighter.gifFPS != settings.gifFPS {
            Button {
                model.exportSettings.gifSize = lighter.gifSize
                model.exportSettings.gifFPS = lighter.gifFPS
            } label: {
                Label(L("Make it lighter: \(lighter.gifSize.title), \(String(lighter.gifFPS)) fps"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }
    }

    // MARK: Progress

    private func runningView(progress: Double, started: Date, destination: URL, clipboard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(clipboard ? L("Rendering, then copying to your clipboard") : destination.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .lineLimit(1)
            if let status = model.latestExportStatus {
                // Cleaning up the voice, balancing loudness, rendering…
                Label(status, systemImage: "waveform")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            } else if let voice = model.voiceJob, progress < 0.001 {
                Label(L("Cleaning up your voice first… \(Int((voice * 100).rounded()))%"), systemImage: "waveform")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
            HStack {
                Text(VideoEditorModel.formatPercent(progress))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(eta(progress: progress, started: started))
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.cancelExport()
                } label: {
                    Text(L("Cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                Button {
                    close()
                } label: {
                    Text(L("Keep Editing"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                .help(L("The export carries on in the background (Esc)"))
            }
        }
    }

    private func eta(progress: Double, started: Date) -> String {
        let elapsed = Date().timeIntervalSince(started)
        guard progress > 0.03, elapsed > 0.5 else { return L("Estimating…") }
        let remaining = elapsed / progress * (1 - progress)
        if remaining < 1 { return L("Almost done") }
        if remaining < 60 { return L("About \(Int(remaining.rounded(.up)))s left") }
        return L("About \(Int((remaining / 60).rounded(.up))) min left")
    }

    private func finishedView(url: URL, bytes: Int64, copied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(copied ? L("\(VideoEditorModel.formatBytes(bytes)) · on your clipboard — paste it anywhere") : VideoEditorModel.formatBytes(bytes))
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
            // One row as designed; two when a language's words don't fit
            // side by side (Поделиться · Показать · Скопировать · Воспроизвести).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    finishedActionsLeading(url: url, copied: copied)
                    finishedActionsTrailing(url: url, copied: copied)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { finishedActionsLeading(url: url, copied: copied) }
                    HStack(spacing: 8) { finishedActionsTrailing(url: url, copied: copied) }
                }
            }
            Button {
                close()
            } label: {
                Text(L("Done")).frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Share and Reveal (not for a clipboard export).
    @ViewBuilder
    private func finishedActionsLeading(url: URL, copied: Bool) -> some View {
        if !copied {
            VideoShareButton(url: url)
            Button { model.revealExport(url) } label: {
                Label(L("Reveal"), systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            .help(L("Reveal in Finder"))
        }
    }

    /// Copy (not for a clipboard export) and Play.
    @ViewBuilder
    private func finishedActionsTrailing(url: URL, copied: Bool) -> some View {
        if !copied {
            Button { model.copyExport(url) } label: {
                Label(L("Copy"), systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }
        Button { model.openExport(url) } label: {
            Label(L("Play"), systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(VideoSecondaryButtonStyle())
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { model.exportPhase = .idle } label: {
                    Text(L("Back")).frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                Button { close() } label: {
                    Text(L("Close")).frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
            }
        }
    }
}
