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
    private weak var timeoutProgressLayer: CALayer?
    private var isHovered = false
    private var mouseInsideOverlay = false
    private var swipeAccumX: CGFloat = 0

    init(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager

        // Fixed premium container — every capture renders at the same size so
        // the overlay has a consistent, CleanShot-style visual presence
        // regardless of whether the user grabbed a 4K fullscreen, a narrow
        // banner, or a tall sidebar. The image inside is aspect-fit (letterboxed)
        // so the full capture is always visible against the container's dark tint.
        let thumbW: CGFloat = 240
        let thumbH: CGFloat = 150
        // Use an integer value so the controls overlay placed above it sits on an integer pixel boundary
        // This prevents CoreAnimation from subpixel blending straight edges against the frosted glass.
        let progressH: CGFloat = 2.0
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
        hasShadow = true
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
            guard inside != self.mouseInsideOverlay else { return }
            self.mouseInsideOverlay = inside
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
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Close", action: #selector(dismissAction), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func buildContent(thumbW: CGFloat, thumbH: CGFloat, progressH: CGFloat, totalH: CGFloat) {
        let container = OverlayContentView(frame: NSRect(x: 0, y: 0, width: thumbW, height: totalH))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.55
        container.layer?.shadowRadius = 30
        container.layer?.shadowOffset = CGSize(width: 0, height: -10)
        contentView = container

        // Clip subviews so content respects corner radius while shadow remains visible
        let clipView = NSView(frame: container.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 12
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        // Subtle dark tint — frames content, visible at rounded corners and behind image
        clipView.layer?.backgroundColor = ShotnixColors.overlayTint.cgColor
        container.addSubview(clipView)

        // White border — primary edge definition on light wallpapers (shadow handles dark)
        let borderView = NSView(frame: container.bounds)
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 12
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.borderWidth = 1.5
        borderView.layer?.borderColor = ShotnixColors.overlayBorder.cgColor
        container.addSubview(borderView)

        // Draggable thumbnail — drag to Finder/apps, double-click to annotate.
        // Dark container fill goes on the thumb's own layer so letterbox bars
        // read as a proper container without inserting an extra opaque subview
        // that can interfere with hit-testing on the controls overlay above.
        let thumbFrame = NSRect(x: 0, y: progressH, width: thumbW, height: thumbH)
        let thumb = DraggableImageView(frame: thumbFrame)
        thumb.image = image
        thumb.imageScaling = .scaleNone
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = ShotnixColors.overlayContainerFill.cgColor
        // resizeAspect letterboxes the image inside the fixed container so the
        // full capture is visible with dark bars on the short axis — matches
        // CleanShot X. resizeAspectFill was cropping content on wide captures.
        thumb.layer?.contentsGravity = .resizeAspect
        thumb.layer?.contents = image.bestCGImage
        thumb.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        thumb.dragImage = image
        thumb.onDoubleClick = { [weak self] in self?.editAction() }
        thumb.onDragStarted = { [weak self] in self?.dismissTimer?.invalidate() }
        thumb.onDragCompleted = { [weak self] in self?.animatedClose() }
        clipView.addSubview(thumb)

        // Controls overlay — frosted glass + corner circles + center pills
        let controls = NSView(frame: NSRect(x: 0, y: progressH, width: thumbW, height: thumbH))
        controls.wantsLayer = true

        // Frosted glass backdrop
        let frost = NSVisualEffectView(frame: controls.bounds)
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        controls.addSubview(frost)

        // ── Corner circles (28px glass buttons, all 4 corners) ──
        let cSize: CGFloat = 28
        let cMargin: CGFloat = 8
        let cConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let corners: [(String, String, Selector, CGFloat, CGFloat)] = [
            ("pencil",  "Edit",   #selector(editAction),    cMargin,                   thumbH - cSize - cMargin),
            ("xmark",   "Close",  #selector(dismissAction), thumbW - cSize - cMargin,  thumbH - cSize - cMargin),
            ("trash",   "Delete", #selector(deleteAction),  cMargin,                   cMargin),
            ("pin",     "Pin",    #selector(pinAction),     thumbW - cSize - cMargin,  cMargin),
        ]
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        for (icon, tip, sel, cx, cy) in corners {
            let btn = OverlayCornerButton(frame: NSRect(x: cx, y: cy, width: cSize, height: cSize))
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tip)?.withSymbolConfiguration(cConfig)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.toolTip = tip
            btn.target = self
            btn.action = sel
            btn.imageScaling = .scaleNone
            btn.contentTintColor = .white
            btn.wantsLayer = true
            btn.layer?.contentsScale = screenScale
            btn.layer?.cornerRadius = cSize / 2
            btn.layer?.cornerCurve = .continuous
            btn.layer?.backgroundColor = ShotnixColors.cornerButtonBackground.cgColor
            controls.addSubview(btn)
        }

        // ── Center pills (tight-fit white capsules) ──
        let pillH: CGFloat = 28
        let pillGap: CGFloat = 8
        let pillPadding: CGFloat = 28  // total horizontal padding (14 each side)
        let pillFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            .font: pillFont,
        ]

        let pills: [(String, Selector)] = [
            ("Copy", #selector(copyAction)),
            ("Save", #selector(saveAction)),
        ]

        // Measure each pill to fit text snugly
        let pillWidths = pills.map { title, _ in
            ceil((title as NSString).size(withAttributes: pillAttrs).width) + pillPadding
        }
        let totalPillW = pillWidths.reduce(0, +) + CGFloat(pills.count - 1) * pillGap
        let pillY = round((thumbH - pillH) / 2)
        var pillCursorX = round((thumbW - totalPillW) / 2)

        let retinaScale = NSScreen.main?.backingScaleFactor ?? 2.0
        for (i, (title, sel)) in pills.enumerated() {
            let pw = pillWidths[i]
            let pill = OverlayPillView(frame: NSRect(x: pillCursorX, y: pillY, width: pw, height: pillH))
            pill.attributedTitle = NSAttributedString(string: title, attributes: pillAttrs)
            pill.target = self
            pill.action = sel
            pill.layer?.contentsScale = retinaScale
            pill.layer?.cornerRadius = pillH / 2
            pill.layer?.cornerCurve = .continuous
            pill.layer?.backgroundColor = ShotnixColors.pillButtonBackground.cgColor
            controls.addSubview(pill)
            pillCursorX += pw + pillGap
        }

        controls.alphaValue = 0
        clipView.addSubview(controls)
        controlsOverlay = controls

        // Progress bar at the very bottom — thin, bright accent line
        let timeout = Settings.overlayTimeout
        if timeout > 0 {
            let progressBg = NSView(frame: NSRect(x: 0, y: 0, width: thumbW, height: progressH))
            progressBg.wantsLayer = true
            progressBg.layer?.backgroundColor = ShotnixColors.progressBackground.cgColor
            clipView.addSubview(progressBg)

            let progressFill = NSView(frame: progressBg.bounds)
            progressFill.wantsLayer = true
            progressFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            progressFill.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
            progressFill.layer?.position = CGPoint(x: 0, y: progressH / 2)
            progressBg.addSubview(progressFill)
            timeoutProgressLayer = progressFill.layer

            animateTimeoutProgress(duration: timeout)

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
            timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        } else {
            let remaining = Settings.overlayTimeout
            if remaining > 0 {
                animateTimeoutProgress(duration: remaining)
                dismissTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.animatedClose() }
                }
            }
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            controlsOverlay?.animator().alphaValue = hovered ? 1 : 0
        }
    }

    private func animateTimeoutProgress(duration: TimeInterval) {
        guard let layer = timeoutProgressLayer else { return }
        layer.removeAnimation(forKey: "timeoutProgress")
        layer.transform = CATransform3DIdentity
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = 1.0
        shrink.toValue = 0.0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "timeoutProgress")
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
    private var skipPolicyReset = false

    private func animatedClose() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            if let layer = self.contentView?.layer {
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.toValue = 0.95
                scaleAnim.duration = 0.12
                scaleAnim.fillMode = .forwards
                scaleAnim.isRemovedOnCompletion = false
                layer.add(scaleAnim, forKey: "exitScale")
            }
            
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
        // (skip when transitioning to another window like editor or pin)
        if QuickAccessWindow.openWindows.isEmpty && !skipPolicyReset {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    // MARK: – Actions

    @objc private func copyAction() {
        ImageExporter.copyToClipboard(image: image)
        showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
    }

    @objc private func saveAction() {
        ImageExporter.saveWithPanel(image: image, suggestedName: ImageExporter.timestampedName) { [weak self] success in
            if success {
                self?.showConfirmation(icon: "arrow.down.circle") { [weak self] in self?.animatedClose() }
            }
        }
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
        badge.layer?.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        clip.addSubview(badge)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            badge.animator().alphaValue = 1
            
            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.7
            scaleAnim.toValue = 1.0
            scaleAnim.duration = 0.12
            badge.layer?.add(scaleAnim, forKey: "pop")
            badge.layer?.transform = CATransform3DIdentity
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion()
            }
        })
    }

    @objc private func editAction() {
        skipPolicyReset = true
        animatedClose()
        // Open after a short delay so cleanup doesn't kill activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image, historyItem, historyManager] in
            AnnotationWindowController.open(image: image, historyItem: historyItem, historyManager: historyManager)
        }
    }

    @objc private func pinAction() {
        skipPolicyReset = true
        showConfirmation(icon: "pin") { [weak self] in
            guard let self else { return }
            self.animatedClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image = self.image] in
                PinnedWindow.pin(image: image)
            }
        }
    }

    @objc private func deleteAction() {
        historyManager.delete(historyItem)
        animatedClose()
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

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Shotnix.FilePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

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
        Self.queue
    }
}

// MARK: – Content view that accepts first mouse + right-click

@MainActor
private final class OverlayContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: – Corner button (glass circle, secondary action)

@MainActor
private final class OverlayCornerButton: NSButton {

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    // Let the first click land on the button even if the overlay window
    // isn't key yet — otherwise the first click just activates the window
    // and the user has to click twice for anything to happen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Suppress the default AppKit focus-ring line that paints under the
    // button when it becomes first responder.
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = ShotnixColors.cornerButtonHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = ShotnixColors.cornerButtonBackground.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = ShotnixColors.cornerButtonPressed.cgColor
        let scale = CATransform3DMakeScale(0.92, 0.92, 1)
        layer?.transform = scale
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.92
        spring.toValue = 1.0
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 15
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "bounceBack")
        layer?.transform = CATransform3DIdentity
        layer?.backgroundColor = isHovered
            ? ShotnixColors.cornerButtonHover.cgColor
            : ShotnixColors.cornerButtonBackground.cgColor
        super.mouseUp(with: event)
    }
}

// MARK: – Pill button (white capsule, primary action)

/// NSView-based pill with an NSTextField label. Uses color-only pressed
/// feedback — no CATransform3D scaling, which causes CoreAnimation to
/// rasterize the layer tree and pixelate text glyphs during the transform.
@MainActor
private final class OverlayPillView: NSView {

    var attributedTitle: NSAttributedString? {
        didSet {
            label.attributedStringValue = attributedTitle ?? NSAttributedString()
            needsLayout = true
        }
    }
    
    weak var target: AnyObject?
    var action: Selector?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    
    private let label: NSTextField

    override init(frame: NSRect) {
        label = NSTextField(labelWithString: "")
        super.init(frame: frame)
        wantsLayer = true
        
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let scale = window?.backingScaleFactor ?? 2.0
        let x = round((bounds.width - label.bounds.width) / 2 * scale) / scale
        let y = round((bounds.height - label.bounds.height) / 2 * scale) / scale
        label.setFrameOrigin(NSPoint(x: x, y: y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if !isPressed {
            layer?.backgroundColor = ShotnixColors.pillButtonHover.cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isPressed {
            layer?.backgroundColor = ShotnixColors.pillButtonBackground.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        // Color-only feedback: darken the pill, no scale transform.
        // This keeps text rendered live by AppKit at native Retina resolution
        // throughout the entire press cycle — zero pixelation, zero rasterization.
        layer?.backgroundColor = ShotnixColors.pillButtonPressed.cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        layer?.backgroundColor = isHovered
            ? ShotnixColors.pillButtonHover.cgColor
            : ShotnixColors.pillButtonBackground.cgColor

        // Fire target-action only if the mouse is still over us (iOS-style behaviour).
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let target = target, let action = action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }
}
