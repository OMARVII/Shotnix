import AppKit

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
    private let historyItem: HistoryItem
    private let historyManager: HistoryManager
    private let image: NSImage

    init(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager

        let thumbW: CGFloat = 240
        let aspect = image.size.height / max(image.size.width, 1)
        let thumbH: CGFloat = min(thumbW * aspect, 160)
        let buttonRowH: CGFloat = 36
        let padding: CGFloat = 8
        let totalH = thumbH + buttonRowH + padding * 2

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: thumbW + padding * 2, height: totalH),
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

        buildContent(thumbW: thumbW, thumbH: thumbH, buttonRowH: buttonRowH, padding: padding, totalH: totalH)
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
            if self.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    NSApp.activate(ignoringOtherApps: true)
                    self.makeKeyAndOrderFront(nil)
                    self.makeFirstResponder(self)
                }
            }
        }

        // Local mouse: keeps window key while hovering (when app IS active)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            if self.frame.contains(NSEvent.mouseLocation) && !self.isKeyWindow {
                self.makeKey()
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
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

    private func buildContent(thumbW: CGFloat, thumbH: CGFloat, buttonRowH: CGFloat, padding: CGFloat, totalH: CGFloat) {
        let container = OverlayContentView(frame: NSRect(x: 0, y: 0, width: thumbW + padding * 2, height: totalH))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        contentView = container

        // Draggable thumbnail — drag to Finder/apps, double-click to annotate
        let thumbFrame = NSRect(x: padding, y: buttonRowH + padding, width: thumbW, height: thumbH)
        let thumb = DraggableImageView(frame: thumbFrame)
        thumb.image = image
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.dragImage = image
        thumb.onDoubleClick = { [weak self] in self?.editAction() }
        thumb.onDragStarted = { [weak self] in self?.dismissTimer?.invalidate() }
        thumb.onDragCompleted = { [weak self] in self?.animatedClose() }
        container.addSubview(thumb)

        // Progress bar — only shown when auto-dismiss is active
        let timeout = Settings.overlayTimeout
        if timeout > 0 {
            let progressBg = NSView(frame: NSRect(x: padding, y: buttonRowH + padding - 3, width: thumbW, height: 2))
            progressBg.wantsLayer = true
            progressBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            container.addSubview(progressBg)

            let progressFill = NSView(frame: progressBg.bounds)
            progressFill.wantsLayer = true
            progressFill.layer?.backgroundColor = NSColor.systemBlue.cgColor
            progressBg.addSubview(progressFill)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = timeout
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                progressFill.animator().frame = NSRect(x: 0, y: 0, width: 0, height: 2)
            })

            dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.animatedClose() }
            }
        }

        // Buttons
        let actions: [(String, String, Selector)] = [
            ("doc.on.clipboard",      "Copy",    #selector(copyAction)),
            ("square.and.arrow.down", "Save",    #selector(saveAction)),
            ("pencil",                "Edit",    #selector(editAction)),
            ("pin",                   "Pin",     #selector(pinAction)),
            ("xmark",                 "Close",   #selector(dismissAction)),
        ]
        let btnW = (thumbW + padding * 2) / CGFloat(actions.count)
        for (i, (icon, tooltip, sel)) in actions.enumerated() {
            let btn = HoverButton(frame: NSRect(x: CGFloat(i) * btnW, y: 1, width: btnW, height: buttonRowH - 2))
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.toolTip = tooltip
            btn.target = self
            btn.action = sel
            btn.imageScaling = .scaleProportionallyDown
            btn.contentTintColor = .secondaryLabelColor
            container.addSubview(btn)
        }
    }

    private func positionOverlay() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let x: CGFloat
        if Settings.overlayOnLeft {
            x = screen.visibleFrame.minX + margin
        } else {
            x = screen.visibleFrame.maxX - frame.width - margin
        }
        let y = screen.visibleFrame.minY + margin
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

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 1
        }
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
        animatedClose()
    }

    @objc private func saveAction() {
        ImageExporter.saveWithPanel(image: image, suggestedName: "Shotnix-\(Date().formatted(.iso8601.year().month().day()))")
        animatedClose()
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
        let ts = ISO8601DateFormatter()
        ts.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let name = ts.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "Shotnix-\(name).png"
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
private final class OverlayContentView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: – Hover button with tint change

@MainActor
private final class HoverButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}
