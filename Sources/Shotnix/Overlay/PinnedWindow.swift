import AppKit

/// A floating screenshot window that stays on top of everything.
/// Can be resized, dragged, and dismissed on hover.
@MainActor
final class PinnedWindow: NSWindow {

    private static var pinned: [PinnedWindow] = []

    static func pin(image: NSImage) {
        let win = PinnedWindow(image: image)
        win.show()
        pinned.append(win)
    }

    static func closeAll() {
        pinned.forEach { $0.orderOut(nil) }
        pinned.removeAll()
    }

    private let imageView: NSImageView
    private var trackingArea: NSTrackingArea?
    private var closeButton: NSButton?
    private var isHovered = false

    init(image: NSImage) {
        let size = constrainedSize(for: image.size)
        imageView = NSImageView(frame: NSRect(origin: .zero, size: size))

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true

        contentView = imageView
        center()
    }

    func show() {
        orderFrontRegardless()
        setupTrackingArea()
    }

    // MARK: – Hover (shows close button)

    private func setupTrackingArea() {
        if let old = trackingArea { imageView.removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: imageView.bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        imageView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        showCloseButton()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hideCloseButton()
    }

    private func showCloseButton() {
        guard closeButton == nil else { return }
        let btn = NSButton(frame: NSRect(x: frame.width - 24, y: frame.height - 24, width: 20, height: 20))
        btn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.target = self
        btn.action = #selector(closeTapped)
        btn.alphaValue = 0
        contentView?.addSubview(btn)
        closeButton = btn
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 1
        }
    }

    private func hideCloseButton() {
        guard let btn = closeButton else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 0
        }, completionHandler: {
            btn.removeFromSuperview()
        })
        closeButton = nil
    }

    @objc private func closeTapped() {
        PinnedWindow.pinned.removeAll { $0 === self }
        orderOut(nil)
    }

    // MARK: – Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Close Pin", action: #selector(closeTapped), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Close All Pins", action: #selector(closeAll), keyEquivalent: ""))
        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func closeAll() { PinnedWindow.closeAll() }
}

// Constrain initial size to something reasonable
private func constrainedSize(for size: NSSize) -> NSSize {
    let maxDim: CGFloat = 480
    let scale = min(1.0, min(maxDim / size.width, maxDim / size.height))
    return NSSize(width: size.width * scale, height: size.height * scale)
}
