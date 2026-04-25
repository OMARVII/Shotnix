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

    private let imageView: DraggablePinnedImageView
    private var closeButton: NSButton?
    private var resizeGrip: NSImageView?
    private var isHovered = false

    init(image: NSImage) {
        let size = constrainedSize(for: image.size)
        let draggableImage = DraggablePinnedImageView(frame: NSRect(origin: .zero, size: size))
        imageView = draggableImage

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
        
        // Force proportional resize so the layer border always perfectly fits the image!
        self.aspectRatio = size

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = ShotnixColors.pinnedBorder.cgColor
        imageView.autoresizingMask = [.width, .height]

        draggableImage.onHoverStateChanged = { [weak self] hovered in
            self?.isHovered = hovered
            if hovered {
                self?.showCloseButton()
            } else {
                self?.hideCloseButton()
            }
        }

        contentView = imageView
        center()
    }

    func show() {
        orderFrontRegardless()
    }

    // MARK: – Hover (shows close button)

    private func showCloseButton() {
        guard closeButton == nil, let content = contentView else { return }
        let btn = NSButton(frame: NSRect(x: content.bounds.width - 24, y: content.bounds.height - 24, width: 20, height: 20))
        btn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.target = self
        btn.action = #selector(closeTapped)
        btn.alphaValue = 0
        // Stick to top-right corner during live window resize.
        btn.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(btn)
        closeButton = btn

        let grip = NSImageView(frame: NSRect(x: content.bounds.width - 20, y: 4, width: 16, height: 16))
        grip.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize")
        grip.contentTintColor = .white.withAlphaComponent(0.6)
        grip.alphaValue = 0
        // Stick to bottom-right corner during live window resize.
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(grip)
        resizeGrip = grip

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 1
            grip.animator().alphaValue = 1
        }
    }

    private func hideCloseButton() {
        guard let btn = closeButton else { return }
        let grip = resizeGrip
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 0
            grip?.animator().alphaValue = 0
        }, completionHandler: {
            btn.removeFromSuperview()
            grip?.removeFromSuperview()
        })
        closeButton = nil
        resizeGrip = nil
    }

    @objc private func closeTapped() {
        PinnedWindow.pinned.removeAll { $0 === self }
        orderOut(nil)
    }

    // MARK: – Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("Copy",            #selector(copyPinnedImage)),
            ("Save As…",        #selector(savePinnedImage)),
            ("Edit",            #selector(editPinnedImage)),
            ("Close Pin",       #selector(closeTapped)),
            ("Close All Pins",  #selector(closeAllPins)),
        ]
        for (title, sel) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            if title == "Edit" { menu.addItem(.separator()) }
        }
        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func copyPinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.copyToClipboard(image: image)
        ToastWindow.show(message: "✓ Copied to clipboard")
    }

    @objc private func savePinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.saveWithPanel(image: image, suggestedName: ImageExporter.timestampedName)
    }

    @objc private func editPinnedImage() {
        guard let image = imageView.image else { return }
        AnnotationWindowController.open(image: image)
        closeTapped()
    }

    @objc private func closeAllPins() { PinnedWindow.closeAll() }
}

// NSImageView consumes mouseDown for its own drag-and-drop, which blocks
// isMovableByWindowBackground. This subclass lets the window handle drags.
@MainActor
private final class DraggablePinnedImageView: NSImageView {
    var onHoverStateChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverStateChanged?(false)
    }
}

// Constrain initial size to something reasonable
private func constrainedSize(for size: NSSize) -> NSSize {
    let maxDim: CGFloat = 480
    let scale = min(1.0, min(maxDim / size.width, maxDim / size.height))
    return NSSize(width: size.width * scale, height: size.height * scale)
}
