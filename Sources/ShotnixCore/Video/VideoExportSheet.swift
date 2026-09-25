import AppKit
import SwiftUI

struct VideoExportSheet: View {
    @ObservedObject var model: VideoEditorModel

    private var settings: VideoExportSettings { model.exportSettings }
    private var canvas: CGSize { model.exportCanvas }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    if !model.isExporting { close() }
                }
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                Group {
                    switch model.exportPhase {
                    case .running(let progress, let started, let destination, let clipboard):
                        runningView(progress: progress, started: started, destination: destination, clipboard: clipboard)
                    case .finished(let url, let bytes, let copied):
                        finishedView(url: url, bytes: bytes, copied: copied)
                    case .failed(let message):
                        failedView(message)
                    case .idle:
                        optionsView
                    }
                }
                .padding(20)
            }
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.105)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
        }
    }

    private func close() {
        model.closeExportSheet()
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Spacer()
            if !model.isExporting {
                Button { close() } label: {
                    Image(systemName: "xmark").frame(width: 26, height: 26)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var title: String {
        switch model.exportPhase {
        case .idle: return "Export"
        case .running(_, _, _, let clipboard): return clipboard ? "Preparing to copy…" : "Exporting…"
        case .finished(_, _, let copied): return copied ? "Copied to clipboard" : "Export complete"
        case .failed: return "Export failed"
        }
    }

    // MARK: Options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VideoSegmented(options: VideoExportSettings.Format.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.format)

            if settings.format == .mp4 {
                row("Resolution") {
                    VideoSegmented(options: VideoExportSettings.Resolution.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.resolution)
                }
                row("Frame rate") {
                    VideoSegmented(options: VideoExportSettings.frameRates.map { ($0, "\($0) fps") }, selection: $model.exportSettings.fps)
                }
                row("Quality") {
                    VStack(alignment: .leading, spacing: 5) {
                        VideoSegmented(options: VideoExportSettings.Quality.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.quality)
                        Text(settings.quality.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(VideoEditorTheme.textTertiary)
                    }
                }
                row("Encoding") {
                    VStack(alignment: .leading, spacing: 5) {
                        VideoSegmented(options: VideoExportSettings.Codec.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.codec)
                        Text(settings.codec.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(VideoEditorTheme.textTertiary)
                    }
                }
                VideoToggleRow(title: "End card", detail: "A 2-second \"Made with Shotnix\" outro on your background", isOn: $model.exportSettings.endCard)
            } else {
                row("Size") {
                    VideoSegmented(options: VideoExportSettings.GIFSize.allCases.map { ($0, $0.title) }, selection: $model.exportSettings.gifSize)
                }
                row("Frame rate") {
                    VideoSegmented(options: VideoExportSettings.gifFrameRates.map { ($0, "\($0) fps") }, selection: $model.exportSettings.gifFPS)
                }
                Text("GIFs embed anywhere — READMEs, pull requests, docs. Keep them short: they get big fast.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            summary

            HStack(spacing: 10) {
                Button {
                    model.beginExport(toClipboard: true)
                } label: {
                    Label("Copy", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                .help("Export and put the file on the clipboard — paste it into Slack, Mail, or Finder")
                Button {
                    model.beginExport(toClipboard: false)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func gifWorkingBytes(size: CGSize, duration: Double) -> Int64 {
        let frames = (duration * Double(settings.gifFPS)).rounded(.up)
        return Int64(frames * Double(size.width * size.height) * 4)
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
        let duration = model.timelineDuration
        let bytes = settings.estimatedBytes(duration: duration, canvas: canvas, hasAudio: model.hasAudio)
        var parts = ["\(Int(size.width))×\(Int(size.height))", "\(settings.effectiveFrameRate) fps"]
        if settings.format == .mp4 { parts.append(settings.codec.title) }
        parts.append(VideoEditorModel.timecode(duration + (settings.format == .mp4 && settings.endCard ? VideoDemoExporter.endCardDuration : 0)))
        let sourceShort = min(model.project.sourceWidth, model.project.sourceHeight)
        let stageShort = min(model.project.stageRect(in: canvas).width, model.project.stageRect(in: canvas).height)
        let outputScale = min(size.width, size.height) / max(min(canvas.width, canvas.height), 1)
        let upscaled = settings.format == .mp4 && sourceShort > 0 && Double(stageShort * outputScale) > sourceShort * 1.15
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                Text("≈ \(VideoEditorModel.formatBytes(bytes))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            if upscaled {
                Label("Larger than the recording — text may look softer than at a lower resolution.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.format == .gif, gifWorkingBytes(size: size, duration: duration) > 1_500_000_000 {
                // A GIF keeps every frame in memory until it's written.
                Label("A long GIF — it needs about \(VideoEditorModel.formatBytes(gifWorkingBytes(size: size, duration: duration))) of memory to make. A smaller size, fewer fps, or MP4 is lighter.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.28)))
    }

    // MARK: Progress

    private func runningView(progress: Double, started: Date, destination: URL, clipboard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(clipboard ? "Rendering, then copying to your clipboard" : destination.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .lineLimit(1)
            if let voice = model.voiceJob, progress < 0.001 {
                // Enhance voice finishes first.
                Label("Cleaning up your voice first… \(Int((voice * 100).rounded()))%", systemImage: "waveform")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
            HStack {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(eta(progress: progress, started: started))
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
            Button {
                model.cancelExport()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
        }
    }

    private func eta(progress: Double, started: Date) -> String {
        let elapsed = Date().timeIntervalSince(started)
        guard progress > 0.03, elapsed > 0.5 else { return "Estimating…" }
        let remaining = elapsed / progress * (1 - progress)
        if remaining < 1 { return "Almost done" }
        if remaining < 60 { return "About \(Int(remaining.rounded(.up)))s left" }
        return "About \(Int((remaining / 60).rounded(.up))) min left"
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
                    Text(copied ? "\(VideoEditorModel.formatBytes(bytes)) · on your clipboard — paste it anywhere" : VideoEditorModel.formatBytes(bytes))
                        .font(.system(size: 11.5))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                if !copied {
                    Button { model.revealExport(url) } label: {
                        Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                    Button { model.copyExport(url) } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(VideoSecondaryButtonStyle())
                }
                Button { model.openExport(url) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
            }
            Button {
                close()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { model.exportPhase = .idle } label: {
                    Text("Back").frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                Button { close() } label: {
                    Text("Close").frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
            }
        }
    }
}
