import AppKit
import SwiftUI

extension ShotnixAppearance {
    /// The name under its picture in Settings, in the words macOS uses.
    var title: String {
        switch self {
        case .system: return L("Automatic appearance")
        case .light: return L("Light appearance")
        case .dark: return L("Dark appearance")
        }
    }
}

/// Settings > General > Appearance: three small windows to pick from, the
/// way macOS shows its own.
struct PreferenceAppearancePicker: View {
    @Binding var selection: ShotnixAppearance

    static let thumbnailSize = CGSize(width: 76, height: 50)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(ShotnixAppearance.allCases, id: \.self) { choice in
                let selected = choice == selection
                Button {
                    selection = choice
                } label: {
                    VStack(spacing: 6) {
                        AppearanceThumbnail(choice: choice)
                            .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(ShotnixTheme.ink(0.14), lineWidth: 1)
                            )
                            // The ring sits just outside the picture, like the Mac's.
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                        Text(choice.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(ShotnixTheme.ink(selected ? 0.9 : 0.58))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(minWidth: Self.thumbnailSize.width + 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A picture of a Shotnix window in one appearance; half and half for the
/// one that follows the Mac.
private struct AppearanceThumbnail: View {
    let choice: ShotnixAppearance

    var body: some View {
        switch choice {
        case .light:
            AppearanceMiniWindow(dark: false)
        case .dark:
            AppearanceMiniWindow(dark: true)
        case .system:
            ZStack {
                AppearanceMiniWindow(dark: false)
                AppearanceMiniWindow(dark: true)
                    .mask(
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    )
            }
        }
    }
}

/// Drawn in fixed colors: the picture shows an appearance, it doesn't
/// follow the one Settings is in.
private struct AppearanceMiniWindow: View {
    let dark: Bool

    private var top: Color { dark ? Color(red: 0.07, green: 0.075, blue: 0.095) : Color(red: 0.975, green: 0.978, blue: 0.988) }
    private var bottom: Color { dark ? Color(red: 0.135, green: 0.125, blue: 0.165) : Color(red: 0.915, green: 0.913, blue: 0.945) }
    private var ink: Color { dark ? .white : Color(red: 0.075, green: 0.078, blue: 0.098) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4.5) {
                HStack(spacing: 3.5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.accentColor).frame(width: 11, height: 5.5)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ink.opacity(0.2)).frame(width: 11, height: 5.5)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ink.opacity(0.2)).frame(width: 11, height: 5.5)
                }
                .padding(.bottom, 1)
                row(lineWidth: 26, on: true)
                row(lineWidth: 19, on: false)
            }
            .padding(7)
        }
    }

    private func row(lineWidth: CGFloat, on: Bool) -> some View {
        HStack(spacing: 0) {
            Capsule().fill(ink.opacity(dark ? 0.55 : 0.5)).frame(width: lineWidth, height: 3)
            Spacer(minLength: 0)
            Capsule().fill(on ? Color.accentColor : ink.opacity(0.22)).frame(width: 10, height: 5.5)
        }
        .padding(.horizontal, 4.5)
        .frame(height: 12)
        .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(ink.opacity(dark ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(ink.opacity(dark ? 0.08 : 0.07), lineWidth: 0.5))
    }
}
