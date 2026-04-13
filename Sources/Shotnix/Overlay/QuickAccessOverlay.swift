import AppKit
import QuartzCore

/// Post-capture floating thumbnail with quick action buttons.
/// Position and dismiss timeout are controlled via Preferences → Settings.
@MainActor
final class QuickAccessOverlay {

    static func show(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager) {
        let window = QuickAccessWindow(image: image, historyItem: historyItem, historyManager: historyManager)
        window.show()
    }
}

@MainActor
private final class QuickAccessWindow: NSWindow {

    /// Keep strong refs so ARC doesn't deallocate while visible.
    private static var openWindows: [QuickAccessWindow] = []

    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    private let historyItem: HistoryItem
    private let historyManager: HistoryManager
    private let image: NSImage
    private var controlsOverlay: NSView?
    private var isHovered = false
    private var swipeAccumX: CGFloat = 0

    init(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager

        let thumbW: CGFloat = 240
        let aspect = image.size.height / max(image.size.width, 1)
        let thumbH: CGFloat = min(thumbW * aspect, 160)
        let progressH: CGFloat = 1.5
        let totalH = thumbH + progressH

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: thumbW, height: totalH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buildContent(thumbW: thumbW, thumbH: thumbH, progressH: progressH, totalH: totalH)
        positionOverlay()
        installEventMonitors()
    }

    override var canBecomeKey: Bool { true }

    // MARK: – Keyboard (direct override — works when window IS key)

    override func keyDown(with event: NSEvent) {
        guard !isClosing else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers, flags) {
        case ("c", .command):  copyAction()
        case ("s", .command):  saveAction()
        case ("e", .command):  editAction()
        default: break
        }
        if event.keyCode == 53 { dismissAction() }
    }

    // MARK: – Event Monitors (bypass view hierarchy entirely)

    private func installEventMonitors() {
        // Keyboard: catches ⌘C/⌘S/⌘E/Escape at the app level — no key window needed
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            // Only handle if mouse is over our window
            guard self.frame.contains(NSEvent.mouseLocation) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (event.charactersIgnoringModifiers, flags) {
            case ("c", .command):  self.copyAction(); return nil
            case ("s", .command):  self.saveAction(); return nil
            case ("e", .command):  self.editAction(); return nil
            default: break
            }
            if event.keyCode == 53 { self.dismissAction(); return nil }
            return event
        }

        // Global mouse: activates app when cursor enters overlay frame (works even when app is inactive)
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            DispatchQueue.main.async {
                self.setHovered(inside)
                if inside {
                    NSApp.setActivationPolicy(.accessory)
                    NSApp.activate(ignoringOtherApps: true)
                    self.makeKeyAndOrderFront(nil)
                    self.makeFirstResponder(self)
                }
            }
        }

        // Local mouse: keeps window key while hovering + tracks hover state
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            self.setHovered(inside)
            if inside && !self.isKeyWindow {
                self.makeKey()
            }
            return event
        }

        // Swipe-to-dismiss: trackpad swipe toward nearest screen edge closes overlay
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            guard self.frame.contains(NSEvent.mouseLocation) else { return event }

            self.swipeAccumX += event.scrollingDeltaX
            let threshold: CGFloat = 60
            if abs(self.swipeAccumX) > threshold {
                let direction = self.swipeAccumX > 0 ? CGFloat(1) : CGFloat(-1)
                self.swipeAccumX = 0
                self.swipeDismiss(direction: direction)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyAction), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Save", action: #selector(saveAction), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Edit", action: #selector(editAction), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Pin", action: #selector(pinAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Close", action: #selector(dismissAction), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func buildContent(thumbW: CGFloat, thumbH: CGFloat, progressH: CGFloat, totalH: CGFloat) {
        let container = OverlayContentView(frame: NSRect(x: 0, y: 0, width: thumbW, height: totalH))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.35
        container.layer?.shadowRadius = 24
        container.layer?.shadowOffset = CGSize(width: 0, height: -6)
        contentView = container

        // Clip subviews so content respects corner radius while shadow remains visible
        let clipView = NSView(frame: container.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 8
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        container.addSubview(clipView)

        // Subtle inner border — gives definition against any background color
        let borderView = NSView(frame: container.bounds)
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 8
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.borderWidth = 0.5
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.addSubview(borderView)

        // Draggable thumbnail — drag to Finder/apps, double-click to annotate
        let thumbFrame = NSRect(x: 0, y: progressH, width: thumbW, height: thumbH)
        let thumb = DraggableImageView(frame: thumbFrame)
        thumb.image = image
        thumb.imageScaling = .scaleNone
        thumb.wantsLayer = true
        // Render via CALayer for crisp retina aspect-fill (no NSImageView resampling)
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.contents = image.bestCGImage
        thumb.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        thumb.dragImage = image
        thumb.onDoubleClick = { [weak self] in self?.editAction() }
        thumb.onDragStarted = { [weak self] in self?.dismissTimer?.invalidate() }
        thumb.onDragCompleted = { [weak self] in self?.animatedClose() }
        clipView.addSubview(thumb)

        // Controls overlay — dark gradient scrim with action buttons, hidden by default
        let controlsH: CGFloat = 40
        let controls = NSView(frame: NSRect(x: 0, y: progressH, width: thumbW, height: controlsH))
        controls.wantsLayer = true

        let gradient = CAGradientLayer()
        gradient.frame = controls.bounds
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        controls.layer?.addSublayer(gradient)

        let actions: [(String, String, Selector)] = [
            ("doc.on.clipboard",      "Copy",    #selector(copyAction)),
            ("square.and.arrow.down", "Save",    #selector(saveAction)),
            ("pencil",                "Edit",    #selector(editAction)),
            ("pin",                   "Pin",     #selector(pinAction)),
            ("xmark",                 "Close",   #selector(dismissAction)),
        ]
        let btnSize: CGFloat = 28
        let spacing: CGFloat = 4
        let totalBtnsW = CGFloat(actions.count) * btnSize + CGFloat(actions.count - 1) * spacing
        let startX = (thumbW - totalBtnsW) / 2
        let btnY: CGFloat = 6
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        for (i, (icon, tooltip, sel)) in actions.enumerated() {
            let btn = OverlayHoverButton(frame: NSRect(
                x: startX + CGFloat(i) * (btnSize + spacing),
                y: btnY, width: btnSize, height: btnSize
            ))
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)?.withSymbolConfiguration(iconConfig)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.toolTip = tooltip
            btn.target = self
            btn.action = sel
            btn.imageScaling = .scaleNone
            btn.contentTintColor = .white
            controls.addSubview(btn)
        }

        controls.alphaValue = 0
        clipView.addSubview(controls)
        controlsOverlay = controls

        // Progress bar at the very bottom — thin, bright accent line
        let timeout = Settings.overlayTimeout
        if timeout > 0 {
            let progressBg = NSView(frame: NSRect(x: 0, y: 0, width: thumbW, height: progressH))
            progressBg.wantsLayer = true
            progressBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
            clipView.addSubview(progressBg)

            let progressFill = NSView(frame: progressBg.bounds)
            progressFill.wantsLayer = true
            progressFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            progressBg.addSubview(progressFill)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = timeout
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                progressFill.animator().frame = NSRect(x: 0, y: 0, width: 0, height: progressH)
            })

            dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.animatedClose() }
            }
        }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered

        // Pause/resume auto-dismiss timer on hover (like CleanShot X)
        if hovered {
            dismissTimer?.invalidate()
        } else {
            let remaining = Settings.overlayTimeout
            if remaining > 0 {
                dismissTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.animatedClose() }
                }
            }
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            controlsOverlay?.animator().alphaValue = hovered ? 1 : 0
        }

        // Subtle scale-up on hover (1.0 → 1.02) for lively micro-interaction
        guard let layer = contentView?.layer else { return }
        let scale: CGFloat = hovered ? 1.02 : 1.0
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = hovered ? 1.0 : 1.02
        anim.toValue = scale
        anim.duration = 0.25
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "hoverScale")
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func positionOverlay() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 36
        let x: CGFloat
        if Settings.overlayOnLeft {
            x = screen.visibleFrame.minX + margin
        } else {
            x = screen.visibleFrame.maxX - frame.width - margin
        }
        let y = screen.visibleFrame.minY + margin
        // Start at final position (slide-up is handled by scale spring, not position offset)
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0

        // LSUIElement apps have .prohibited activation policy — activate() is
        // unreliable without temporarily escalating to .accessory first.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(self)

        // Deferred re-checks: activate() is async and completion time varies.
        // 100ms catches the common case; 300ms catches slow activation handshakes.
        for delay in [0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isClosing else { return }
                if !self.isKeyWindow {
                    NSApp.setActivationPolicy(.accessory)
                    NSApp.activate(ignoringOtherApps: true)
                    self.makeKeyAndOrderFront(nil)
                    self.makeFirstResponder(self)
                }
            }
        }

        // Scale entrance: start at 92% and spring to 100%
        if let layer = contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.position = CGPoint(x: frame.width / 2, y: 0)

            let scaleAnim = CASpringAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.92
            scaleAnim.toValue = 1.0
            scaleAnim.mass = 1.0
            scaleAnim.stiffness = 300
            scaleAnim.damping = 18
            scaleAnim.initialVelocity = 0
            scaleAnim.duration = scaleAnim.settlingDuration
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            layer.add(scaleAnim, forKey: "entranceScale")
        }

        // Fade in (scale spring handles the motion)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Swipe-dismiss: slide overlay off-screen toward the swipe direction
    private func swipeDismiss(direction: CGFloat) {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()

        let slideDistance: CGFloat = frame.width + 40
        let targetX = frame.origin.x + (direction * slideDistance)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().setFrameOrigin(NSPoint(x: targetX, y: self.frame.origin.y))
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    private var isClosing = false

    private func animatedClose() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    private var didCleanup = false

    private func forceCleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        removeEventMonitors()
        orderOut(nil)
        QuickAccessWindow.openWindows.removeAll { $0 === self }
        // Restore background-only policy so app doesn't appear in Cmd-Tab
        if QuickAccessWindow.openWindows.isEmpty {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    // MARK: – Actions

    @objc private func copyAction() {
        ImageExporter.copyToClipboard(image: image)
        showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
    }

    @objc private func saveAction() {
        ImageExporter.saveWithPanel(image: image, suggestedName: ImageExporter.timestampedName)
        animatedClose()
    }

    /// Flash a confirmation icon over the thumbnail before closing
    private func showConfirmation(icon: String, then completion: @escaping () -> Void) {
        guard let clip = contentView?.subviews.first else { completion(); return }
        let size: CGFloat = 36
        let badge = NSImageView(frame: NSRect(
            x: (clip.bounds.width - size) / 2,
            y: (clip.bounds.height - size) / 2,
            width: size, height: size
        ))
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        badge.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badge.layer?.cornerRadius = size / 2
        badge.layer?.cornerCurve = .continuous
        badge.alphaValue = 0
        clip.addSubview(badge)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            badge.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                completion()
            }
        })
    }

    @objc private func editAction() {
        animatedClose()
        AnnotationWindowController.open(image: image, historyItem: historyItem, historyManager: historyManager)
    }

    @objc private func pinAction() {
        animatedClose()
        PinnedWindow.pin(image: image)
    }

    @objc private func dismissAction() {
        animatedClose()
    }

    func show() {
        QuickAccessWindow.openWindows.append(self)
    }
}

// MARK: – Draggable thumbnail (drag-and-drop to Finder/apps like CleanShot X)

@MainActor
private final class DraggableImageView: NSImageView, NSDraggingSource {

    var dragImage: NSImage?
    var onDoubleClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragCompleted: (() -> Void)?

    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let dragImg = dragImage else { return }
        let current = event.locationInWindow
        let dx = abs(current.x - origin.x)
        let dy = abs(current.y - origin.y)
        guard dx > 3 || dy > 3 else { return }

        dragOrigin = nil
        onDragStarted?()

        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: ImageFilePromiseDelegate(image: dragImg))
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: dragImg)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in
            self?.onDragCompleted?()
        }
    }
}

// MARK: – File promise for drag-and-drop

private final class ImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "\(ImageExporter.timestampedName).png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            if let png = ImageExporter.pngData(from: image) {
                try png.write(to: url)
            }
            handler(nil)
        } catch {
            handler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}

// MARK: – Content view that accepts first mouse + right-click

@MainActor
private final class OverlayContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: – Overlay hover button (white icon on dark scrim)

@MainActor
private final class OverlayHoverButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 6
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
