import AppKit

/// "Recording saved" with Edit / Reveal / Copy Path, shown when the editor
/// doesn't open by itself. A non-activating panel: it takes keys (Esc
/// closes it) once clicked, without pulling focus from the app in front.
@MainActor
final class VideoDemoPostRecordingPanel: NSPanel {
    private static var activePanel: VideoDemoPostRecordingPanel?
    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private let openHandler: () -> Void
    private let videoURL: URL

    static func show(videoURL: URL, on screen: NSScreen? = nil, openHandler: @escaping () -> Void) {
        activePanel?.close()
        let panel = VideoDemoPostRecordingPanel(videoURL: videoURL, openHandler: openHandler)
        activePanel = panel
        panel.show(on: screen)
    }

    static func dismissActive() {
        activePanel?.close()
    }

    /// The panel on screen, for tests.
    static var visiblePanel: VideoDemoPostRecordingPanel? { activePanel }

    private init(videoURL: URL, openHandler: @escaping () -> Void) {
        self.openHandler = openHandler
        self.videoURL = videoURL

        let frame = NSRect(x: 0, y: 0, width: 342, height: 112)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true

        let root = NSVisualEffectView(frame: frame)
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        contentView = root

        let title = NSTextField(labelWithString: "Recording saved")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .white.withAlphaComponent(0.92)
        title.frame = NSRect(x: 16, y: 76, width: 190, height: 18)
        root.addSubview(title)

        // With the overlay timeout set to "Never" this is the only way out.
        let close = NSButton(frame: NSRect(x: frame.width - 34, y: frame.height - 34, width: 22, height: 22))
        close.isBordered = false
        close.title = ""
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        close.imagePosition = .imageOnly
        close.contentTintColor = .white.withAlphaComponent(0.5)
        close.toolTip = "Close (Esc)"
        close.target = self
        close.action = #selector(closeTapped)
        root.addSubview(close)

        let detail = NSTextField(labelWithString: videoURL.lastPathComponent)
        detail.font = .systemFont(ofSize: 10.5, weight: .semibold)
        detail.textColor = .white.withAlphaComponent(0.48)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.frame = NSRect(x: 16, y: 58, width: 310, height: 16)
        root.addSubview(detail)

        let edit = button(title: "Edit Video", symbol: "film.stack", x: 16, width: 112)
        edit.target = self
        edit.action = #selector(editVideo)
        root.addSubview(edit)

        let reveal = button(title: "Reveal", symbol: "folder", x: 136, width: 84)
        reveal.target = self
        reveal.action = #selector(revealFile)
        root.addSubview(reveal)

        let copy = button(title: "Copy Path", symbol: "doc.on.doc", x: 228, width: 98)
        copy.target = self
        copy.action = #selector(copyPath)
        root.addSubview(copy)

        // Hover pauses the auto-close countdown (mouseEntered/mouseExited below).
        // The panel has a fixed size, so a one-time tracking area is enough.
        let tracking = NSTrackingArea(rect: root.bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        root.addTrackingArea(tracking)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        super.close()
        if Self.activePanel === self {
            Self.activePanel = nil
        }
    }

    // Esc once the panel has been clicked (it's key then).
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// Top-right of the screen the recording was made on.
    private func show(on screen: NSScreen?) {
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 18, y: visible.maxY - frame.height - 18))
        }
        orderFrontRegardless()
        // Esc while Shotnix is in front, whichever of its windows is key
        // (unless that window handles Esc itself: editors, sheets).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  NSApp.keyWindow == nil || NSApp.keyWindow === self else { return event }
            self.close()
            return nil
        }
        // Don't start the countdown while the cursor already sits over the panel —
        // mouseExited will arm it once the user moves away.
        if !frame.contains(NSEvent.mouseLocation) {
            scheduleAutoClose()
        }
    }

    /// Auto-close after the user-configured overlay timeout (-1 = never),
    /// same convention as the post-capture overlay.
    private func scheduleAutoClose() {
        dismissTimer?.invalidate()
        let timeout = Settings.overlayTimeout
        guard timeout > 0 else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    // Pause/resume auto-close on hover (matches QuickAccessOverlay behavior)
    override func mouseEntered(with event: NSEvent) {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    override func mouseExited(with event: NSEvent) {
        scheduleAutoClose()
    }

    private func button(title: String, symbol: String, x: CGFloat, width: CGFloat) -> NSButton {
        let button = NSButton(frame: NSRect(x: x, y: 16, width: width, height: 30))
        button.title = title
        button.font = .systemFont(ofSize: 11, weight: .bold)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.88)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        button.layer?.cornerRadius = 8
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func editVideo() {
        openHandler()
        close()
    }

    @objc private func closeTapped() {
        close()
    }

    @objc private func revealFile(_ sender: NSButton) {
        NSWorkspace.shared.activateFileViewerSelecting([videoURL])
    }

    @objc private func copyPath(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(videoURL.path, forType: .string)
    }
}
