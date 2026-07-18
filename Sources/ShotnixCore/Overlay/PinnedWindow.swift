import AppKit

/// A floating screenshot window that stays on top of everything.
/// Can be resized, dragged, and dismissed on hover.
@MainActor
final class PinnedWindow: NSWindow {

    private static var pinned: [PinnedWindow] = []

    /// Pins a screenshot as a floating window. When the original capture rect
    /// is known, the pin appears exactly over where the capture was taken;
    /// otherwise it falls back to centering on the main screen.
    static func pin(image: NSImage, at rect: CGRect? = nil) {
        let win = PinnedWindow(image: image)
        if let rect {
            win.positionOverCaptureRect(rect)
        }
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

    /// Places the window exactly over the original capture rect, on the screen
    /// where the capture happened. `HistoryItem.captureRect` is stored in AppKit
    /// screen coordinates (bottom-left origin, via AreaSelectionWindow's
    /// convertToScreen), so no CG top-left flip is needed — only clamping to the
    /// target screen's visibleFrame.
    private func positionOverCaptureRect(_ rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        guard let screen = NSScreen.screenContaining(rect: rect) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let imageAspect = frame.height > 0 ? frame.width / frame.height : 1
        let rectAspect = rect.width / rect.height
        let size: NSSize
        let origin: NSPoint
        if abs(imageAspect - rectAspect) < 0.01 * max(imageAspect, rectAspect) {
            // Aspect matches (normal area/window captures): sit exactly over the
            // capture, shrinking proportionally if it exceeds the usable screen
            // area (menu bar / Dock overlap) so the pin always fits on screen.
            let scale = min(1.0, min(visible.width / rect.width, visible.height / rect.height))
            size = NSSize(width: rect.width * scale, height: rect.height * scale)
            origin = rect.origin
        } else {
            // Image aspect differs from the capture rect (e.g. stitched scrolling
            // capture): keep the image-derived size from init and just center the
            // pin over the rect.
            size = frame.size
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        }

        // Clamp the origin so the pin stays fully inside the visible frame.
        let x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        let y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
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
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    // MARK: – Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        guard let view = contentView else { return }
        ShotnixContextMenu.show(
            sections: [
                ShotnixMenuSection(id: "pin.capture", title: "Pinned Screenshot", actions: [
                    ShotnixMenuAction(id: "pin.copy", title: "Copy", symbolName: "doc.on.doc", role: .primary) { [weak self] in self?.copyPinnedImage() },
                    ShotnixMenuAction(id: "pin.save", title: "Save As", symbolName: "square.and.arrow.down") { [weak self] in self?.savePinnedImage() },
                    ShotnixMenuAction(id: "pin.edit", title: "Edit", symbolName: "pencil") { [weak self] in self?.editPinnedImage() },
                ]),
                ShotnixMenuSection(id: "pin.manage", title: "Manage", actions: [
                    ShotnixMenuAction(id: "pin.close", title: "Close Pin", symbolName: "xmark") { [weak self] in self?.closeTapped() },
                    ShotnixMenuAction(id: "pin.close-all", title: "Close All Pins", symbolName: "rectangle.stack.badge.minus", role: .destructive) { [weak self] in self?.closeAllPins() },
                ])
            ],
            at: event,
            in: view
        )
    }

    @objc private func copyPinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.copyToClipboard(image: image)
        ToastWindow.show(message: "✓ Copied to clipboard", on: screen)
    }

    @objc private func savePinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.saveWithPanel(image: image, suggestedName: ImageExporter.timestampedName, presentingWindow: self) { [weak self] result in
            if result.didSave {
                ToastWindow.show(message: "✓ Saved screenshot", on: self?.screen)
            }
        }
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
