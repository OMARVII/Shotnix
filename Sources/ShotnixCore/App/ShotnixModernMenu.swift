import AppKit
import SwiftUI

enum ShotnixMenuMetrics {
    static let commandCenterWidth: CGFloat = 360
    static let actionMenuWidth: CGFloat = 236
    static let cornerRadius: CGFloat = 12
    static let rowRadius: CGFloat = 9
}

@MainActor
final class ShotnixModernMenuPresenter {
    private var popover: NSPopover?

    // The command center reuses ONE popover + hosting controller for the
    // app's lifetime: building the SwiftUI tree fresh on every open cost
    // 15-40ms, and NSPopover's default zoom animation made even a fast open
    // feel sluggish. Cached content + no animation = the menu just appears.
    private var commandCenterPopover: NSPopover?
    private var commandCenterController: NSHostingController<ShotnixCommandCenterView>?

    var isShown: Bool {
        (popover?.isShown ?? false) || (commandCenterPopover?.isShown ?? false)
    }

    /// Builds the command center's SwiftUI hierarchy once at launch so the
    /// very first open pays no layout cost.
    func warmUp() {
        _ = commandCenterInfrastructure()
    }

    func showCommandCenter(
        sections: [ShotnixMenuSection],
        healthRows: [ShotnixHealthRow],
        healthActions: [ShotnixHealthKind: () -> Void],
        relativeTo button: NSStatusBarButton
    ) {
        let (popover, controller) = commandCenterInfrastructure()
        controller.rootView = ShotnixCommandCenterView(
            sections: sections,
            healthRows: healthRows,
            healthActions: healthActions,
            dismiss: { [weak self] in self?.dismiss() }
        )
        let screenHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 700
        let height = min(620, max(420, screenHeight - 80))
        popover.contentSize = NSSize(width: ShotnixMenuMetrics.commandCenterWidth, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        animateEntrance(on: controller.view)
    }

    /// Quick settle-in on the popover content: pure Core Animation on the
    /// hosting view's layer, applied AFTER the popover is shown — it can never
    /// touch SwiftUI state or re-enter AppKit layout (a SwiftUI-state version
    /// of this crashed inside NSView layout). The popover window still appears
    /// with zero latency; the content fades and settles over ~0.2s.
    private func animateEntrance(on view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "entranceFade")
        layer.removeAnimation(forKey: "entranceSlide")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "entranceFade")

        let slide = CASpringAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 6
        slide.toValue = 0
        slide.mass = 1
        slide.stiffness = 380
        slide.damping = 26
        slide.duration = slide.settlingDuration
        layer.add(slide, forKey: "entranceSlide")
    }

    private func commandCenterInfrastructure() -> (NSPopover, NSHostingController<ShotnixCommandCenterView>) {
        if let commandCenterPopover, let commandCenterController {
            return (commandCenterPopover, commandCenterController)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let controller = NSHostingController(
            rootView: ShotnixCommandCenterView(sections: [], healthRows: [], healthActions: [:], dismiss: {})
        )
        popover.contentViewController = controller
        commandCenterPopover = popover
        commandCenterController = controller
        return (popover, controller)
    }

    func showActionMenu(sections: [ShotnixMenuSection], at event: NSEvent, in view: NSView) {
        let popover = makePopover(width: ShotnixMenuMetrics.actionMenuWidth)
        let controller = NSHostingController(
            rootView: ShotnixActionMenuView(
                sections: sections,
                dismiss: { [weak self] in self?.dismiss() }
            )
        )
        popover.contentViewController = controller
        popover.contentSize = actionMenuSize(for: sections)
        self.popover = popover
        let point = view.convert(event.locationInWindow, from: nil)
        popover.show(
            relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1),
            of: view,
            preferredEdge: .maxY
        )
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
        // The command center popover is cached — close it but keep it warm.
        commandCenterPopover?.performClose(nil)
    }

    private func makePopover(width: CGFloat) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: width, height: 240)
        return popover
    }

    private func actionMenuSize(for sections: [ShotnixMenuSection]) -> NSSize {
        let actionCount = sections.reduce(0) { $0 + $1.actions.count }
        let height = CGFloat(actionCount * 40 + sections.count * 26 + 20)
        return NSSize(width: ShotnixMenuMetrics.actionMenuWidth, height: min(max(height, 120), 460))
    }
}

@MainActor
enum ShotnixContextMenu {
    private static let presenter = ShotnixModernMenuPresenter()

    static func show(sections: [ShotnixMenuSection], at event: NSEvent, in view: NSView) {
        presenter.showActionMenu(sections: sections, at: event, in: view)
    }
}

struct ShotnixCommandCenterView: View {
    let sections: [ShotnixMenuSection]
    let healthRows: [ShotnixHealthRow]
    let healthActions: [ShotnixHealthKind: () -> Void]
    let dismiss: () -> Void

    private var contentSections: [ShotnixMenuSection] {
        sections.filter { $0.id != "settings" }
    }

    private var footerActions: [ShotnixMenuAction] {
        sections.first { $0.id == "settings" }?.actions ?? []
    }

    private var visibleHealthRows: [ShotnixHealthRow] {
        healthRows.filter { $0.kind != .version }
    }

    private var versionRow: ShotnixHealthRow? {
        healthRows.first { $0.kind == .version }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ShotnixSmoothScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    healthSection

                    ForEach(contentSections) { section in
                        ShotnixMenuSectionView(section: section, dismiss: dismiss)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(width: ShotnixMenuMetrics.commandCenterWidth)
            }
            // Soft edge fades hint at scrollability now that no bar renders.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 10)
                }
            )
            .frame(maxHeight: 560)

            if !footerActions.isEmpty {
                ShotnixCommandFooter(
                    actions: footerActions,
                    versionText: versionRow?.detail,
                    dismiss: dismiss
                )
            }
        }
        .frame(width: ShotnixMenuMetrics.commandCenterWidth)
        .background(ShotnixHUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: ShotnixMenuMetrics.cornerRadius, style: .continuous))
        .onExitCommand(perform: dismiss)
        .focusable()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Shotnix")
                    .font(.system(size: 14, weight: .semibold))
                Text("Command Center")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.12))
    }

    private var attentionRows: [ShotnixHealthRow] {
        visibleHealthRows.filter { $0.state == .warning || $0.state == .issue }
    }

    /// When everything is green the old 2×N tile grid burned ~120pt at the
    /// top of every menu open. Healthy state collapses to one quiet line;
    /// tiles appear only for the rows that actually need attention.
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShotnixMenuSectionLabel("Health")

            if attentionRows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(NSColor.systemGreen))
                    Text("Everything is ready")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                    Spacer(minLength: 4)
                    Text("Capture · Record · Updates")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color(NSColor.systemGreen).opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(NSColor.systemGreen).opacity(0.14), lineWidth: 1)
                )
            } else {
                // Full-width rows, not half-width grid cells: attention tiles
                // are rare, and titles like "Apple Shortcuts · Conflict
                // detected" were truncating to "Apple Sho… / Conflict det…"
                // when squeezed into a 2-column grid.
                VStack(spacing: 6) {
                    ForEach(attentionRows) { row in
                        ShotnixHealthTile(
                            row: row,
                            action: healthActions[row.kind].map { action in
                                {
                                    dismiss()
                                    action()
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct ShotnixCommandFooter: View {
    let actions: [ShotnixMenuAction]
    let versionText: String?
    let dismiss: () -> Void

    private var primaryActions: [ShotnixMenuAction] {
        actions.filter { $0.id != "settings.quit" }
    }

    private var quitAction: ShotnixMenuAction? {
        actions.first { $0.id == "settings.quit" }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(primaryActions) { action in
                Button {
                    guard action.isEnabled else { return }
                    dismiss()
                    action.handler()
                } label: {
                    Image(systemName: action.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(action.isEnabled ? Color.white.opacity(0.82) : Color.white.opacity(0.28))
                        .background(Color.white.opacity(action.isEnabled ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .help(action.title)
            }

            Spacer(minLength: 8)

            if let versionText {
                Text(versionText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }

            if let quitAction {
                Button {
                    dismiss()
                    quitAction.handler()
                } label: {
                    Image(systemName: quitAction.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color(NSColor.systemRed).opacity(0.9))
                        .background(Color(NSColor.systemRed).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(quitAction.title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

struct ShotnixActionMenuView: View {
    let sections: [ShotnixMenuSection]
    let dismiss: () -> Void
    @State private var selectedActionID: String?

    private var enabledActions: [ShotnixMenuAction] {
        sections.flatMap(\.actions).filter(\.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                ShotnixMenuSectionView(
                    section: section,
                    selectedActionID: selectedActionID,
                    dismiss: dismiss,
                    onHover: { selectedActionID = $0 }
                )
            }
        }
        .padding(10)
        .frame(width: ShotnixMenuMetrics.actionMenuWidth)
        .background(ShotnixHUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: ShotnixMenuMetrics.cornerRadius, style: .continuous))
        .onAppear {
            selectedActionID = enabledActions.first?.id
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onSubmit {
            guard let action = enabledActions.first(where: { $0.id == selectedActionID }) else { return }
            dismiss()
            action.handler()
        }
        .onExitCommand(perform: dismiss)
        .focusable()
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !enabledActions.isEmpty else { return }
        guard let selectedActionID,
              let index = enabledActions.firstIndex(where: { $0.id == selectedActionID }) else {
            self.selectedActionID = enabledActions.first?.id
            return
        }

        switch direction {
        case .down, .right:
            self.selectedActionID = enabledActions[(index + 1) % enabledActions.count].id
        case .up, .left:
            self.selectedActionID = enabledActions[(index - 1 + enabledActions.count) % enabledActions.count].id
        @unknown default:
            break
        }
    }
}

private struct ShotnixMenuSectionView: View {
    let section: ShotnixMenuSection
    var selectedActionID: String?
    let dismiss: () -> Void
    var onHover: ((String?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShotnixMenuSectionLabel(section.title)

            VStack(spacing: 5) {
                ForEach(section.actions) { action in
                    ShotnixMenuActionRow(
                        action: action,
                        isSelected: selectedActionID == action.id,
                        dismiss: dismiss,
                        onHover: onHover
                    )
                }
            }
        }
    }
}

private struct ShotnixMenuSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
}

private struct ShotnixMenuActionRow: View {
    let action: ShotnixMenuAction
    let isSelected: Bool
    let dismiss: () -> Void
    let onHover: ((String?) -> Void)?
    @State private var isHovered = false

    private var active: Bool { isHovered || isSelected }
    private var isPrimary: Bool { action.role == .primary }

    var body: some View {
        Button {
            guard action.isEnabled else { return }
            dismiss()
            action.handler()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbolName)
                    .font(.system(size: isPrimary ? 14 : 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: isPrimary ? 24 : 22, height: isPrimary ? 24 : 22)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: isPrimary ? 13.5 : 13, weight: isPrimary ? .bold : .medium))
                        .foregroundStyle(textColor)
                        .lineLimit(1)

                    if let subtitle = action.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: ShotnixMenuMetrics.rowRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShotnixMenuMetrics.rowRadius, style: .continuous)
                    .stroke(rowBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ShotnixMenuMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.45)
        .onHover { hover in
            isHovered = hover
            if action.isEnabled {
                onHover?(hover ? action.id : nil)
            }
        }
    }

    private var textColor: Color {
        action.role == .destructive ? Color(NSColor.systemRed) : Color.primary
    }

    private var iconColor: Color {
        if action.role == .destructive { return Color(NSColor.systemRed) }
        if action.role == .primary { return .accentColor }
        return .primary
    }

    private var iconBackground: Color {
        if action.role == .destructive { return Color(NSColor.systemRed).opacity(0.15) }
        if isPrimary { return Color.accentColor.opacity(0.18) }
        return Color.white.opacity(0.07)
    }

    private var rowBackground: Color {
        if isPrimary && active { return Color.accentColor.opacity(0.16) }
        if isPrimary { return Color.accentColor.opacity(0.09) }
        if active { return Color.white.opacity(0.12) }
        return Color.white.opacity(0.045)
    }

    private var rowBorder: Color {
        if isPrimary { return Color.accentColor.opacity(active ? 0.34 : 0.22) }
        return Color.white.opacity(active ? 0.08 : 0.035)
    }

    private var rowHeight: CGFloat {
        if action.subtitle != nil { return 44 }
        return isPrimary ? 40 : 36
    }
}

private struct ShotnixHealthTile: View {
    let row: ShotnixHealthRow
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .help(row.actionTitle ?? row.title)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            // A real warning badge, not the feature's own icon tinted yellow —
            // the state must be readable at a glance.
            Image(systemName: stateSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            if action != nil, let actionTitle = row.actionTitle {
                Text(actionTitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(color.opacity(0.14), in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(color.opacity(0.16), lineWidth: 1)
        )
    }

    private var stateSymbol: String {
        switch row.state {
        case .warning: return "exclamationmark.triangle.fill"
        case .issue: return "exclamationmark.octagon.fill"
        case .ok: return "checkmark.circle.fill"
        case .info: return row.symbolName
        }
    }

    private var color: Color {
        switch row.state {
        case .ok: return Color(NSColor.systemGreen)
        case .warning: return Color(NSColor.systemYellow)
        case .issue: return Color(NSColor.systemRed)
        case .info: return .accentColor
        }
    }
}

/// SwiftUI's ScrollView on macOS ignores `.scrollIndicators(.hidden)` whenever
/// a mouse is connected or "Show scroll bars: Always" is set — the legacy
/// scroller still renders as a thick gray slab down the menu. Wrapping the
/// real NSScrollView guarantees a bar-free, elastic, buttery scroll.
private struct ShotnixSmoothScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? NSHostingView<Content>)?.rootView = content
    }
}

struct ShotnixHUDBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(
                colors: [
                    Color(NSColor(calibratedRed: 0.045, green: 0.049, blue: 0.062, alpha: 0.96)),
                    Color(NSColor(calibratedRed: 0.105, green: 0.096, blue: 0.13, alpha: 0.96))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.82)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
