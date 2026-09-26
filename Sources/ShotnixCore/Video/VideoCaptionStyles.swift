import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presets

/// How captions look: weight, ink, what's behind the words, and how the
/// spoken word stands out.
enum VideoCaptionPreset: String, Codable, CaseIterable, Identifiable {
    /// White words on a dark pill; words light up as they're spoken.
    case classic
    /// Heavy white words with a black outline, the spoken one in color.
    case outline
    /// Light words with a soft shadow, nothing behind them.
    case minimal
    /// The spoken word sits on a bright tag.
    case highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .outline: return "Bold outline"
        case .minimal: return "Minimal"
        case .highlight: return "Highlight"
        }
    }

    enum Backdrop {
        case pill
        case none
    }

    var weight: NSFont.Weight {
        switch self {
        case .classic: return .semibold
        case .outline: return .heavy
        case .minimal: return .medium
        case .highlight: return .bold
        }
    }

    var ink: VideoRGBA { VideoRGBA(1, 1, 1) }

    var backdrop: Backdrop { self == .classic ? .pill : .none }

    var backdropColor: VideoRGBA { VideoRGBA(0.03, 0.03, 0.03, 0.86) }

    /// The spoken word's color (or its tag's, for Highlight).
    var defaultHighlight: VideoRGBA {
        switch self {
        case .classic, .minimal: return VideoRGBA(1, 1, 1)
        case .outline: return VideoRGBA(hex: 0xFFD60A)
        case .highlight: return VideoRGBA(hex: 0x7C4DFF)
        }
    }

    /// Words not spoken yet, as a fraction of full ink.
    var upcomingAlpha: CGFloat {
        switch self {
        case .classic: return 0.5
        case .minimal: return 0.55
        case .outline, .highlight: return 1
        }
    }

    /// Swatches offered for the spoken word.
    static let highlightPalette: [VideoRGBA] = [
        VideoRGBA(hex: 0xFFD60A), VideoRGBA(hex: 0x30D158), VideoRGBA(hex: 0x64D2FF),
        VideoRGBA(hex: 0xFF375F), VideoRGBA(hex: 0xFF9F0A), VideoRGBA(hex: 0x7C4DFF), VideoRGBA(1, 1, 1),
    ]
}

extension VideoCaptionStyle {
    var resolvedHighlight: VideoRGBA { highlightColor ?? preset.defaultHighlight }
}

// MARK: - Drawing

/// Draws one caption line in its style — for the preview, the export, and
/// the style picker alike.
enum VideoCaptionDrawing {
    /// `spoken`: index of the word being said (-1: none yet); nil draws
    /// every word in full ink (no word timings, or highlighting off).
    static func image(text: String, words: [String], spoken: Int?, style: VideoCaptionStyle, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let preset = style.preset
        let font = NSFont.systemFont(ofSize: fontSize, weight: preset.weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = fontSize * (preset == .highlight ? 0.22 : 0.08)

        let ink = preset.ink.nsColor
        let highlight = style.resolvedHighlight.nsColor
        let content = NSMutableAttributedString()
        var ranges: [NSRange] = []
        if let spoken, !words.isEmpty {
            for (index, word) in words.enumerated() {
                if index > 0, VideoCaptionBuilder.needsSpace(between: words[index - 1], and: word) {
                    content.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                var color = ink
                if index > spoken {
                    color = ink.withAlphaComponent(preset.upcomingAlpha)
                } else if index == spoken, preset != .highlight {
                    color = highlight
                }
                let start = content.length
                content.append(NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: color]))
                ranges.append(NSRange(location: start, length: content.length - start))
            }
        } else {
            content.append(NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font, .foregroundColor: ink]))
        }
        content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))

        let padX = (fontSize * (preset.backdrop == .pill ? 0.7 : 0.45)).rounded()
        let padY = (fontSize * (preset.backdrop == .pill ? 0.36 : 0.3)).rounded()
        // Laid out once: the bounds, and the spoken word's box for Highlight.
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(maxWidth - padX * 2, fontSize), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = Int(ceil(used.width + padX * 2))
        let height = Int(ceil(used.height + padY * 2))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        if preset.backdrop == .pill {
            let radius = min(CGFloat(height) / 2, fontSize * 0.55)
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil))
            let fill = preset.backdropColor
            context.setFillColor(CGColor(srgbRed: fill.r, green: fill.g, blue: fill.b, alpha: fill.a))
            context.fillPath()
        }

        // Text system coordinates are top-down: flip to match.
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let origin = CGPoint(x: padX - used.minX, y: padY - used.minY)
        let glyphs = layout.glyphRange(for: container)

        if preset == .highlight, let spoken, ranges.indices.contains(spoken) {
            let glyphRange = layout.glyphRange(forCharacterRange: ranges[spoken], actualCharacterRange: nil)
            var box = layout.boundingRect(forGlyphRange: glyphRange, in: container).offsetBy(dx: origin.x, dy: origin.y)
            box = box.insetBy(dx: -fontSize * 0.18, dy: -fontSize * 0.04)
            let tag = NSBezierPath(roundedRect: box, xRadius: fontSize * 0.2, yRadius: fontSize * 0.2)
            highlight.setFill()
            tag.fill()
        }

        switch preset {
        case .outline:
            // A black outline under full-weight fill (the stroke centers on
            // the glyph edge, so drawing it first keeps the fill crisp).
            let stroke = NSMutableAttributedString(attributedString: content)
            stroke.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 15.0, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: stroke.length))
            let strokeStorage = NSTextStorage(attributedString: stroke)
            let strokeLayout = NSLayoutManager()
            let strokeContainer = NSTextContainer(size: container.size)
            strokeContainer.lineFragmentPadding = 0
            strokeLayout.addTextContainer(strokeContainer)
            strokeStorage.addLayoutManager(strokeLayout)
            strokeLayout.drawGlyphs(forGlyphRange: strokeLayout.glyphRange(for: strokeContainer), at: origin)
        case .minimal, .highlight:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(preset == .minimal ? 0.8 : 0.55)
            shadow.shadowBlurRadius = fontSize * 0.22
            // Shadow offsets ignore the flip: negative is down.
            shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.04)
            shadow.set()
        case .classic:
            break
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

// MARK: - Subtitle files

enum VideoSubtitleFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt

    var id: String { rawValue }
    var title: String { self == .srt ? ".srt (SubRip)" : ".vtt (WebVTT)" }
    var fileExtension: String { rawValue }
}

extension VideoCaptionBuilder {
    /// WebVTT for the edited timeline — the same lines and times as the
    /// video shows (cuts removed, speed applied), for web players.
    static func vtt(lines: [VideoCaptionLine], segments: [VideoDemoTimelineSegment], translation: [UUID: String]? = nil) -> String {
        var output = "WEBVTT\n\n"
        for caption in VideoRenderPlan.visibleCaptions(lines, segments: segments, translation: translation) {
            let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            output += "\(vttTimestamp(caption.start)) --> \(vttTimestamp(caption.end))\n\(escaped)\n\n"
        }
        return output
    }

    static func vttTimestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    /// SubRip for the edited timeline in the given caption track.
    static func srt(lines: [VideoCaptionLine], segments: [VideoDemoTimelineSegment], translation: [UUID: String]?) -> String {
        guard let translation else { return srt(lines: lines, segments: segments) }
        var output = ""
        var index = 1
        for caption in VideoRenderPlan.visibleCaptions(lines, segments: segments, translation: translation) {
            let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output += "\(index)\n\(timestamp(caption.start)) --> \(timestamp(caption.end))\n\(text)\n\n"
            index += 1
        }
        return output
    }

    /// The subtitles file for a project's shown caption track.
    static func subtitles(_ format: VideoSubtitleFormat, project: VideoDemoProject, segments: [VideoDemoTimelineSegment]) -> String {
        let translation = project.captionTracks.activeTranslation
        switch format {
        case .srt: return srt(lines: project.captions, segments: segments, translation: translation)
        case .vtt: return vtt(lines: project.captions, segments: segments, translation: translation)
        }
    }
}

extension VideoEditorModel {
    /// "Demo.srt", or "Demo.es.vtt" for a translated track.
    func subtitleFileName(_ format: VideoSubtitleFormat, base: String? = nil) -> String {
        let name = base ?? project.sourceURL.deletingPathExtension().lastPathComponent
        if let language = project.captionTracks.active {
            return "\(name).\(language).\(format.fileExtension)"
        }
        return "\(name).\(format.fileExtension)"
    }

    func exportSubtitles(_ format: VideoSubtitleFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = subtitleFileName(format)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VideoCaptionBuilder.subtitles(format, project: project, segments: segments).write(to: url, atomically: true, encoding: .utf8)
            showNotice("Saved \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
        } catch {
            showNotice("Couldn't save the captions file", symbol: "exclamationmark.triangle.fill")
        }
    }
}

// MARK: - Inspector

/// Four looks, drawn by the real caption renderer.
struct VideoCaptionPresetPicker: View {
    @ObservedObject var model: VideoEditorModel

    private var style: VideoCaptionStyle { model.project.captionStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(VideoCaptionPreset.allCases) { preset in
                    tile(preset)
                }
            }
            if style.highlightWords {
                HStack(spacing: 7) {
                    Text(style.preset == .highlight ? "Tag" : "Spoken word")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                        .fixedSize()
                    Spacer(minLength: 4)
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                        swatch(color)
                    }
                }
            }
        }
    }

    private var swatches: [VideoRGBA] {
        var colors = VideoCaptionPreset.highlightPalette
        if !colors.contains(style.preset.defaultHighlight) { colors.insert(style.preset.defaultHighlight, at: 0) }
        return colors
    }

    private func tile(_ preset: VideoCaptionPreset) -> some View {
        let selected = style.preset == preset
        return Button {
            model.setStyle { project in
                project.captionStyle.preset = preset
                // A new look starts with its own highlight.
                project.captionStyle.highlightColor = nil
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.3, blue: 0.46), Color(red: 0.42, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let image = VideoCaptionPresetThumbnails.shared.image(for: preset, highlight: selected ? style.highlightColor : nil) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.horizontal, 6)
                    }
                }
                .frame(height: 44)
                Text(preset.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? VideoEditorTheme.textPrimary : VideoEditorTheme.textSecondary)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.white.opacity(0.09) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Color.accentColor : VideoEditorTheme.cardStroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.title)
        .accessibilityLabel("Caption style \(preset.title)")
    }

    private func swatch(_ color: VideoRGBA) -> some View {
        let selected = style.resolvedHighlight == color
        return Button {
            model.setStyle { $0.captionStyle.highlightColor = color == $0.captionStyle.preset.defaultHighlight ? nil : color }
        } label: {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Color.white : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Highlight color")
    }
}

/// Style picker previews: a sample line through the real renderer.
@MainActor
final class VideoCaptionPresetThumbnails {
    static let shared = VideoCaptionPresetThumbnails()
    private var images: [String: NSImage] = [:]

    func image(for preset: VideoCaptionPreset, highlight: VideoRGBA?) -> NSImage? {
        let key = "\(preset.rawValue)-\(highlight.map { "\($0.r)-\($0.g)-\($0.b)" } ?? "default")"
        if let cached = images[key] { return cached }
        var style = VideoCaptionStyle()
        style.preset = preset
        style.highlightColor = highlight
        let words = ["Captions", "look", "like", "this"]
        guard let cgImage = VideoCaptionDrawing.image(text: words.joined(separator: " "), words: words, spoken: 1, style: style, fontSize: 26, maxWidth: 400) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        images[key] = image
        return image
    }
}

/// "Save Subtitles" with a choice of format.
struct VideoSubtitlesButton: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        Menu {
            ForEach(VideoSubtitleFormat.allCases) { format in
                Button("Save \(format.title)…") { model.exportSubtitles(format) }
            }
        } label: {
            Label("Save Subtitles", systemImage: "square.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
        } primaryAction: {
            model.exportSubtitles(.srt)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
        .help("A subtitles file for YouTube and web players (.srt), or for the web (.vtt) — follows your cuts")
    }
}
