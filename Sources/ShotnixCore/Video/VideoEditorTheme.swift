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
        }
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
                    .help("Reset")
                    .accessibilityLabel("Reset \(title)")
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
        HStack(spacing: 2) {
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
