import AppKit

@MainActor
final class VideoDemoPostRecordingPanel: NSWindow {
    private static var activePanel: VideoDemoPostRecordingPanel?
    private var autoOpenWorkItem: DispatchWorkItem?
    private let openHandler: () -> Void
    private let videoURL: URL

    static func show(videoURL: URL, autoOpen: Bool, openHandler: @escaping () -> Void) {
        activePanel?.close()
        let panel = VideoDemoPostRecordingPanel(videoURL: videoURL, autoOpen: autoOpen, openHandler: openHandler)
        activePanel = panel
        panel.show()
    }

    static func dismissActive() {
        activePanel?.close()
    }

    private init(videoURL: URL, autoOpen: Bool, openHandler: @escaping () -> Void) {
        self.openHandler = openHandler
        self.videoURL = videoURL

        let frame = NSRect(x: 0, y: 0, width: 342, height: 112)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

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

        let detail = NSTextField(labelWithString: videoURL.lastPathComponent)
        detail.font = .systemFont(ofSize: 10.5, weight: .semibold)
        detail.textColor = .white.withAlphaComponent(0.48)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.frame = NSRect(x: 16, y: 58, width: 310, height: 16)
        root.addSubview(detail)

        let edit = button(title: autoOpen ? "Opening Editor" : "Edit Video", symbol: "film.stack", x: 16, width: 112)
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

        if autoOpen {
            let workItem = DispatchWorkItem { [weak self] in
                self?.editVideo()
            }
            autoOpenWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
        }
    }

    override func close() {
        autoOpenWorkItem?.cancel()
        autoOpenWorkItem = nil
        super.close()
        if Self.activePanel === self {
            Self.activePanel = nil
        }
    }

    private func show() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 18, y: visible.maxY - frame.height - 18))
        }
        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            self?.close()
        }
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
        autoOpenWorkItem?.cancel()
        autoOpenWorkItem = nil
        openHandler()
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
