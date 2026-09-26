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

    /// In `.window` mode: the CGWindowID of the clicked window, set just
    /// before the completion fires. Enables isolated single-window capture.
    private(set) var selectedWindowID: CGWindowID?

    init(mode: SelectionMode, completion: @escaping Completion) {
        self.mode = mode
        self.completion = completion
    }

    private var keyMonitor: Any?

    func prepareAndShow(engine: CaptureEngine) async {
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)

        // Show the overlays IMMEDIATELY — the crosshair must never wait on a
        // screenshot. The frozen per-screen images only feed the loupe and hex
        // readout, so they load in the background and the loupe appears a beat
        // later; everything else (crosshair, drag, dimension label) is instant.
        let screens = NSScreen.screens
        for screen in screens {
            let overlay = SelectionOverlayWindow(screen: screen, mode: mode, frozenImage: nil)
            overlay.selectionHandler = { [weak self] rect, windowID in
                self?.selectedWindowID = windowID
                self?.finish(rect: rect, screen: screen)
            }
            overlay.cancelHandler = { [weak self] in self?.cancel() }
            // One selection at a time: starting one on this display drops an
            // adjustable selection left on another.
            overlay.selectionBeganHandler = { [weak self, weak overlay] in
                self?.overlays.filter { $0 !== overlay }.forEach { $0.resetSelection() }
            }
            overlay.show()
            overlays.append(overlay)
        }

        // Window mode never uses the frozen images — skip the captures entirely.
        if mode == .area {
            for (screen, overlay) in zip(screens, overlays) {
                Task { @MainActor [weak overlay] in
                    let image = await engine.captureRectToImage(screen.frame, on: screen)
                    var rect = NSRect(origin: .zero, size: screen.frame.size)
                    let frozenCG = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    overlay?.updateFrozenImage(frozenCG)
                }
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
        // push() alone can be overridden by the cursor rect that was active
        // under the mouse when the overlay appeared; set() applies it NOW.
        NSCursor.crosshair.set()
    }
    private func focusFirstOverlay() {
        guard !overlays.isEmpty, let first = overlays.first else { return }
        guard first.isVisible else { return }
        // A selection being adjusted on another display keeps the keyboard.
        guard !overlays.contains(where: { $0.isKeyWindow && $0 !== first }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        first.makeKeyAndOrderFront(nil)
        first.makeMain()
        first.makeFirstResponder(first.contentView)
    }

    private func finish(rect: CGRect, screen: NSScreen) {
        NSCursor.pop()
        tearDown()
        if #available(macOS 14.0, *) {
            // SCK captures exclude Shotnix's own windows, so there's no need
            // to wait for the dimming overlay to leave the compositor —
            // fire on the next runloop tick and shave ~80ms off the shutter.
            // Local copy: the completion releases self (engine drops its ref).
            let completion = completion
            DispatchQueue.main.async { completion(rect, screen) }
        } else {
            // The CGWindowList fallback would catch the overlay — give the
            // orderOut a beat to land before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.completion(rect, screen)
            }
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
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }
}

// MARK: – Overlay NSWindow

@MainActor
private final class SelectionOverlayWindow: NSWindow {

    var selectionHandler: ((CGRect, CGWindowID?) -> Void)?
    var cancelHandler: (() -> Void)?
    var selectionBeganHandler: (() -> Void)?

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
        overlayView.selectionHandler = { [weak self] rect, windowID in self?.selectionHandler?(rect, windowID) }
        overlayView.cancelHandler   = { [weak self] in self?.cancelHandler?() }
        overlayView.selectionBeganHandler = { [weak self] in self?.selectionBeganHandler?() }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        orderFrontRegardless()
        // Feedback must not wait for the first mouse move: draw the crosshair
        // (or window highlight) at the CURRENT cursor position right away, and
        // register a cursor rect so the pointer becomes a crosshair while the
        // mouse is still stationary.
        overlayView.primeInitialMouseState()
        invalidateCursorRects(for: overlayView)
    }

    /// The loupe's pixel source arrives asynchronously after the overlay is
    /// already on screen — swap it in and repaint if the loupe is visible.
    func updateFrozenImage(_ image: CGImage?) {
        overlayView.updateFrozenImage(image)
    }

    func resetSelection() {
        overlayView.resetSelection()
    }
}

// MARK: – Overlay NSView

/// Drag to select. By default the capture happens on release; with
/// "Capture immediately after selecting" off — or ⇧ held as the mouse is
/// released, which flips the setting for one capture — the selection stays
/// on screen to adjust: drag edges and corners, drag inside to move, arrow
/// keys nudge (⇧ ×10), Return or the Capture button captures, Esc cancels.
@MainActor
final class SelectionOverlayView: NSView {

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    enum Stage: Equatable {
        case idle
        case drawing
        case adjusting
        case resizing(Handle)
        case moving
    }

    var selectionHandler: ((CGRect, CGWindowID?) -> Void)?
    var cancelHandler:    (() -> Void)?
    var selectionBeganHandler: (() -> Void)?

    /// Capture on release, or keep the selection adjustable (see type docs).
    var captureImmediately = Settings.captureImmediatelyAfterSelecting

    private let mode: SelectionMode
    private(set) var stage: Stage = .idle
    private var startPoint: NSPoint?
    private(set) var currentRect: NSRect = .zero

    // For area mode: track mouse position for crosshair before drag starts
    private var mousePosition: NSPoint?

    // For window mode
    private var highlightedWindowRect: NSRect?
    private var highlightedWindowID: CGWindowID?
    private var trackingArea: NSTrackingArea?
    private var cachedWindows: [(rect: NSRect, windowID: CGWindowID)] = []
    private var lastWindowListRefresh: TimeInterval = 0

    // Space-drag: holding space while dragging moves the selection instead of
    // resizing it (matches the native macOS screenshot behavior).
    private var isSpaceDown = false
    private var lastDragPoint: NSPoint?

    // Adjusting: the rect when a handle/move drag began, and where the
    // pointer grabbed it.
    private var dragStartRect: NSRect = .zero
    private var dragStartPoint: NSPoint = .zero
    /// The selection a click outside it was about to replace — restored when
    /// that click turns out to be a plain click, not a new drag.
    private var replacedSelection: NSRect?

    /// ⇧ still held from the capture shortcut (⌘⇧4…) doesn't count as the
    /// adjust modifier until it has been released once.
    var shiftHeldSinceStart = false

    /// Only the display with the pointer shows the hint line.
    private var showsHint = false

    private var frozenImage: CGImage?

    static let minimumSize: CGFloat = 5
    private static let handleSize: CGFloat = 9
    private static let handleHitRadius: CGFloat = 10

    init(mode: SelectionMode, frozenImage: CGImage?) {
        self.mode = mode
        self.frozenImage = frozenImage
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        updateTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(mode == .window ? "Window capture" : "Screenshot selection")
        setAccessibilityHelp(hintText)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    func updateFrozenImage(_ image: CGImage?) {
        frozenImage = image
        // Loupe pixels just became available — paint it at the current cursor.
        if let position = mousePosition {
            invalidateCursorArtifacts(at: position)
        }
    }

    /// Drops any selection on this display (another display started one).
    func resetSelection() {
        guard stage != .idle || !currentRect.isEmpty else { return }
        stage = .idle
        currentRect = .zero
        startPoint = nil
        replacedSelection = nil
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(bounds)
    }

    /// AppKit keeps the pointer a crosshair over the overlay even while the
    /// mouse hasn't moved yet — a pushed NSCursor alone gets overridden by
    /// whatever cursor rect was active when the overlay appeared.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
        guard stage == .adjusting else { return }
        addCursorRect(currentRect, cursor: .openHand)
        for handle in Handle.allCases {
            addCursorRect(handleHitRect(handle, in: currentRect), cursor: Self.cursor(for: handle))
        }
        addCursorRect(confirmButtonRect(for: currentRect), cursor: .pointingHand)
    }

    /// Renders feedback for the mouse's CURRENT position the moment the
    /// overlay appears. Testers pressed the hotkey, saw nothing change, and
    /// assumed capture hadn't started — the crosshair and window highlight
    /// only initialized from mouse-MOVE events.
    func primeInitialMouseState() {
        shiftHeldSinceStart = NSEvent.modifierFlags.contains(.shift)
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        // Overlays exist per display; only the one under the mouse paints.
        guard window.frame.contains(screenPoint) else { return }
        let viewPoint = window.convertPoint(fromScreen: screenPoint)
        showsHint = true
        setNeedsDisplay(hintRect())

        if mode == .area {
            mousePosition = viewPoint
            invalidateCursorArtifacts(at: viewPoint)
        } else {
            let hit = windowUnder(viewPoint)
            highlightedWindowRect = hit?.rect
            highlightedWindowID = hit?.windowID
            invalidateWindowHighlight(from: nil, to: highlightedWindowRect)
        }
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
        } else if stage != .idle && !currentRect.isEmpty {
            // Area mode, selecting: dim outside selection, clear inside
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

            // Subtle rule-of-thirds grid for premium framing
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

            if stage == .drawing {
                drawCornerHandles(for: currentRect)
            } else {
                drawResizeHandles(for: currentRect)
                drawConfirmButton(for: currentRect)
            }
            drawDimensionLabel(near: currentRect)
            // No loupe while drawing: dimension label + corner handles are
            // the more useful feedback while the rect is being sized. While
            // an edge is dragged, the loupe helps land it on the right pixel.
            if case .resizing = stage, let position = mousePosition {
                drawMagnifierLoupe(at: position)
            }
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
        if showsHint {
            drawHint()
        }
    }

    // MARK: – Hint line

    /// Says what a release will do — and how to get the other behavior.
    var hintText: String {
        if mode == .window {
            return "Click a window to capture it  ·  Esc cancels"
        }
        switch stage {
        case .adjusting, .resizing, .moving:
            return "Drag edges or corners to resize  ·  Arrow keys nudge (⇧ ×10)  ·  Return captures  ·  Esc cancels"
        case .idle, .drawing:
            return captureImmediately
                ? "Drag to capture  ·  Hold ⇧ as you let go to adjust first  ·  Space moves  ·  Esc cancels"
                : "Drag to select, then adjust  ·  Hold ⇧ as you let go to capture right away  ·  Esc cancels"
        }
    }

    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]

    /// Bottom center, or top center when the pointer or selection is near it.
    private func hintRect() -> NSRect {
        let size = (hintText as NSString).size(withAttributes: Self.hintAttributes)
        let width = ceil(size.width) + 28
        let height = ceil(size.height) + 14
        let bottom = NSRect(x: (bounds.midX - width / 2).rounded(), y: bounds.minY + 36, width: width, height: height)
        let avoid = bottom.insetBy(dx: -24, dy: -60)
        let crowded = (mousePosition.map { avoid.contains($0) } ?? false)
            || (stage != .idle && currentRect.intersects(avoid))
        guard crowded else { return bottom }
        return NSRect(x: bottom.minX, y: bounds.maxY - 64 - height, width: width, height: height)
    }

    private func drawHint() {
        let rect = hintRect()
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let size = (hintText as NSString).size(withAttributes: Self.hintAttributes)
        (hintText as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: Self.hintAttributes
        )
    }

    // MARK: – Magnifier Loupe

    private func drawMagnifierLoupe(at point: NSPoint) {
        guard let window = window, let frozenImage = frozenImage else { return }

        // Convert cursor point to the AppKit screen coordinate space
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin

        // The frozen image covers only THIS screen, so sample in screen-local
        // coordinates — subtract the screen's global origin (nonzero on
        // secondary displays).
        let screenFrame = window.screen?.frame ?? NSRect(origin: .zero, size: bounds.size)
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        let localX = screenPoint.x - screenFrame.origin.x
        let localY = screenPoint.y - screenFrame.origin.y

        // The frozen image is at the display's pixel resolution (2x on Retina,
        // 1x on non-Retina panels). Derive the true pixel-per-point scale from
        // the image itself instead of assuming a backing factor.
        let scaleX = CGFloat(frozenImage.width) / screenFrame.width
        let scaleY = CGFloat(frozenImage.height) / screenFrame.height

        // Capture region: 24x24 device pixels around cursor, so the loupe's
        // per-pixel magnification (and the pixel grid) is identical on Retina
        // and non-Retina displays.
        let captureSize: CGFloat = 24

        // Use the frozen screen image to get pixels instantly!
        // The frozenImage is top-left origin (CoreGraphics standard); localY is
        // AppKit bottom-left, so invert within the screen, then scale to pixels.
        let pixelX = localX * scaleX
        let pixelY = (screenFrame.height - localY) * scaleY

        let captureRect = CGRect(
            x: pixelX - captureSize / 2,
            y: pixelY - captureSize / 2,
            width: captureSize,
            height: captureSize
        )

        guard let cgImage = frozenImage.cropping(to: captureRect) else { return }
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

        // Pixel grid overlay — one cell per device pixel in the crop
        let pixelColumns = max(cgImage.width, 1)
        let pixelSize = loupeSize / CGFloat(pixelColumns)
        if pixelSize > 4 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.setLineWidth(0.5)
            for i in 0...pixelColumns {
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
        guard offset + bytesPerPixel <= CFDataGetLength(data) else { return }

        // Component order depends on BOTH alpha placement and byte order:
        // SCK frames are typically BGRA (alpha-first, 32-bit little-endian),
        // CGWindowList captures can be ARGB (alpha-first, big-endian).
        let alphaInfo = image.alphaInfo
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first
            || alphaInfo == .noneSkipFirst
        let r: UInt8, g: UInt8, b: UInt8
        if bytesPerPixel >= 4 {
            if byteOrder == .byteOrder32Little {
                if alphaFirst {
                    // ARGB read little-endian → BGRA in memory
                    b = ptr[offset]
                    g = ptr[offset + 1]
                    r = ptr[offset + 2]
                } else {
                    // RGBA read little-endian → ABGR in memory
                    b = ptr[offset + 1]
                    g = ptr[offset + 2]
                    r = ptr[offset + 3]
                }
            } else {
                if alphaFirst {
                    // ARGB in memory (big-endian / host default)
                    r = ptr[offset + 1]
                    g = ptr[offset + 2]
                    b = ptr[offset + 3]
                } else {
                    // RGBA in memory
                    r = ptr[offset]
                    g = ptr[offset + 1]
                    b = ptr[offset + 2]
                }
            }
        } else {
            // 24-bit RGB, no alpha channel
            r = ptr[offset]
            g = ptr[offset + 1]
            b = ptr[offset + 2]
        }

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

    /// Adjust stage: eight grabbable square handles.
    private func drawResizeHandles(for rect: NSRect) {
        for handle in Handle.allCases {
            let center = handleCenter(handle, in: rect)
            let size = Self.handleSize
            let square = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: square.insetBy(dx: -1, dy: -1), xRadius: 2.5, yRadius: 2.5).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private static let confirmAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    private static let confirmTitle = "Capture  ⏎"

    /// Under the selection, or inside its bottom edge when there's no room.
    func confirmButtonRect(for rect: NSRect) -> NSRect {
        let size = (Self.confirmTitle as NSString).size(withAttributes: Self.confirmAttributes)
        let width = ceil(size.width) + 26
        let height: CGFloat = 28
        let x = min(max(rect.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
        var y = rect.minY - height - 10
        if y < bounds.minY + 8 {
            y = rect.minY + 10
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    private func drawConfirmButton(for rect: NSRect) {
        let button = confirmButtonRect(for: rect)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: button, xRadius: button.height / 2, yRadius: button.height / 2).fill()
        let size = (Self.confirmTitle as NSString).size(withAttributes: Self.confirmAttributes)
        (Self.confirmTitle as NSString).draw(
            at: NSPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2),
            withAttributes: Self.confirmAttributes
        )
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
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 6)
        // At the top of the screen the label moves inside the selection.
        if origin.y + size.height + 3 > bounds.maxY {
            origin.y = rect.maxY - size.height - 9
        }
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
                // Convert to global AppKit coordinates — view-local rects are
                // only correct on the primary display (screen origin 0,0).
                selectionHandler?(convertToScreen(r), highlightedWindowID)
            }
            return
        }

        let point = clamped(event.locationInWindow)
        showsHint = true
        if stage == .adjusting {
            if confirmButtonRect(for: currentRect).contains(point)
                || (event.clickCount == 2 && currentRect.contains(point)) {
                commitSelection()
                return
            }
            if let handle = handle(at: point) {
                beginAdjustDrag(.resizing(handle), at: point)
                return
            }
            if currentRect.contains(point) {
                beginAdjustDrag(.moving, at: point)
                return
            }
            // Outside: start over — unless this turns out to be a plain click.
            replacedSelection = currentRect
        } else {
            replacedSelection = nil
        }

        startPoint = point
        lastDragPoint = point
        stage = .drawing
        currentRect = .zero
        mousePosition = nil  // Hide crosshair once drag starts
        selectionBeganHandler?()
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(bounds)
    }

    private func beginAdjustDrag(_ newStage: Stage, at point: NSPoint) {
        stage = newStage
        dragStartRect = currentRect
        dragStartPoint = point
        mousePosition = point
        if newStage == .moving { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        // A drag never leaves this display: the other screen's pixels aren't
        // in this capture, and would come back black.
        let current = clamped(event.locationInWindow)
        let previousRect = currentRect
        switch stage {
        case .drawing:
            guard let start = startPoint else { return }
            if isSpaceDown, !currentRect.isEmpty, let last = lastDragPoint {
                // Space held: translate the whole selection by the cursor delta,
                // and shift the anchor with it so releasing space resumes resizing
                // from the moved rect.
                let moved = keptInBounds(currentRect.offsetBy(dx: current.x - last.x, dy: current.y - last.y))
                startPoint = NSPoint(x: start.x + moved.minX - currentRect.minX, y: start.y + moved.minY - currentRect.minY)
                currentRect = moved
            } else {
                currentRect = NSRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
            }
            lastDragPoint = current
        case .resizing(let handle):
            currentRect = resized(dragStartRect, handle: handle, to: current)
            mousePosition = current
        case .moving:
            currentRect = keptInBounds(dragStartRect.offsetBy(dx: current.x - dragStartPoint.x, dy: current.y - dragStartPoint.y))
        case .idle, .adjusting:
            return
        }
        invalidateSelectionChange(from: previousRect, to: currentRect)
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        switch stage {
        case .drawing:
            if currentRect.width > 4 && currentRect.height > 4 {
                if wantsAdjustStage(releasedWith: event.modifierFlags) {
                    enterAdjustStage()
                } else {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    selectionHandler?(convertToScreen(currentRect), nil)
                }
            } else if let previous = replacedSelection {
                // A plain click beside an adjustable selection keeps it.
                currentRect = previous
                enterAdjustStage()
            } else {
                // Tiny click / accidental tap — cancel cleanly; never leave overlay stuck
                cancelHandler?()
            }
            replacedSelection = nil
        case .resizing, .moving:
            stage = .adjusting
            mousePosition = nil
            window?.invalidateCursorRects(for: self)
            updateAccessibilityValue(announce: false)
        case .idle, .adjusting:
            return
        }
        setNeedsDisplay(bounds)
    }

    /// Release with ⇧ flips "Capture immediately after selecting" for this one
    /// capture. ⇧ still held from the shortcut doesn't count.
    func wantsAdjustStage(releasedWith flags: NSEvent.ModifierFlags) -> Bool {
        let shiftFlip = flags.contains(.shift) && !shiftHeldSinceStart
        return captureImmediately == shiftFlip
    }

    private func enterAdjustStage() {
        stage = .adjusting
        currentRect = currentRect.integral.intersection(bounds)
        window?.invalidateCursorRects(for: self)
        setAccessibilityHelp(hintText)
        updateAccessibilityValue(announce: true)
        setNeedsDisplay(bounds)
    }

    /// Captures the adjusted selection (Return, the Capture button, or a
    /// double-click inside it).
    func commitSelection() {
        guard stage == .adjusting, currentRect.width >= Self.minimumSize, currentRect.height >= Self.minimumSize else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        selectionHandler?(convertToScreen(currentRect), nil)
    }

    override func mouseMoved(with event: NSEvent) {
        if !showsHint {
            showsHint = true
            setNeedsDisplay(hintRect())
        }
        if mode == .window {
            let previous = highlightedWindowRect
            let hit = windowUnder(event.locationInWindow)
            highlightedWindowRect = hit?.rect
            highlightedWindowID = hit?.windowID
            if previous != highlightedWindowRect {
                invalidateWindowHighlight(from: previous, to: highlightedWindowRect)
            }
        } else if mode == .area && stage == .idle {
            // Invalidate every artifact we paint around the cursor at both
            // the previous and new positions: crosshair strips (full-screen
            // lines), the loupe (120px + shadow/border, flips left or right
            // and up or down near screen edges), the hex color pill below
            // the loupe, and the coordinate label offset from the cursor.
            let hintBefore = hintRect()
            if let old = mousePosition {
                invalidateCursorArtifacts(at: old)
            }
            mousePosition = event.locationInWindow
            invalidateCursorArtifacts(at: event.locationInWindow)
            let hintAfter = hintRect()
            if hintAfter != hintBefore {
                setNeedsDisplay(hintBefore.insetBy(dx: -2, dy: -2))
                setNeedsDisplay(hintAfter.insetBy(dx: -2, dy: -2))
            }
        } else if stage != .adjusting {
            setNeedsDisplay(bounds)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard showsHint || mousePosition != nil else { return }
        showsHint = false
        if stage == .idle, let old = mousePosition {
            mousePosition = nil
            invalidateCursorArtifacts(at: old)
        }
        setNeedsDisplay(bounds)
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

    /// The first drawing frame repaints everything (the pre-drag tint is
    /// near-clear, so the 0.3 dim must be established once); after that only
    /// the old and new rects — plus room for the border, handles, labels, the
    /// Capture button and the loupe — changed.
    private func invalidateSelectionChange(from previousRect: NSRect, to newRect: NSRect) {
        guard !previousRect.isEmpty else {
            setNeedsDisplay(bounds)
            return
        }
        let margin: CGFloat = stage == .drawing ? 32 : 200
        setNeedsDisplay(previousRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
        setNeedsDisplay(newRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
        setNeedsDisplay(hintRect().insetBy(dx: -2, dy: -2))
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

    // MARK: – Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            cancelHandler?()
            return
        }
        if event.keyCode == 49, !event.isARepeat { // Space — move selection while dragging
            isSpaceDown = true
            return
        }
        guard stage == .adjusting else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        let resize = flags.contains(.option)
        let previousRect = currentRect
        switch event.keyCode {
        case 36, 76: // Return, Enter
            commitSelection()
            return
        case 123: nudge(dx: -step, dy: 0, resize: resize)
        case 124: nudge(dx: step, dy: 0, resize: resize)
        case 125: nudge(dx: 0, dy: -step, resize: resize)
        case 126: nudge(dx: 0, dy: step, resize: resize)
        default: return
        }
        invalidateSelectionChange(from: previousRect, to: currentRect)
        window?.invalidateCursorRects(for: self)
        updateAccessibilityValue(announce: false)
    }

    /// Arrows move the selection; with ⌥ they grow or shrink it from its
    /// right and top edges.
    private func nudge(dx: CGFloat, dy: CGFloat, resize: Bool) {
        if resize {
            let width = min(max(currentRect.width + dx, Self.minimumSize), bounds.maxX - currentRect.minX)
            let height = min(max(currentRect.height + dy, Self.minimumSize), bounds.maxY - currentRect.minY)
            currentRect.size = NSSize(width: width, height: height)
        } else {
            currentRect = keptInBounds(currentRect.offsetBy(dx: dx, dy: dy))
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) {
            shiftHeldSinceStart = false
        }
        super.flagsChanged(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: – Geometry

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// The rect moved back inside this display, size unchanged.
    private func keptInBounds(_ rect: NSRect) -> NSRect {
        var moved = rect
        moved.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        moved.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return moved
    }

    /// `rect` with the grabbed edge(s) following `point`; the opposite edges
    /// stay put and the selection never collapses below the minimum size.
    private func resized(_ rect: NSRect, handle: Handle, to point: NSPoint) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let minimum = Self.minimumSize
        switch handle {
        case .left, .topLeft, .bottomLeft: minX = min(point.x, maxX - minimum)
        case .right, .topRight, .bottomRight: maxX = max(point.x, minX + minimum)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY = min(point.y, maxY - minimum)
        case .top, .topLeft, .topRight: maxY = max(point.y, minY + minimum)
        default: break
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    func handleCenter(_ handle: Handle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .topLeft: return NSPoint(x: rect.minX, y: rect.maxY)
        case .top: return NSPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return NSPoint(x: rect.maxX, y: rect.maxY)
        case .right: return NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return NSPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return NSPoint(x: rect.minX, y: rect.minY)
        case .left: return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleHitRect(_ handle: Handle, in rect: NSRect) -> NSRect {
        let center = handleCenter(handle, in: rect)
        let radius = Self.handleHitRadius
        return NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Corners win over edges where they overlap on small selections.
    private func handle(at point: NSPoint) -> Handle? {
        let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        if let corner = order.first(where: { handleHitRect($0, in: currentRect).contains(point) }) {
            return corner
        }
        // Anywhere along an edge grabs it, not only the midpoint square.
        let tolerance: CGFloat = 5
        let inX = point.x > currentRect.minX && point.x < currentRect.maxX
        let inY = point.y > currentRect.minY && point.y < currentRect.maxY
        if inX, abs(point.y - currentRect.maxY) <= tolerance { return .top }
        if inX, abs(point.y - currentRect.minY) <= tolerance { return .bottom }
        if inY, abs(point.x - currentRect.minX) <= tolerance { return .left }
        if inY, abs(point.x - currentRect.maxX) <= tolerance { return .right }
        return nil
    }

    private static func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch handle {
                case .topLeft: position = .topLeft
                case .topRight: position = .topRight
                case .bottomLeft: position = .bottomLeft
                default: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            return .crosshair
        }
    }

    // MARK: – Accessibility

    private func updateAccessibilityValue(announce: Bool) {
        let size = String(format: "%.0f by %.0f points", currentRect.width, currentRect.height)
        setAccessibilityValue("Selection \(size)")
        NSAccessibility.post(element: self, notification: .valueChanged)
        guard announce else { return }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Selection \(size). Arrow keys move it, Return captures, Escape cancels.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: – Helpers

    private func convertToScreen(_ rect: NSRect) -> CGRect {
        guard let win = window else { return rect }
        // Convert from view to window to screen
        let winRect = convert(rect, to: nil)
        let screenRect = win.convertToScreen(winRect)
        return screenRect
    }

    private func windowUnder(_ point: NSPoint) -> (rect: NSRect, windowID: CGWindowID)? {
        guard let win = window else { return nil }
        let screenPoint = win.convertToScreen(NSRect(origin: point, size: .zero)).origin
        refreshWindowRectsIfNeeded()
        for cached in cachedWindows where cached.rect.contains(screenPoint) {
            let viewOrigin = win.convertFromScreen(NSRect(origin: cached.rect.origin, size: .zero)).origin
            return (NSRect(origin: viewOrigin, size: cached.rect.size), cached.windowID)
        }
        return nil
    }

    private func refreshWindowRectsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowListRefresh > 0.15 else { return }
        lastWindowListRefresh = now
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        cachedWindows = windowList.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let appKitRect = CGRect(
                x: bounds.origin.x,
                y: screenHeight - bounds.origin.y - bounds.height,
                width: bounds.width,
                height: bounds.height
            )
            return (rect: appKitRect, windowID: CGWindowID(windowNumber))
        }
    }

}
