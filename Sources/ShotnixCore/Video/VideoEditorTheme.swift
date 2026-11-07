import AppKit
import SwiftUI

/// The editor's dark, content-first palette.
enum VideoEditorTheme {
    static let window = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let stage = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.086)
    static let card = Color.white.opacity(0.045)
    static let cardHover = Color.white.opacity(0.075)
    static let cardStroke = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.58)
    /// Helper text: still readable on the panel (about 5:1).
    static let textTertiary = Color.white.opacity(0.5)
    static let zoom = Color(red: 0.43, green: 0.39, blue: 1.0)
    static let clip = Color(red: 0.94, green: 0.58, blue: 0.2)
    static let playhead = Color(red: 1.0, green: 0.31, blue: 0.43)
    static let accent = Color.accentColor
    /// Primary buttons: a fixed blue, so white text stays readable whatever
    /// accent color the Mac uses (yellow, orange, green…).
    static let primary = Color(red: 0.04, green: 0.42, blue: 1.0)

    static func overlayTint(_ kind: VideoDemoOverlayEffectKind) -> Color {
        switch kind {
        case .text: return Color(red: 0.62, green: 0.35, blue: 0.95)
        case .highlight: return Color(red: 0.92, green: 0.7, blue: 0.1)
        case .arrow: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .blur: return Color(white: 0.42)
        case .spotlight: return Color(red: 0.3, green: 0.66, blue: 0.82)
        case .image: return Color(red: 0.2, green: 0.66, blue: 0.9)
        }
    }
}

/// Values the editor shows, written the way the user's language writes them.
enum VideoEditorFormat {
    /// A fraction as a percentage: "42%" ("42 %" in German and French).
    static func percent(_ fraction: Double) -> String {
        L("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - Buttons

struct VideoToolButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        VideoToolButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct VideoToolButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let destructive: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }

        private var foreground: Color {
            guard isEnabled else { return VideoEditorTheme.textTertiary }
            if destructive { return Color(red: 1, green: 0.45, blue: 0.45) }
            return VideoEditorTheme.textPrimary
        }

        private var background: Color {
            if prominent { return Color.white.opacity(configuration.isPressed ? 0.2 : (hovered ? 0.16 : 0.11)) }
            if configuration.isPressed { return Color.white.opacity(0.14) }
            return hovered && isEnabled ? Color.white.opacity(0.08) : Color.clear
        }
    }
}

struct VideoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.45))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isEnabled ? VideoEditorTheme.primary : Color.white.opacity(0.08))
                        .brightness(configuration.isPressed ? -0.08 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(isEnabled ? 0.18 : 0.06), lineWidth: 1)
                )
                .shadow(color: VideoEditorTheme.primary.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 2)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

struct VideoSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, destructive: destructive)
    }

    private struct SecondaryBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? (destructive ? Color(red: 1, green: 0.47, blue: 0.47) : VideoEditorTheme.textPrimary) : VideoEditorTheme.textTertiary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.14 : (hovered && isEnabled ? 0.1 : 0.06)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovered = $0 }
        }
    }
}

// MARK: - Inspector building blocks

struct VideoInspectorSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                trailing()
            }
            content()
        }
    }
}

extension VideoInspectorSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// A labeled slider with its value and a reset button that appears when
/// the value differs from the default.
struct VideoSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?
    var format: (Double) -> String
    var detail: String?
    var onEditingEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Spacer()
                if let defaultValue, abs(value - defaultValue) > (range.upperBound - range.lowerBound) * 0.004 {
                    Button {
                        value = defaultValue
                        onEditingEnded()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(VideoEditorTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Reset"))
                    .accessibilityLabel(L("Reset \(title)"))
                }
                Text(format(value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
                    .frame(minWidth: 38, alignment: .trailing)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onEditingEnded() }
            })
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A sound level, from off to three times as loud as recorded. 100% sits
/// two-thirds along, so turning a sound down is as fine-grained as ever,
/// and the knob catches there on the way past. Past 100% the value turns
/// orange and says how much louder, in dB; a limiter keeps it from
/// crackling.
struct VideoLevelRow: View {
    let title: String
    @Binding var value: Double
    var detail: String?
    /// Says under the level, once it's past 100%, that it won't crackle
    /// (the value's tooltip always does).
    var boostNote = false
    var onEditingEnded: () -> Void = {}

    /// Where 100% sits along the slider.
    static let unity = 2.0 / 3.0
    /// How close to 100% the knob catches (a few points either side).
    static let catchDistance = 0.014

    static var loudest: Double { VideoAudioSettings.volumeRange.upperBound }

    /// The slider's position (0…1) for a level.
    static func position(for level: Double) -> Double {
        let level = min(max(level, 0), loudest)
        return level <= 1 ? level * unity : unity + (level - 1) / (loudest - 1) * (1 - unity)
    }

    /// The level at a slider position, to the whole percent, caught at 100%.
    static func level(at position: Double) -> Double {
        let position = min(max(position, 0), 1)
        if abs(position - unity) < catchDistance { return 1 }
        let level = position <= unity ? position / unity : 1 + (position - unity) / (1 - unity) * (loudest - 1)
        return (level * 100).rounded() / 100
    }

    static func isLouder(_ level: Double) -> Bool { level > 1.005 }

    /// "−6 dB", "+3.5 dB": how much quieter or louder than recorded.
    static func decibels(_ level: Double) -> String? {
        guard level > 0.004, abs(level - 1) > 0.004 else { return nil }
        return VideoEditorModel.formatDecibels(20 * log10(level))
    }

    var body: some View {
        let louder = Self.isLouder(value)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if abs(value - 1) > 0.004 {
                    Button {
                        value = 1
                        onEditingEnded()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(VideoEditorTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Reset"))
                    .accessibilityLabel(L("Reset \(title)"))
                }
                if let decibels = Self.decibels(value) {
                    Text(decibels)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(louder ? VideoEditorTheme.clip.opacity(0.8) : VideoEditorTheme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(VideoEditorFormat.percent(value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(louder ? VideoEditorTheme.clip : VideoEditorTheme.textSecondary)
                    .frame(minWidth: 38, alignment: .trailing)
                    .fixedSize()
            }
            .help(louder ? L("Plays louder than recorded, without crackling") : "")
            Slider(value: Binding(get: { Self.position(for: value) }, set: { value = Self.level(at: $0) }), in: 0...1, onEditingChanged: { editing in
                if !editing { onEditingEnded() }
            })
            .controlSize(.small)
            // Always a color: back at nil, AppKit's slider keeps the orange.
            .tint(louder ? VideoEditorTheme.clip : VideoEditorTheme.accent)
            .accessibilityLabel(title)
            .accessibilityValue([VideoEditorFormat.percent(value), Self.decibels(value)].compactMap { $0 }.joined(separator: ", "))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if boostNote, louder {
                Text(L("Plays louder than recorded, without crackling"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.clip.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VideoToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// Pill segmented control that matches the editor chrome.
struct VideoSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        VideoSegmentsLayout(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? VideoEditorTheme.textPrimary : VideoEditorTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // VoiceOver says which option is on.
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1)
        )
    }
}

/// Segments side by side: equal while every title fits its share. When one
/// doesn't (German and French run long), each segment gets its title's width
/// and some room around it, and they share what's left; titles truncate only
/// when even that doesn't fit.
struct VideoSegmentsLayout: Layout {
    var spacing: CGFloat
    /// Room on each side of a title when widths follow the titles.
    var titlePadding: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let spacings = spacing * CGFloat(max(subviews.count - 1, 0))
        let idealWidth = ideals.reduce(spacings) { $0 + $1.width + 2 * titlePadding }
        return CGSize(width: proposal.width ?? idealWidth, height: ideals.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let available = max(bounds.width - spacing * (count - 1), 0)
        let share = available / count
        let titles = subviews.map { $0.sizeThatFits(.unspecified).width }
        var widths = Array(repeating: share, count: subviews.count)
        if titles.contains(where: { $0 > share }) {
            let needed = titles.map { $0 + 2 * titlePadding }
            let total = needed.reduce(0, +)
            let extra = available - total
            widths = extra >= 0 ? needed.map { $0 + extra / count } : needed.map { $0 * available / max(total, 1) }
        }
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }
}

struct VideoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(VideoEditorTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(VideoEditorTheme.cardStroke, lineWidth: 1))
    }
}

/// Lets empty chrome drag the window (the toolbar lives in the title bar).
struct VideoWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
