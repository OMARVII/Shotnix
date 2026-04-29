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

    func prepareAndShow(engine: CaptureEngine) async {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        // Capture all screens concurrently for speed
        await withTaskGroup(of: (NSScreen, CGImage?).self) { group in
            for screen in NSScreen.screens {
                group.addTask {
                    let image = await engine.captureRectToImage(screen.frame, on: screen)
                    var r = NSRect(origin: .zero, size: screen.frame.size)
                    let cg = image?.cgImage(forProposedRect: &r, context: nil, hints: nil)
                    return (screen, cg)
                }
            }
            
            for await (screen, frozenCG) in group {
                let overlay = SelectionOverlayWindow(screen: screen, mode: self.mode, frozenImage: frozenCG)
                overlay.selectionHandler = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
                overlay.cancelHandler   = { [weak self] in self?.cancel() }
                overlay.show()
                self.overlays.append(overlay)
            }
        }

        focusFirstOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusFirstOverlay()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusFirstOverlay()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }

        NSCursor.crosshair.push()
    }
    private func focusFirstOverlay() {
        guard !overlays.isEmpty, let first = overlays.first else { return }
        guard first.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        first.makeKeyAndOrderFront(nil)
        first.makeMain()
        first.makeFirstResponder(first.contentView)
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
        // Restore background-only policy
        NSApp.setActivationPolicy(.prohibited)
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

    init(screen: NSScreen, mode: SelectionMode, frozenImage: CGImage?) {
        self.targetScreen = screen
        self.mode = mode
        self.overlayView = SelectionOverlayView(mode: mode, frozenImage: frozenImage)
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
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.selectionHandler = { [weak self] rect in self?.selectionHandler?(rect) }
        overlayView.cancelHandler   = { [weak self] in self?.cancelHandler?() }
    }
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
    private var cachedWindowRects: [NSRect] = []
    private var lastWindowListRefresh: TimeInterval = 0

    private let frozenImage: CGImage?

    init(mode: SelectionMode, frozenImage: CGImage?) {
        self.mode = mode
        self.frozenImage = frozenImage
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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

            // Subtle rule-of-thirds grid for premium framing (like CleanShot X)
            if currentRect.width > 50 && currentRect.height > 50 {
                NSColor.white.withAlphaComponent(0.25).setStroke()
                let grid = NSBezierPath()
                let w3 = currentRect.width / 3
                let h3 = currentRect.height / 3
                grid.move(to: NSPoint(x: currentRect.minX + w3, y: currentRect.minY))
                grid.line(to: NSPoint(x: currentRect.minX + w3, y: currentRect.maxY))
                grid.move(to: NSPoint(x: currentRect.minX + w3 * 2, y: currentRect.minY))
                grid.line(to: NSPoint(x: currentRect.minX + w3 * 2, y: currentRect.maxY))
                grid.move(to: NSPoint(x: currentRect.minX, y: currentRect.minY + h3))
                grid.line(to: NSPoint(x: currentRect.maxX, y: currentRect.minY + h3))
                grid.move(to: NSPoint(x: currentRect.minX, y: currentRect.minY + h3 * 2))
                grid.line(to: NSPoint(x: currentRect.maxX, y: currentRect.minY + h3 * 2))
                grid.lineWidth = 1.0
                grid.stroke()
            }

            drawCornerHandles(for: currentRect)
            drawDimensionLabel(near: currentRect)
            // No loupe during drag: CGWindowListCreateImage is a synchronous
            // main-thread screen capture per frame, which trails behind the
            // cursor and paints dark-circle artifacts along the drag path.
            // Dimension label + corner handles are the more useful feedback
            // while the rect is being sized, matching CleanShot X.
        } else if mode == .area {
            // Area mode, pre-drag: near-invisible tint so macOS hit-tests this
            // region and delivers mouseDown. Fully clear windows pass clicks through.
            NSColor.black.withAlphaComponent(0.001).setFill()
            NSBezierPath.fill(bounds)
            if let pos = mousePosition {
                drawCrosshair(at: pos)
                drawCoordinateLabel(at: pos)
                drawMagnifierLoupe(at: pos)
            }
        }
    }

    // MARK: – Magnifier Loupe

    private func drawMagnifierLoupe(at point: NSPoint) {
        guard let window = window else { return }
        
        // Convert cursor point to the AppKit screen coordinate space
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin

        // Capture region: 24x24 pixels around cursor
        let captureSize: CGFloat = 24
        
        // Use the frozen screen image to get pixels instantly!
        // The frozenImage is full-screen, top-left origin (CoreGraphics standard).
        // screenPoint.y is AppKit bottom-left, so we must invert it to sample the CGImage.
        let screenHeight = window.screen?.frame.height ?? bounds.height
        let cgY = screenHeight - screenPoint.y
        
        let captureRect = CGRect(
            x: screenPoint.x - captureSize / 2,
            y: cgY - captureSize / 2,
            width: captureSize,
            height: captureSize
        )

        guard let cgImage = frozenImage?.cropping(to: captureRect) else { return }
        let loupeSize: CGFloat = 120
        let offset: CGFloat = 20

        // Position: offset from cursor, flip to other side near edges
        var loupeX = point.x + offset
        var loupeY = point.y + offset
        if loupeX + loupeSize > bounds.maxX - 10 {
            loupeX = point.x - offset - loupeSize
        }
        if loupeY + loupeSize > bounds.maxY - 10 {
            loupeY = point.y - offset - loupeSize
        }

        let loupeRect = NSRect(x: loupeX, y: loupeY, width: loupeSize, height: loupeSize)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        // Clip to circle
        let clipPath = CGPath(ellipseIn: loupeRect, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()

        // Dark background behind the magnified pixels
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fill(loupeRect)

        // Draw magnified image with nearest-neighbor interpolation for crisp pixels
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: loupeRect)

        // Pixel grid overlay
        let pixelSize = loupeSize / captureSize
        if pixelSize > 4 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.setLineWidth(0.5)
            for i in 0...Int(captureSize) {
                let x = loupeRect.minX + CGFloat(i) * pixelSize
                ctx.move(to: CGPoint(x: x, y: loupeRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: loupeRect.maxY))
                let y = loupeRect.minY + CGFloat(i) * pixelSize
                ctx.move(to: CGPoint(x: loupeRect.minX, y: y))
                ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: y))
            }
            ctx.strokePath()
        }

        // Center crosshair
        let cx = loupeRect.midX, cy = loupeRect.midY
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: cx - 6, y: cy))
        ctx.addLine(to: CGPoint(x: cx + 6, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - 6))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 6))
        ctx.strokePath()

        ctx.restoreGState()

        // Circular border (drawn outside the clip)
        let borderPath = NSBezierPath(ovalIn: loupeRect.insetBy(dx: 0.75, dy: 0.75))
        NSColor.white.withAlphaComponent(0.4).setStroke()
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        // Shadow ring for depth
        let shadowPath = NSBezierPath(ovalIn: loupeRect.insetBy(dx: -1, dy: -1))
        NSColor.black.withAlphaComponent(0.3).setStroke()
        shadowPath.lineWidth = 2.0
        shadowPath.stroke()

        // Pixel color hex label below the loupe
        drawColorLabel(for: cgImage, below: loupeRect)
    }

    private func drawColorLabel(for image: CGImage, below loupeRect: NSRect) {
        // Sample the center pixel of the captured image
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return }
        let centerX = w / 2, centerY = h / 2

        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return }

        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return }

        let offset = centerY * bytesPerRow + centerX * bytesPerPixel
        guard offset + 2 < CFDataGetLength(data) else { return }

        // Pixel order depends on bitmap info; most CG captures are BGRA or RGBA
        let alphaInfo = image.alphaInfo
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let r: UInt8, g: UInt8, b: UInt8
        if byteOrder == .byteOrder32Little {
            // BGRA layout
            b = ptr[offset]
            g = ptr[offset + 1]
            r = ptr[offset + 2]
        } else {
            // RGBA layout
            r = ptr[offset]
            g = ptr[offset + 1]
            b = ptr[offset + 2]
        }
        _ = alphaInfo // silence unused warning

        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: hex, attributes: attrs)
        let size = str.size()
        let pillX = loupeRect.midX - (size.width + 12) / 2
        let pillY = loupeRect.minY - size.height - 10
        let pillRect = NSRect(x: pillX, y: pillY, width: size.width + 12, height: size.height + 6)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: pillX + 6, y: pillY + 3))
    }

    // MARK: – Corner Handles

    private func drawCornerHandles(for rect: NSRect) {
        let handleLen: CGFloat = 8
        let handleWidth: CGFloat = 2.5
        NSColor.white.setStroke()

        let corners: [(NSPoint, [(CGFloat, CGFloat)])] = [
            (NSPoint(x: rect.minX, y: rect.minY), [(0, handleLen), (handleLen, 0)]),
            (NSPoint(x: rect.maxX, y: rect.minY), [(0, handleLen), (-handleLen, 0)]),
            (NSPoint(x: rect.minX, y: rect.maxY), [(0, -handleLen), (handleLen, 0)]),
            (NSPoint(x: rect.maxX, y: rect.maxY), [(0, -handleLen), (-handleLen, 0)]),
        ]

        for (origin, offsets) in corners {
            let path = NSBezierPath()
            path.lineWidth = handleWidth
            path.lineCapStyle = .round
            for (dx, dy) in offsets {
                path.move(to: origin)
                path.line(to: NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
            path.stroke()
        }
    }

    // MARK: – Dimension Label

    private func drawDimensionLabel(near rect: NSRect) {
        let label = String(format: "%.0f \u{00D7} %.0f", rect.width, rect.height)
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
        // Convert to top-left origin (Core Graphics) for user-facing display.
        // CG global coords are anchored to the primary display — use screens[0].
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
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
        // Safety net: if window isn't key (activation race on first capture),
        // force it now so the subsequent drag events are delivered here.
        if let win = window, !win.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(self)
        }

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
        let previousRect = currentRect
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        // First drag frame: pre-drag branch only painted a near-clear tint
        // across the screen, so we need a full-screen redraw to establish the
        // 0.3 dim everywhere and punch out the selection. After that, only
        // the diff between old and new rects (plus margin for border, corner
        // handles, and the dimension label above) actually changed — the rest
        // of the dim region is already correct on the layer's backing store.
        let margin: CGFloat = 32
        if previousRect.isEmpty {
            setNeedsDisplay(bounds)
        } else {
            setNeedsDisplay(previousRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
            setNeedsDisplay(currentRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, isSelecting else { return }
        isSelecting = false
        if currentRect.width > 4 && currentRect.height > 4 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            selectionHandler?(convertToScreen(currentRect))
        } else {
            // Tiny click / accidental tap — cancel cleanly; never leave overlay stuck
            cancelHandler?()
        }
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .window {
            let previous = highlightedWindowRect
            highlightedWindowRect = windowRect(under: event.locationInWindow)
            if previous != highlightedWindowRect {
                invalidateWindowHighlight(from: previous, to: highlightedWindowRect)
            }
        } else if mode == .area && !isSelecting {
            // Invalidate every artifact we paint around the cursor at both
            // the previous and new positions: crosshair strips (full-screen
            // lines), the loupe (120px + shadow/border, flips left or right
            // and up or down near screen edges), the hex color pill below
            // the loupe, and the coordinate label offset from the cursor.
            if let old = mousePosition {
                invalidateCursorArtifacts(at: old)
            }
            mousePosition = event.locationInWindow
            invalidateCursorArtifacts(at: mousePosition!)
        } else {
            setNeedsDisplay(bounds)
        }
    }

    private func invalidateWindowHighlight(from oldRect: NSRect?, to newRect: NSRect?) {
        let padding: CGFloat = 8
        if let oldRect {
            setNeedsDisplay(oldRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
        if let newRect {
            setNeedsDisplay(newRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
    }

    /// Repaints the narrow crosshair strips plus a generous box around the
    /// cursor that fully contains the loupe (on either side), the hex color
    /// pill, and the coordinate label. Tuned so no leftover pixels trail the
    /// pointer when the mouse moves fast.
    private func invalidateCursorArtifacts(at point: NSPoint) {
        // Crosshair lines span the whole view; invalidate a thin strip on each axis.
        let strip: CGFloat = 4
        setNeedsDisplay(NSRect(x: 0, y: point.y - strip / 2, width: bounds.width, height: strip))
        setNeedsDisplay(NSRect(x: point.x - strip / 2, y: 0, width: strip, height: bounds.height))

        // Loupe (120) + 20 offset + margin for shadow/border/pill/coord label in any quadrant.
        let halo: CGFloat = 190
        let haloRect = NSRect(
            x: point.x - halo,
            y: point.y - halo,
            width: halo * 2,
            height: halo * 2
        ).intersection(bounds)
        setNeedsDisplay(haloRect)
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
        refreshWindowRectsIfNeeded()
        for appKitRect in cachedWindowRects where appKitRect.contains(screenPoint) {
            let viewOrigin = win.convertFromScreen(NSRect(origin: appKitRect.origin, size: .zero)).origin
            return NSRect(origin: viewOrigin, size: appKitRect.size)
        }
        return nil
    }

    private func refreshWindowRectsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowListRefresh > 0.15 else { return }
        lastWindowListRefresh = now
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        cachedWindowRects = windowList.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            return CGRect(
                x: bounds.origin.x,
                y: screenHeight - bounds.origin.y - bounds.height,
                width: bounds.width,
                height: bounds.height
            )
        }
    }

}
