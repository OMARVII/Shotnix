import AppKit

enum SelectionMode { case area, window }

/// Full-screen translucent overlay that lets the user drag-select a region.
/// In `.window` mode it highlights the window under the cursor instead.
@MainActor
final class AreaSelectionWindow: NSObject {

    // Completion: selected rect in screen coordinates (AppKit, bottom-left), or nil if cancelled
    typealias Completion = (CGRect?, NSScreen) -> Void

    private let mode: SelectionMode
    private let completion: Completion
    private var overlays: [SelectionOverlayWindow] = []
    private var activeOverlay: SelectionOverlayWindow?

    init(mode: SelectionMode, completion: @escaping Completion) {
        self.mode = mode
        self.completion = completion
    }

    private var keyMonitor: Any?

    func show() {
        // LSUIElement apps are background processes — must activate before
        // showing any interactive window, otherwise makeKey() silently fails
        // and the overlay won't receive mouse drag events.
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(screen: screen, mode: mode)
            overlay.selectionHandler = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
            overlay.cancelHandler   = { [weak self] in self?.cancel() }
            overlay.show()
            overlays.append(overlay)
        }

        if let first = overlays.first {
            first.makeKeyAndOrderFront(nil)
            first.makeMain()
            first.makeFirstResponder(first.contentView)
        }

        // FIX 2: local key monitor as belt-and-suspenders — Escape always exits
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }

        NSCursor.crosshair.push()
    }

    private func finish(rect: CGRect, screen: NSScreen) {
        NSCursor.pop()
        tearDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.completion(rect, screen)
        }
    }

    func cancel() {
        NSCursor.pop()
        tearDown()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        completion(nil, screen)
    }

    private func tearDown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }
}

// MARK: – Overlay NSWindow

@MainActor
private final class SelectionOverlayWindow: NSWindow {

    var selectionHandler: ((CGRect) -> Void)?
    var cancelHandler: (() -> Void)?

    private let overlayView: SelectionOverlayView
    private let targetScreen: NSScreen
    private let mode: SelectionMode

    init(screen: NSScreen, mode: SelectionMode) {
        self.targetScreen = screen
        self.mode = mode
        self.overlayView = SelectionOverlayView(mode: mode)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.selectionHandler = { [weak self] rect in self?.selectionHandler?(rect) }
        overlayView.cancelHandler   = { [weak self] in self?.cancelHandler?() }
    }

    // Borderless windows return false by default — must override or makeKey() is ignored
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        orderFrontRegardless()
    }
}

// MARK: – Overlay NSView

@MainActor
private final class SelectionOverlayView: NSView {

    var selectionHandler: ((CGRect) -> Void)?
    var cancelHandler:    (() -> Void)?

    private let mode: SelectionMode
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var isSelecting = false

    // For area mode: track mouse position for crosshair before drag starts
    private var mousePosition: NSPoint?

    // For window mode
    private var highlightedWindowRect: NSRect?
    private var trackingArea: NSTrackingArea?

    init(mode: SelectionMode) {
        self.mode = mode
        super.init(frame: .zero)
        updateTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: – Drawing

    override func draw(_ dirtyRect: NSRect) {
        if mode == .window {
            // Window mode: dimmed background with cut-out for highlighted window
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath.fill(bounds)
            if let winRect = highlightedWindowRect {
                NSColor.clear.setFill()
                let path = NSBezierPath(rect: winRect)
                path.fill()
                NSColor.systemBlue.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        } else if isSelecting && !currentRect.isEmpty {
            // Area mode, during drag: dim outside selection, clear inside
            let outer = NSBezierPath(rect: bounds)
            let inner = NSBezierPath(rect: currentRect)
            outer.append(inner)
            outer.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.3).setFill()
            outer.fill()

            // Blue selection border
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: currentRect)
            border.lineWidth = 1.5
            border.stroke()

            drawMagnifier(near: currentRect)
            drawSizeLabel(for: currentRect)
        } else if mode == .area {
            // Area mode, pre-drag: near-invisible tint so macOS hit-tests this
            // region and delivers mouseDown. Fully clear windows pass clicks through.
            NSColor.black.withAlphaComponent(0.001).setFill()
            NSBezierPath.fill(bounds)
            if let pos = mousePosition {
                drawCrosshair(at: pos)
                drawCoordinateLabel(at: pos)
            }
        }
    }

    private func drawMagnifier(near rect: NSRect) {
        // Show pixel-accurate coordinates
        let label = String(format: "%.0f × %.0f", rect.width, rect.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 6)
        let bg = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: origin)
    }

    private func drawSizeLabel(for rect: NSRect) { /* included above */ }

    private func drawCrosshair(at point: NSPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Shadow line (dark, underneath) for contrast on light backgrounds
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.strokePath()

        // Primary line (white, on top)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(0.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.strokePath()
    }

    private func drawCoordinateLabel(at point: NSPoint) {
        guard let win = window else { return }
        // Convert view coordinates to screen coordinates for display
        let screenPoint = win.convertToScreen(NSRect(origin: point, size: .zero)).origin
        // Convert to top-left origin (Core Graphics) for user-facing display
        let screenHeight = win.screen?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let displayX = Int(screenPoint.x)
        let displayY = Int(screenHeight - screenPoint.y)

        let label = "\(displayX)\n\(displayY)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let padding: CGFloat = 6
        let offset: CGFloat = 15

        // Position label to bottom-right of cursor, clamped to view bounds
        var labelX = point.x + offset
        var labelY = point.y - offset - size.height - padding
        if labelX + size.width + padding * 2 > bounds.maxX {
            labelX = point.x - offset - size.width - padding * 2
        }
        if labelY < bounds.minY {
            labelY = point.y + offset
        }

        let bgRect = NSRect(x: labelX, y: labelY, width: size.width + padding * 2, height: size.height + padding)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: labelX + padding, y: labelY + padding * 0.5))
    }

    // MARK: – Mouse Events

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            if let r = highlightedWindowRect {
                selectionHandler?(r)
            }
            return
        }
        startPoint = event.locationInWindow
        isSelecting = true
        currentRect = .zero
        mousePosition = nil  // Hide crosshair once drag starts
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = startPoint else { return }
        let current = event.locationInWindow
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, isSelecting else { return }
        isSelecting = false
        if currentRect.width > 4 && currentRect.height > 4 {
            selectionHandler?(convertToScreen(currentRect))
        } else {
            // Tiny click / accidental tap — cancel cleanly; never leave overlay stuck
            cancelHandler?()
        }
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .window {
            highlightedWindowRect = windowRect(under: event.locationInWindow)
        } else if mode == .area && !isSelecting {
            mousePosition = event.locationInWindow
        }
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            cancelHandler?()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: – Helpers

    private func convertToScreen(_ rect: NSRect) -> CGRect {
        guard let win = window else { return rect }
        // Convert from view to window to screen
        let winRect = convert(rect, to: nil)
        let screenRect = win.convertToScreen(winRect)
        return screenRect
    }

    private func windowRect(under point: NSPoint) -> NSRect? {
        guard let win = window else { return nil }
        let screenPoint = win.convertToScreen(NSRect(origin: point, size: .zero)).origin
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windowList {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // CGWindowBounds uses top-left origin; convert to AppKit bottom-left
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let appKitRect = CGRect(
                x: bounds.origin.x,
                y: screenHeight - bounds.origin.y - bounds.height,
                width: bounds.width,
                height: bounds.height
            )
            if appKitRect.contains(screenPoint) {
                // Convert back to view coords for display
                let viewOrigin = win.convertFromScreen(NSRect(origin: appKitRect.origin, size: .zero)).origin
                return NSRect(origin: viewOrigin, size: appKitRect.size)
            }
        }
        return nil
    }
}
