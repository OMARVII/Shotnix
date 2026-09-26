import AppKit
import CoreImage
import SwiftUI

// MARK: - Model

/// A full-frame card before the first clip (intro) or after the last one
/// (outro): a title and a line under it on the video's own background.
/// Separate from the "Made with Shotnix" end card, which only the export adds.
struct VideoTitleCard: Codable, Equatable {
    static let durationRange: ClosedRange<Double> = 1...10

    var enabled = false
    var title = ""
    var subtitle = ""
    var duration = 3.0

    init(enabled: Bool = false, title: String = "", subtitle: String = "", duration: Double = 3) {
        self.enabled = enabled
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
    }

    /// Seconds it adds to the timeline (0 when off).
    var effectiveDuration: Double {
        enabled ? min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound) : 0
    }

    private enum CodingKeys: String, CodingKey { case enabled, title, subtitle, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3
    }
}

struct VideoTitleCards: Codable, Equatable {
    var intro = VideoTitleCard()
    var outro = VideoTitleCard()

    init(intro: VideoTitleCard = VideoTitleCard(), outro: VideoTitleCard = VideoTitleCard()) {
        self.intro = intro
        self.outro = outro
    }

    private enum CodingKeys: String, CodingKey { case intro, outro }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intro = (try? c.decode(VideoTitleCard.self, forKey: .intro)) ?? VideoTitleCard()
        outro = (try? c.decode(VideoTitleCard.self, forKey: .outro)) ?? VideoTitleCard()
    }
}

extension VideoDemoProject {
    /// Timeline seconds before the first clip (the intro card).
    var timelineLeadIn: Double { cards.intro.effectiveDuration }

    /// Timeline seconds after the last clip (the outro card).
    var timelineTail: Double { cards.outro.effectiveDuration }

    /// The edited video's length: the clips plus the intro and outro cards.
    func outputDuration(segments: [VideoDemoTimelineSegment]) -> Double {
        guard let last = segments.last else { return 0 }
        return last.timelineEnd + timelineTail
    }
}

// MARK: - Rendering

/// Draws a title card: the project's background (a little softer, so the
/// words read), the title, and the line under it — rising in, the way the
/// end card does.
enum VideoTitleCardRenderer {
    /// Seconds the card takes to dissolve into (or out of) the video.
    static let dissolve = 0.5

    /// Whether dark ink reads better than white on this background.
    static func usesDarkInk(_ background: VideoBackground) -> Bool {
        background.approximateLuminance > 0.62
    }

    /// The card's backdrop, rasterized once per size.
    static func base(background: VideoBackground, size: CGSize, context: CIContext) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let picture = VideoBackgroundRenderer.image(for: background, blur: 0.3, size: size)
        var image = picture
        if !usesDarkInk(background) {
            image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.22)).cropped(to: rect).composited(over: picture)
        }
        image = image.cropped(to: rect)
        if let cgImage = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            return CIImage(cgImage: cgImage)
        }
        return image
    }

    /// Title and subtitle on transparency, laid out for a `size` frame.
    static func text(title: String, subtitle: String, darkInk: Bool, size: CGSize) -> CIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 0, height > 0, !(trimmedTitle.isEmpty && trimmedSubtitle.isEmpty),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let unit = min(size.width, size.height) / 1080
        let ink = darkInk ? NSColor(white: 0.08, alpha: 1) : NSColor.white
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let maxWidth = size.width * 0.8

        var titleText: NSAttributedString?
        if !trimmedTitle.isEmpty {
            titleText = NSAttributedString(string: trimmedTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 76 * unit, weight: .bold),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
                .kern: -0.6 * unit,
            ])
        }
        var subtitleText: NSAttributedString?
        if !trimmedSubtitle.isEmpty {
            subtitleText = NSAttributedString(string: trimmedSubtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 34 * unit, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.74),
                .paragraphStyle: paragraph,
            ])
        }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let titleBounds = titleText?.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: options) ?? .zero
        let subtitleBounds = subtitleText?.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: options) ?? .zero
        let gap = titleText != nil && subtitleText != nil ? 20 * unit : 0
        let block = ceil(titleBounds.height) + gap + ceil(subtitleBounds.height)
        // Bottom-left origin: the title sits above the subtitle, the pair
        // centered (a touch above the middle, like a slide title).
        let top = size.height / 2 + block / 2 + 12 * unit

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if !darkInk {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 18 * unit
            shadow.shadowOffset = NSSize(width: 0, height: -3 * unit)
            shadow.set()
        }
        if let titleText {
            let rect = CGRect(x: (size.width - maxWidth) / 2, y: top - ceil(titleBounds.height), width: maxWidth, height: ceil(titleBounds.height))
            titleText.draw(with: rect, options: options)
        }
        if let subtitleText {
            let y = top - ceil(titleBounds.height) - gap - ceil(subtitleBounds.height)
            let rect = CGRect(x: (size.width - maxWidth) / 2, y: y, width: maxWidth, height: ceil(subtitleBounds.height))
            subtitleText.draw(with: rect, options: options)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    /// How far the text has risen in (0 → 1) `elapsed` seconds into the card.
    static func appear(_ elapsed: Double) -> Double {
        VideoCameraEasing.spring(min(max((elapsed - 0.1) / 0.7, 0), 1))
    }
}

extension VideoRenderPlan {
    /// Which card covers `time`, how far into it, and how opaque it is
    /// (it dissolves into the video after the intro and out of it before
    /// the outro).
    func card(at time: Double) -> (card: VideoTitleCard, isIntro: Bool, elapsed: Double, opacity: Double)? {
        if cards.intro.enabled, time < introEnd {
            let remaining = introEnd - time
            let fade = min(VideoTitleCardRenderer.dissolve, introEnd / 2)
            let opacity = fade > 0 && remaining < fade ? VideoCameraEasing.glide(remaining / fade) : 1
            return (cards.intro, true, max(time, 0), opacity)
        }
        if cards.outro.enabled, time > outroStart, outroStart < timelineDuration {
            let elapsed = time - outroStart
            let fade = min(VideoTitleCardRenderer.dissolve, (timelineDuration - outroStart) / 2)
            let opacity = fade > 0 && elapsed < fade ? VideoCameraEasing.glide(elapsed / fade) : 1
            return (cards.outro, false, elapsed, opacity)
        }
        return nil
    }
}

// MARK: - Editor

extension VideoEditorModel {
    /// A sensible first title: the recording's name unless it's just a
    /// date stamp.
    var suggestedIntroTitle: String {
        let name = project.sourceURL.deletingPathExtension().lastPathComponent
        let looksLikeStamp = name.hasPrefix("Shotnix") || name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        return looksLikeStamp ? "Welcome" : name
    }

    func setIntroEnabled(_ on: Bool) {
        setStyle { project in
            project.cards.intro.enabled = on
            if on, project.cards.intro.title.isEmpty, project.cards.intro.subtitle.isEmpty {
                project.cards.intro.title = suggestedIntroTitle
            }
        }
        if on { seek(to: 0) }
    }

    func setOutroEnabled(_ on: Bool) {
        setStyle { project in
            project.cards.outro.enabled = on
            if on, project.cards.outro.title.isEmpty, project.cards.outro.subtitle.isEmpty {
                project.cards.outro.title = "Thanks for watching"
            }
        }
        if on { seek(to: max(timelineDuration - 0.5, 0)) }
    }
}

/// Intro and outro cards, in the Style tab.
struct VideoTitleCardsSection: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VideoInspectorSection("Intro & outro") {
            cardEditor(
                title: "Intro card",
                detail: "Plays before the first clip",
                card: model.project.cards.intro,
                keyPath: \.intro,
                setEnabled: model.setIntroEnabled
            )
            Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
            cardEditor(
                title: "Outro card",
                detail: "Plays after the last clip, before the end card",
                card: model.project.cards.outro,
                keyPath: \.outro,
                setEnabled: model.setOutroEnabled
            )
            Text("Cards use your background, and the timeline grows to fit them. The “Made with Shotnix” end card is separate — it's in the export options.")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cardEditor(title: String, detail: String, card: VideoTitleCard, keyPath: WritableKeyPath<VideoTitleCards, VideoTitleCard>, setEnabled: @escaping (Bool) -> Void) -> some View {
        VideoToggleRow(title: title, detail: detail, isOn: Binding(get: { card.enabled }, set: { setEnabled($0) }))
        if card.enabled {
            VStack(alignment: .leading, spacing: 8) {
                field("Title", text: Binding(
                    get: { model.project.cards[keyPath: keyPath].title },
                    set: { value in model.setStyle(coalesce: "card-title-\(title)") { $0.cards[keyPath: keyPath].title = value } }
                ))
                field("Subtitle", text: Binding(
                    get: { model.project.cards[keyPath: keyPath].subtitle },
                    set: { value in model.setStyle(coalesce: "card-subtitle-\(title)") { $0.cards[keyPath: keyPath].subtitle = value } }
                ))
                VideoSliderRow(
                    title: "Length",
                    value: Binding(
                        get: { model.project.cards[keyPath: keyPath].duration },
                        set: { value in model.setStyle(coalesce: "card-length-\(title)") { $0.cards[keyPath: keyPath].duration = (value * 2).rounded() / 2 } }
                    ),
                    range: VideoTitleCard.durationRange,
                    defaultValue: 3,
                    format: { String(format: "%.1fs", $0) },
                    onEditingEnded: { model.endGesture() }
                )
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
            .onSubmit { model.endGesture() }
    }
}
