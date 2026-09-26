import AppKit
import Carbon.HIToolbox

/// The main drawing surface for the annotation editor.
/// Handles tool interaction, renders all annotation objects, and manages undo.
///
/// Annotations live in image coordinates — points from the screenshot's
/// top-left corner — so the backdrop padding and the crop never move them.
/// Drawing and hit-testing translate by `layout.imageOrigin`.
@MainActor
final class AnnotationCanvas: NSView {

    // MARK: – State

    var backgroundImage: NSImage? {
        didSet {
            guard backgroundImage !== oldValue else { return }
            updateLayout(refit: false)
        }
    }
    var objects: [any AnnotationObject] = []
    var selectedObjects: [any AnnotationObject] = [] {
        didSet {
            // Style edits coalesce per selection, not across two objects.
            coalescingKey = nil
            onOptionsChanged?()
        }
    }
    var activeTool: AnnotationTool = .arrow {
        didSet {
            if oldValue != activeTool {
                // A live text field must not outlive its tool: left open, it
                // silently commits on the NEXT canvas click, which looks like the
                // new tool spawned a text annotation out of nowhere.
                commitTextField()
                if activeTool == .crop {
                    beginCropEditing(returningTo: oldValue)
                } else if oldValue == .crop {
                    endCropEditing()
                }
            }
            window?.invalidateCursorRects(for: self)
            onToolChanged?(activeTool)
            onOptionsChanged?()
            // Reopening the editor straight into crop mode would be confusing.
            if activeTool != .crop {
                Settings.annotationLastTool = activeTool.rawValue
            }
        }
    }
    var activeColor: NSColor = .systemRed {
        didSet { persistActiveColor() }
    }
    var activeLineWidth: CGFloat = 3 {
        didSet { Settings.annotationLastLineWidth = Double(activeLineWidth) }
    }
    var activeFontSize: CGFloat = 18 {
        didSet { Settings.annotationTextFontSize = Double(activeFontSize) }
    }
    var activeTextBold = true {
        didSet { Settings.annotationTextBold = activeTextBold }
    }
    var activeRedactionStrength = AnnotationRedaction.defaultStrength {
        didSet { Settings.annotationRedactionStrength = Double(activeRedactionStrength) }
    }
    var roundedRectangles = false {
        didSet { Settings.annotationRoundedRectangles = roundedRectangles }
    }
    var spotlightEllipse = false {
        didSet { Settings.annotationSpotlightEllipse = spotlightEllipse }
    }

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onSaveRequested: (() -> Void)?
    var onCopyRequested: (() -> Void)?
    /// Selection, tool, or a tool style changed — the toolbar's options follow.
    var onOptionsChanged: (() -> Void)?
    var onCropStateChanged: (() -> Void)?
    var onBackgroundOptionsChanged: ((ScreenshotBackgroundOptions) -> Void)?
    /// The canvas changed size; `refit` asks to re-fit it to the viewport (crop changes).
    var onLayoutChanged: ((_ refit: Bool) -> Void)?
    var onDirtyStateChanged: (() -> Void)?

    // In-progress drawing state
    private var currentObject: (any AnnotationObject)?
    private var dragStart: CGPoint?
    private var lastDragPoint: CGPoint?

    private let renderer = AnnotationRenderer()

    // MARK: – Document (everything besides objects that the export shows)

    /// Backdrop behind the screenshot. Undoable, like every other edit.
    private(set) var backgroundOptions = ScreenshotBackgroundOptions.editorDefault
    /// Applied crop in image points; nil = the whole screenshot. Nothing is
    /// thrown away: annotations outside it come back when the crop widens.
    private(set) var appliedCrop: CGRect?
    /// The crop being adjusted while the crop tool is active.
    private(set) var pendingCrop: CGRect?
    private var toolBeforeCrop: AnnotationTool = .arrow

    var isEditingCrop: Bool { activeTool == .crop }

    var layout: AnnotationCanvasLayout {
        AnnotationCanvasLayout(
            imageSize: backgroundImage?.size ?? .zero,
            // Crop editing shows the whole screenshot around the crop.
            crop: isEditingCrop ? nil : appliedCrop,
            padding: backgroundOptions.isEnabled ? min(max(backgroundOptions.padding, 0), 240).rounded() : 0
        )
    }

    /// Whether the export differs from the untouched screenshot.
    var hasEdits: Bool {
        !objects.isEmpty || appliedCrop != nil || backgroundOptions.isEnabled
    }

    // MARK: – Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        restorePersistedStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true } // Easier coordinate math (top-left origin)

    // Clicking into an unfocused editor window interacts immediately instead
    // of eating the first click just to focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: – Coordinates

    private func documentPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let origin = layout.imageOrigin
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    private func viewRect(fromDocument rect: CGRect) -> CGRect {
        let origin = layout.imageOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func setNeedsDisplay(documentRect rect: CGRect, padding: CGFloat = 8) {
        let dirty = viewRect(fromDocument: rect).insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard !dirty.isNull, !dirty.isEmpty else { return }
        setNeedsDisplay(dirty)
    }

    private var imageBounds: CGRect {
        CGRect(origin: .zero, size: backgroundImage?.size ?? bounds.size)
    }

    /// Editing chrome (handles, outlines, grab slop) keeps its on-screen
    /// size when a big capture is zoomed out to fit.
    private var chromeScale: CGFloat {
        guard let magnification = enclosingScrollView?.magnification, magnification > 0 else { return 1 }
        return min(max(1 / magnification, 1), 6)
    }

    private func updateLayout(refit: Bool) {
        var sizeChanged = false
        if backgroundImage != nil {
            let size = layout.canvasSize
            sizeChanged = frame.size != size
            if sizeChanged { setFrameSize(size) }
        }
        positionTextEditor()
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(bounds)
        // Only a real size change re-fits; the user's zoom stays otherwise.
        onLayoutChanged?(refit && sizeChanged)
    }

    // MARK: - Hover feedback

    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredObjectID: UUID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverFeedback(at: documentPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredObject(nil)
    }

    private func updateHoverFeedback(at point: CGPoint) {
        guard activeTextEditor == nil, !isEditingCrop else {
            setHoveredObject(nil)
            return
        }
        if let handleHit = editHandleHit(at: point) {
            setHoveredObject(nil)
            cursor(for: handleHit.action).set()
            return
        }
        let hit = grabbableObject(at: point)
        setHoveredObject(hit?.id)
        if hit != nil {
            NSCursor.openHand.set()
        } else {
            defaultToolCursor.set()
        }
    }

    private func setHoveredObject(_ id: UUID?) {
        guard hoveredObjectID != id else { return }
        let previous = hoveredObjectID.flatMap { old in objects.first(where: { $0.id == old })?.bounds }
        hoveredObjectID = id
        let current = id.flatMap { new in objects.first(where: { $0.id == new })?.bounds }
        for rect in [previous, current].compactMap({ $0 }) {
            setNeedsDisplay(documentRect: rect, padding: 8 * chromeScale)
        }
    }

    private func cursor(for action: SelectDragAction) -> NSCursor {
        switch action {
        case .move:
            return .openHand
        case .arrowHandle, .lineEndpoint, .highlighterEndpoint, .calloutTail:
            return .pointingHand
        case .resize(_, let handle):
            switch handle {
            case .left, .right:
                return .resizeLeftRight
            case .top, .bottom:
                return .resizeUpDown
            case .topLeft, .bottomRight, .topRight, .bottomLeft:
                if #available(macOS 15.0, *) {
                    let position: NSCursor.FrameResizePosition = {
                        switch handle {
                        case .topLeft: return .topLeft
                        case .topRight: return .topRight
                        case .bottomLeft: return .bottomLeft
                        default: return .bottomRight
                        }
                    }()
                    return .frameResize(position: position, directions: .all)
                }
                return .crosshair
            }
        }
    }

    private var defaultToolCursor: NSCursor {
        switch activeTool {
        case .select:                                        return .arrow
        case .arrow, .rectangle, .filledRectangle, .ellipse: return .crosshair
        case .line, .freehand, .highlighter:                 return .crosshair
        case .freehandHighlighter, .spotlight:               return .crosshair
        case .text:                                          return .iBeam
        case .callout, .numberedStep:                        return .pointingHand
        case .blur, .pixelate, .crop:                        return .crosshair
        }
    }

    // MARK: - Cursor Management

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: defaultToolCursor)
    }

    // MARK: – Drawing

    private var scene: AnnotationRenderer.Scene {
        var drawn = objects
        if let currentObject { drawn.append(currentObject) }
        return AnnotationRenderer.Scene(
            image: backgroundImage,
            layout: layout,
            backgroundOptions: backgroundOptions,
            objects: drawn,
            fallbackSize: bounds.size
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1–3. Screenshot, backdrop, redactions, spotlights, annotations —
        // the exact renderer the export uses.
        renderer.draw(scene, in: ctx, scale: window?.backingScaleFactor ?? 2)

        // 4. Editing chrome, never part of an export
        let origin = layout.imageOrigin
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)

        // Hover affordance: a faint outline on the grabbable object under
        // the cursor, so "you can drag this" is visible before any click.
        if let hoveredObjectID,
           !selectedObjects.contains(where: { $0.id == hoveredObjectID }),
           let hovered = objects.first(where: { $0.id == hoveredObjectID }) {
            let s = chromeScale
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(s)
            ctx.setLineDash(phase: 0, lengths: [4 * s, 3 * s])
            ctx.stroke(selectionFrame(for: hovered).insetBy(dx: -3 * s, dy: -3 * s))
            ctx.restoreGState()
        }

        for obj in selectedObjects {
            drawSelectionHandle(for: obj, ctx: ctx)
        }
        ctx.restoreGState()

        activeTextEditor?.drawPlaceholderAndFrame(in: ctx)
        drawCropOverlay(in: ctx)
    }

    /// The rect selection handles surround.
    private func selectionFrame(for obj: any AnnotationObject) -> CGRect {
        if let callout = obj as? CalloutAnnotation { return callout.bubbleRect }
        return obj.bounds
    }

    private func drawSelectionHandle(for obj: any AnnotationObject, ctx: CGContext) {
        if let arrow = obj as? ArrowAnnotation {
            drawArrowSelection(for: arrow, ctx: ctx)
            return
        }

        if let line = obj as? LineAnnotation {
            drawEndpointSelection(start: line.startPoint, end: line.endPoint, ctx: ctx)
            return
        }

        if let highlighter = obj as? HighlighterAnnotation {
            drawEndpointSelection(start: highlighter.startPoint, end: highlighter.endPoint, ctx: ctx)
            return
        }

        let s = chromeScale
        let expanded = selectionFrame(for: obj).insetBy(dx: -4 * s, dy: -4 * s)

        ctx.saveGState()

        let accent = NSColor.controlAccentColor
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.25 * s)
        ctx.setLineDash(phase: 0, lengths: [5 * s, 4 * s])
        ctx.stroke(expanded)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setShadow(offset: .zero, blur: 0)

        for handle in ResizeHandle.allCases {
            drawResizeHandle(at: resizeHandleCenter(for: expanded, handle: handle), handle: handle, accent: accent, ctx: ctx)
        }

        if let callout = obj as? CalloutAnnotation, callout.tailPath != nil {
            drawRoundHandle(at: callout.tail, radius: 7 * s, fill: accent, stroke: .white, ctx: ctx)
        }

        ctx.restoreGState()
    }

    private func drawEndpointSelection(start: CGPoint, end: CGPoint, ctx: CGContext) {
        let s = chromeScale
        ctx.saveGState()
        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25 * s)
        ctx.setLineDash(phase: 0, lengths: [5 * s, 4 * s])
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawRoundHandle(at: start, radius: 6.5 * s, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: end, radius: 6.5 * s, fill: .white, stroke: accent, ctx: ctx)
        ctx.restoreGState()
    }

    private func drawArrowSelection(for arrow: ArrowAnnotation, ctx: CGContext) {
        let s = chromeScale
        ctx.saveGState()

        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25 * s)
        ctx.setLineDash(phase: 0, lengths: [5 * s, 4 * s])
        ctx.move(to: arrow.startPoint)
        if let controlPoint = arrow.controlPoint {
            ctx.addQuadCurve(to: arrow.endPoint, control: controlPoint)
        } else {
            ctx.addLine(to: arrow.endPoint)
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let curveMidpoint = arrow.pointOnCurve(at: 0.5)
        let controlPoint = arrow.handlePoint(.control)
        ctx.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(s)
        ctx.move(to: curveMidpoint)
        ctx.addLine(to: controlPoint)
        ctx.strokePath()

        drawRoundHandle(at: arrow.handlePoint(.start), radius: 6.5 * s, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: arrow.handlePoint(.end), radius: 6.5 * s, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: controlPoint, radius: 7.5 * s, fill: accent, stroke: .white, ctx: ctx)

        ctx.restoreGState()
    }

    private func drawRoundHandle(at point: CGPoint, radius: CGFloat, fill: NSColor, stroke: NSColor, ctx: CGContext) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1.5 * chromeScale)
        ctx.strokeEllipse(in: rect)
    }

    private func drawResizeHandle(at point: CGPoint, handle: ResizeHandle, accent: NSColor, ctx: CGContext) {
        let radius: CGFloat = (isCornerHandle(handle) ? 5.5 : 4.5) * chromeScale
        drawRoundHandle(at: point, radius: radius, fill: .white, stroke: accent, ctx: ctx)
    }

    private func resizeHandleCenter(for rect: CGRect, handle: ResizeHandle) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func isCornerHandle(_ handle: ResizeHandle) -> Bool {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }

    private func drawCropOverlay(in ctx: CGContext) {
        guard isEditingCrop, let pendingCrop else { return }
        let crop = viewRect(fromDocument: pendingCrop)
        let s = chromeScale
        ctx.saveGState()
        // Dim outside crop
        let dimmed = CGMutablePath()
        dimmed.addRect(bounds)
        dimmed.addRect(crop)
        ctx.addPath(dimmed)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)

        // Rule-of-thirds guides
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(s)
        for third in [CGFloat(1) / 3, CGFloat(2) / 3] {
            ctx.move(to: CGPoint(x: crop.minX + crop.width * third, y: crop.minY))
            ctx.addLine(to: CGPoint(x: crop.minX + crop.width * third, y: crop.maxY))
            ctx.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * third))
            ctx.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * third))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 * s)
        ctx.stroke(crop)
        for handle in ResizeHandle.allCases {
            drawResizeHandle(at: resizeHandleCenter(for: crop, handle: handle), handle: handle, accent: .controlAccentColor, ctx: ctx)
        }
        ctx.restoreGState()
    }

    // MARK: – Mouse

    override func mouseDown(with event: NSEvent) {
        let point = documentPoint(for: event)
        // A click on the canvas takes focus from the editor (committing it)
        // before this mouseDown arrives; either way, the click was spent
        // finishing the text.
        let wasEditingText = activeTextEditor != nil || editorJustLostFocus
        editorJustLostFocus = false
        commitTextField()
        setHoveredObject(nil)

        if isEditingCrop {
            cropMouseDown(at: point, clickCount: event.clickCount)
            return
        }

        // Double-click a text annotation or callout with any tool reopens it
        // for editing in place. (Skipped when the click just committed an
        // active field — that commit is what the double-click landed on.)
        if event.clickCount == 2, !wasEditingText,
           let editable = objects.last(where: { ($0 is TextAnnotation || $0 is CalloutAnnotation) && $0.contains(point: point) }) {
            beginEditing(editable, isNew: false)
            return
        }

        if activeTool == .select {
            handleSelectDown(point: point, hit: topmostObject { $0.contains(point: point) })
            updateDragCursor()
            return
        }

        // Direct manipulation with a drawing tool: a handle of the selection,
        // or an annotation's outline, grabs it. A drag inside a shape draws a
        // new annotation — labeling or spotlighting inside a box is common.
        let grabbed = grabbableObject(at: point)
        if grabbed != nil || editHandleHit(at: point) != nil {
            isGrabSession = true
            handleSelectDown(point: point, hit: grabbed)
            updateDragCursor()
            return
        }

        // Clicking away from text being typed only commits it.
        if wasEditingText, activeTool == .text || activeTool == .callout {
            return
        }

        if activeTool == .text {
            beginTextEntry(at: point)
            return
        }
        if activeTool == .numberedStep {
            pushUndo()
            let step = NumberedStepAnnotation(center: point, number: nextStepNumber())
            step.color = activeColor
            objects.append(step)
            selectedObjects = [step]
            setNeedsDisplay(bounds)
            return
        }

        pushUndo()
        dragStart = point
        lastDragPoint = point
        currentObject = makeObject(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = documentPoint(for: event)

        if activeTool == .select || isGrabSession {
            handleSelectDrag(point: point)
            return
        }
        if isEditingCrop {
            cropMouseDragged(to: point)
            return
        }

        let previousBounds = currentObject?.bounds
        updateCurrentObject(to: point, modifiers: event.modifierFlags)
        lastDragPoint = point
        if currentObject is SpotlightAnnotation {
            setNeedsDisplay(bounds) // the dimming covers everything
        } else {
            invalidate(previousBounds, currentObject?.bounds, padding: activeLineWidth + 12)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = documentPoint(for: event)

        if activeTool == .select || isGrabSession {
            handleSelectUp(point: point)
            isGrabSession = false
            updateHoverFeedback(at: point)
            return
        }
        if isEditingCrop {
            cropMouseUp()
            return
        }
        let startedDrawing = dragStart != nil
        dragStart = nil
        guard let obj = currentObject else {
            if startedDrawing { discardLastUndo() } // the press made nothing to draw
            return
        }
        currentObject = nil

        if let callout = obj as? CalloutAnnotation {
            objects.append(callout)
            beginEditing(callout, isNew: true)
        } else if isDegenerate(obj) {
            // A click without a drag draws nothing.
            discardLastUndo()
        } else {
            objects.append(obj)
            selectedObjects = [obj]
        }
        setNeedsDisplay(bounds)
    }

    private func isDegenerate(_ object: any AnnotationObject) -> Bool {
        func tooSmall(_ rect: CGRect) -> Bool { rect.width < 2 || rect.height < 2 }
        func tooShort(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(b.x - a.x, b.y - a.y) < 3 }
        switch object {
        case let r as RectangleAnnotation:   return tooSmall(r.rect)
        case let e as EllipseAnnotation:     return tooSmall(e.rect)
        case let b as BlurAnnotation:        return tooSmall(b.rect)
        case let p as PixelateAnnotation:    return tooSmall(p.rect)
        case let s as SpotlightAnnotation:   return tooSmall(s.rect)
        case let a as ArrowAnnotation:       return tooShort(a.startPoint, a.endPoint)
        case let l as LineAnnotation:        return tooShort(l.startPoint, l.endPoint)
        case let h as HighlighterAnnotation: return tooShort(h.startPoint, h.endPoint)
        case let f as FreehandAnnotation:
            let extent = AnnotationGeometry.boundingRect(of: f.points)
            return f.points.count < 2 || max(extent.width, extent.height) < 2
        default:                             return false
        }
    }

    // MARK: – Select tool

    /// True while a drag that started on an existing object is being routed
    /// through the select machinery even though a drawing tool is active.
    private var isGrabSession = false

    /// The annotation a click at this point would grab, given the active
    /// tool. Select grabs anything it hits. Drawing tools only grab near an
    /// outline, so drags inside shapes draw; freehand never grabs bodies
    /// (scribbling over annotations is legitimate), and the click-to-place
    /// tools (text, callout, numbered step) only grab their own kind so
    /// placing one on top of a shape stays easy.
    private func grabbableObject(at point: CGPoint) -> (any AnnotationObject)? {
        switch activeTool {
        case .select:
            return topmostObject { $0.contains(point: point) }
        case .crop, .freehand, .freehandHighlighter:
            return nil
        case .text:
            return objects.last { $0 is TextAnnotation && $0.contains(point: point) }
        case .callout:
            return objects.last { $0 is CalloutAnnotation && $0.contains(point: point) }
        case .numberedStep:
            return objects.last { $0 is NumberedStepAnnotation && $0.contains(point: point) }
        default:
            let tolerance = 6 * chromeScale
            return topmostObject { $0.outlineContains(point: point, tolerance: tolerance) }
        }
    }

    /// The topmost object matching `predicate` in drawing order: redactions
    /// and spotlights render beneath every other annotation, whenever they
    /// were added.
    private func topmostObject(where predicate: (any AnnotationObject) -> Bool) -> (any AnnotationObject)? {
        objects.last { !AnnotationRenderer.isScreenshotEffect($0) && predicate($0) }
            ?? objects.last { AnnotationRenderer.isScreenshotEffect($0) && predicate($0) }
    }

    private func updateDragCursor() {
        if case .move = selectDragAction, !selectedObjects.isEmpty {
            NSCursor.closedHand.set()
        }
    }

    private var selectDragStart: CGPoint?
    private var didPushSelectMoveUndo = false
    private var selectDragAction: SelectDragAction?

    private enum ResizeHandle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum SelectDragAction {
        case move
        case arrowHandle(ArrowAnnotation, ArrowHandle)
        case lineEndpoint(LineAnnotation, EndpointHandle)
        case highlighterEndpoint(HighlighterAnnotation, EndpointHandle)
        case calloutTail(CalloutAnnotation)
        case resize(any AnnotationObject, ResizeHandle)
    }

    private enum EndpointHandle {
        case start, end
    }

    private func handleSelectDown(point: CGPoint, hit: (any AnnotationObject)?) {
        if let hitAction = editHandleHit(at: point) {
            if let object = hitAction.object, !selectedObjects.contains(where: { $0.id == object.id }) {
                selectedObjects = [object]
            }
            selectDragStart = point
            selectDragAction = hitAction.action
            didPushSelectMoveUndo = false
            setNeedsDisplay(bounds)
            return
        }

        if let hit {
            if !selectedObjects.contains(where: { $0.id == hit.id }) {
                selectedObjects = [hit]
            }
            selectDragStart = point
            selectDragAction = .move
            didPushSelectMoveUndo = false
        } else {
            selectedObjects = []
            selectDragAction = nil
        }
        setNeedsDisplay(bounds)
    }

    private func handleSelectDrag(point: CGPoint) {
        guard let start = selectDragStart else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        guard delta.x != 0 || delta.y != 0 else { return }
        if !didPushSelectMoveUndo {
            pushUndo()
            didPushSelectMoveUndo = true
        }
        let previousRects = selectedObjects.map(\.bounds)
        switch selectDragAction {
        case .arrowHandle(let arrow, let handle):
            arrow.setHandle(handle, to: point)
        case .lineEndpoint(let line, let endpoint):
            setEndpoint(endpoint, on: line, to: point)
        case .highlighterEndpoint(let highlighter, let endpoint):
            setEndpoint(endpoint, on: highlighter, to: point)
        case .calloutTail(let callout):
            callout.tail = point
        case .resize(let object, let handle):
            resize(object, handle: handle, by: delta)
        case .move, nil:
            for obj in selectedObjects {
                obj.move(by: delta)
            }
        }
        selectDragStart = point
        if selectedObjects.contains(where: { $0 is SpotlightAnnotation }) {
            setNeedsDisplay(bounds)
            return
        }
        let currentRects = selectedObjects.map(\.bounds)
        for rect in previousRects + currentRects {
            setNeedsDisplay(documentRect: rect, padding: 12 * chromeScale)
        }
    }

    private func handleSelectUp(point: CGPoint) {
        if didPushSelectMoveUndo {
            onOptionsChanged?() // a resize changes the size the toolbar shows
        }
        selectDragStart = nil
        selectDragAction = nil
        didPushSelectMoveUndo = false
    }

    private func editHandleHit(at point: CGPoint) -> (object: (any AnnotationObject)?, action: SelectDragAction)? {
        let s = chromeScale
        for obj in selectedObjects.reversed() {
            if let arrow = obj as? ArrowAnnotation {
                for handle in [ArrowHandle.control, .end, .start] {
                    let center = arrow.handlePoint(handle)
                    let radius = handle == .control ? CGFloat(9) : CGFloat(8)
                    if hit(point, center: center, radius: (radius + 4) * s) {
                        return (arrow, .arrowHandle(arrow, handle))
                    }
                }
                continue
            }

            if let line = obj as? LineAnnotation {
                if hit(point, center: line.startPoint, radius: 10 * s) { return (line, .lineEndpoint(line, .start)) }
                if hit(point, center: line.endPoint, radius: 10 * s) { return (line, .lineEndpoint(line, .end)) }
                continue
            }

            if let highlighter = obj as? HighlighterAnnotation {
                if hit(point, center: highlighter.startPoint, radius: 10 * s) { return (highlighter, .highlighterEndpoint(highlighter, .start)) }
                if hit(point, center: highlighter.endPoint, radius: 10 * s) { return (highlighter, .highlighterEndpoint(highlighter, .end)) }
                continue
            }

            if let callout = obj as? CalloutAnnotation, callout.tailPath != nil,
               hit(point, center: callout.tail, radius: 11 * s) {
                return (callout, .calloutTail(callout))
            }

            let expanded = selectionFrame(for: obj).insetBy(dx: -4 * s, dy: -4 * s)
            for handle in ResizeHandle.allCases {
                if hit(point, center: resizeHandleCenter(for: expanded, handle: handle), radius: 10 * s) {
                    return (obj, .resize(obj, handle))
                }
            }
        }
        return nil
    }

    private func hit(_ point: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius
    }

    private func setEndpoint(_ endpoint: EndpointHandle, on line: LineAnnotation, to point: CGPoint) {
        switch endpoint {
        case .start: line.startPoint = point
        case .end:   line.endPoint = point
        }
    }

    private func setEndpoint(_ endpoint: EndpointHandle, on highlighter: HighlighterAnnotation, to point: CGPoint) {
        switch endpoint {
        case .start: highlighter.startPoint = point
        case .end:   highlighter.endPoint = point
        }
    }

    private func resize(_ object: any AnnotationObject, handle: ResizeHandle, by delta: CGPoint) {
        let sourceRect = editableRect(for: object)
        let newRect = resizedRect(from: sourceRect, handle: handle, by: delta)

        switch object {
        case let rectangle as RectangleAnnotation:
            rectangle.rect = newRect
        case let ellipse as EllipseAnnotation:
            ellipse.rect = newRect
        case let blur as BlurAnnotation:
            blur.rect = newRect
        case let pixelate as PixelateAnnotation:
            pixelate.rect = newRect
        case let spotlight as SpotlightAnnotation:
            spotlight.rect = newRect
        case let text as TextAnnotation:
            let oldHeight = max(sourceRect.height, 1)
            let scale = max(newRect.height, 1) / oldHeight
            text.origin = newRect.origin
            text.fontSize = min(96, max(8, text.fontSize * scale))
        case let callout as CalloutAnnotation:
            let scale = max(newRect.height, 1) / max(sourceRect.height, 1)
            callout.origin = newRect.origin
            callout.fontSize = min(96, max(8, callout.fontSize * scale))
        case let step as NumberedStepAnnotation:
            let diameter = min(160, max(14, max(newRect.width, newRect.height)))
            step.origin = CGPoint(x: newRect.midX, y: newRect.midY)
            step.diameter = diameter
        case let freehand as FreehandAnnotation:
            resizeFreehand(freehand, from: sourceRect, to: newRect)
        default:
            break
        }
    }

    private func editableRect(for object: any AnnotationObject) -> CGRect {
        switch object {
        case let rectangle as RectangleAnnotation: return rectangle.rect
        case let ellipse as EllipseAnnotation:     return ellipse.rect
        case let blur as BlurAnnotation:           return blur.rect
        case let pixelate as PixelateAnnotation:   return pixelate.rect
        case let spotlight as SpotlightAnnotation: return spotlight.rect
        case let callout as CalloutAnnotation:     return callout.bubbleRect
        default:                                   return object.bounds
        }
    }

    private func resizedRect(from rect: CGRect, handle: ResizeHandle, by delta: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:     minX += delta.x; minY += delta.y
        case .top:         minY += delta.y
        case .topRight:    maxX += delta.x; minY += delta.y
        case .right:       maxX += delta.x
        case .bottomRight: maxX += delta.x; maxY += delta.y
        case .bottom:      maxY += delta.y
        case .bottomLeft:  minX += delta.x; maxY += delta.y
        case .left:        minX += delta.x
        }

        let minSize: CGFloat = 10
        if maxX - minX < minSize {
            if handle == .left || handle == .topLeft || handle == .bottomLeft { minX = maxX - minSize }
            else { maxX = minX + minSize }
        }
        if maxY - minY < minSize {
            if handle == .top || handle == .topLeft || handle == .topRight { minY = maxY - minSize }
            else { maxY = minY + minSize }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizeFreehand(_ freehand: FreehandAnnotation, from sourceRect: CGRect, to newRect: CGRect) {
        guard !freehand.points.isEmpty else { return }
        let sourceWidth = max(sourceRect.width, 1)
        let sourceHeight = max(sourceRect.height, 1)
        freehand.points = freehand.points.map { point in
            let xRatio = (point.x - sourceRect.minX) / sourceWidth
            let yRatio = (point.y - sourceRect.minY) / sourceHeight
            return CGPoint(x: newRect.minX + xRatio * newRect.width,
                           y: newRect.minY + yRatio * newRect.height)
        }
    }

    // MARK: – Object factory

    private func makeObject(at point: CGPoint) -> (any AnnotationObject)? {
        switch activeTool {
        case .arrow:
            let a = ArrowAnnotation(start: point, end: point)
            a.color = activeColor; a.lineWidth = activeLineWidth; return a
        case .rectangle, .filledRectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: activeTool == .filledRectangle)
            r.color = activeColor; r.lineWidth = activeLineWidth
            r.cornerRadius = roundedRectangles ? RectangleAnnotation.roundedCornerRadius : 0
            return r
        case .ellipse:
            let e = EllipseAnnotation(rect: CGRect(origin: point, size: .zero))
            e.color = activeColor; e.lineWidth = activeLineWidth; return e
        case .line:
            let l = LineAnnotation(start: point, end: point)
            l.color = activeColor; l.lineWidth = activeLineWidth; return l
        case .freehand:
            let f = FreehandAnnotation()
            f.points = [point]; f.color = activeColor; f.lineWidth = activeLineWidth; return f
        case .highlighter:
            let h = HighlighterAnnotation(start: point, end: point)
            h.color = activeColor; h.lineWidth = Self.highlighterWidth(forSize: activeLineWidth); return h
        case .freehandHighlighter:
            let f = FreehandAnnotation()
            f.isHighlighter = true
            f.points = [point]; f.color = activeColor; f.lineWidth = Self.highlighterWidth(forSize: activeLineWidth); return f
        case .blur:
            let b = BlurAnnotation(rect: CGRect(origin: point, size: .zero))
            b.strength = activeRedactionStrength
            return b
        case .pixelate:
            let p = PixelateAnnotation(rect: CGRect(origin: point, size: .zero))
            p.strength = activeRedactionStrength
            return p
        case .spotlight:
            return SpotlightAnnotation(rect: CGRect(origin: point, size: .zero), isEllipse: spotlightEllipse)
        case .callout:
            return makeCallout(pointingAt: point)
        default: return nil
        }
    }

    /// A new, empty callout pointing at `tip`, its bubble up and to the right
    /// (flipped to stay on the screenshot near its edges).
    private func makeCallout(pointingAt tip: CGPoint) -> CalloutAnnotation {
        let callout = CalloutAnnotation(origin: tip, tail: tip)
        callout.color = activeColor
        callout.fontSize = activeFontSize
        callout.isBold = activeTextBold
        let size = callout.bubbleRect.size
        let visible = layout.visibleImageRect
        var origin = CGPoint(x: tip.x + 32, y: tip.y - 40 - size.height)
        if origin.y < visible.minY { origin.y = tip.y + 40 }
        if origin.x + size.width > visible.maxX { origin.x = tip.x - 32 - size.width }
        callout.origin = origin
        return callout
    }

    private func updateCurrentObject(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let start = dragStart else { return }
        let square = modifiers.contains(.shift)
        let fromCenter = modifiers.contains(.option)
        // ⇧ with line-style tools snaps the angle to 45° increments
        let endPoint = square ? snappedEndPoint(from: start, to: point) : point
        switch currentObject {
        case let a as ArrowAnnotation:       a.endPoint = endPoint
        case let r as RectangleAnnotation:   r.rect = dragRect(from: start, to: point, square: square, fromCenter: fromCenter)
        case let e as EllipseAnnotation:     e.rect = dragRect(from: start, to: point, square: square, fromCenter: fromCenter)
        case let l as LineAnnotation:        l.endPoint = endPoint
        case let f as FreehandAnnotation:
            if let last = f.points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
            f.points.append(point)
        case let h as HighlighterAnnotation: h.endPoint = endPoint
        case let b as BlurAnnotation:        b.rect = dragRect(from: start, to: point, square: square, fromCenter: fromCenter)
        case let p as PixelateAnnotation:    p.rect = dragRect(from: start, to: point, square: square, fromCenter: fromCenter)
        case let s as SpotlightAnnotation:   s.rect = dragRect(from: start, to: point, square: square, fromCenter: fromCenter)
        case let c as CalloutAnnotation:
            // Press on what to point at, drag the bubble out to where it goes.
            guard hypot(point.x - start.x, point.y - start.y) > 6 else { return }
            let size = c.bubbleRect.size
            c.origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        default: break
        }
    }

    /// Snaps the drag endpoint to 45° increments around the drag start.
    private func snappedEndPoint(from start: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - start.x
        let dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// Builds the drag rect honoring ⇧ (constrain to square) and ⌥ (draw from center).
    private func dragRect(from start: CGPoint, to point: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = point.x - start.x
        var dy = point.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return rectFrom(start, to: CGPoint(x: start.x + dx, y: start.y + dy))
    }

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }

    private func invalidate(_ oldRect: CGRect?, _ newRect: CGRect?, padding: CGFloat) {
        for rect in [oldRect, newRect].compactMap({ $0 }) {
            setNeedsDisplay(documentRect: rect, padding: padding)
        }
    }

    private func nextStepNumber() -> Int {
        let existing = objects.compactMap { ($0 as? NumberedStepAnnotation)?.number }
        return (existing.max() ?? 0) + 1
    }

    // MARK: – Crop
    //
    // Crop is a rect applied at render time. While the crop tool is active the
    // whole screenshot shows with the crop drawn over it: drag to draw a new
    // one, drag inside to move it, drag a handle to resize. Return, a
    // double-click inside, or Apply commits (undoable); Escape cancels.

    private enum CropDrag {
        case create(start: CGPoint)
        case move(from: CGRect, start: CGPoint)
        case resize(ResizeHandle, from: CGRect, start: CGPoint)
    }
    private var cropDrag: CropDrag?
    private var cropBeforeDrag: CGRect?

    var canApplyCrop: Bool { isEditingCrop && normalizedPendingCrop != appliedCrop }
    var canResetCrop: Bool { isEditingCrop && pendingCrop != nil }

    private func beginCropEditing(returningTo tool: AnnotationTool) {
        toolBeforeCrop = tool == .crop ? .arrow : tool
        selectedObjects = []
        pendingCrop = appliedCrop
        updateLayout(refit: true)
        onCropStateChanged?()
    }

    private func endCropEditing() {
        pendingCrop = nil
        cropDrag = nil
        updateLayout(refit: true)
        onCropStateChanged?()
    }

    /// Commits the crop being edited and returns to the previous tool.
    func applyCrop() {
        guard isEditingCrop else { return }
        let newCrop = normalizedPendingCrop
        if newCrop != appliedCrop {
            pushUndo()
            appliedCrop = newCrop
        }
        activeTool = toolBeforeCrop
    }

    /// Leaves crop editing without changing the applied crop.
    func cancelCropEditing() {
        guard isEditingCrop else { return }
        activeTool = toolBeforeCrop
    }

    /// Clears the crop being edited; applying then shows the whole screenshot.
    func resetCrop() {
        guard isEditingCrop else { return }
        pendingCrop = nil
        setNeedsDisplay(bounds)
        onCropStateChanged?()
    }

    /// The pending crop as it would be applied: inside the screenshot, on its
    /// pixel grid, and nil when it covers everything.
    private var normalizedPendingCrop: CGRect? {
        guard let pending = pendingCrop else { return nil }
        let limits = imageBounds
        var crop = pending.standardized.intersection(limits)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        if let density = AnnotationRenderer.source(for: backgroundImage)?.density {
            crop = AnnotationRenderer.pixelAligned(crop, density: density)
        }
        return crop.equalTo(limits) ? nil : crop
    }

    private func cropMouseDown(at point: CGPoint, clickCount: Int) {
        if clickCount == 2, let crop = pendingCrop, crop.contains(point) {
            applyCrop()
            return
        }
        cropBeforeDrag = pendingCrop
        if let crop = pendingCrop {
            let radius = 10 * chromeScale
            if let handle = ResizeHandle.allCases.first(where: { hit(point, center: resizeHandleCenter(for: crop, handle: $0), radius: radius) }) {
                cropDrag = .resize(handle, from: crop, start: point)
                return
            }
            if crop.contains(point) {
                cropDrag = .move(from: crop, start: point)
                return
            }
        }
        cropDrag = .create(start: clamped(point, to: imageBounds))
    }

    private func cropMouseDragged(to point: CGPoint) {
        guard let cropDrag else { return }
        let previous = pendingCrop
        let limits = imageBounds
        switch cropDrag {
        case .create(let start):
            pendingCrop = rectFrom(start, to: clamped(point, to: limits))
        case .move(let from, let start):
            var moved = from.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, limits.minX), limits.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, limits.minY), limits.maxY - moved.height)
            pendingCrop = moved
        case .resize(let handle, let from, let start):
            let resized = resizedRect(from: from, handle: handle, by: CGPoint(x: point.x - start.x, y: point.y - start.y))
            pendingCrop = resized.intersection(limits)
        }
        invalidate(previous, pendingCrop, padding: 16 * chromeScale)
        onCropStateChanged?()
    }

    private func cropMouseUp() {
        // A click or a sliver doesn't replace the crop being edited.
        if case .create = cropDrag, let crop = pendingCrop, crop != cropBeforeDrag, crop.width < 4 || crop.height < 4 {
            pendingCrop = cropBeforeDrag
        }
        cropDrag = nil
        setNeedsDisplay(bounds)
        onCropStateChanged?()
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    // MARK: – Text
    //
    // Text annotations and callouts are edited in place: the object stays in
    // `objects` (hidden text) while an AnnotationTextEditor floats over it.

    private struct TextEditingSession {
        let target: any AnnotationObject
        let isNew: Bool
        let originalText: String
        let originalFontSize: CGFloat
        let originalBold: Bool
        let originalColor: NSColor
    }

    private var textSession: TextEditingSession?
    private var activeTextEditor: AnnotationTextEditor?
    /// Typing undo lives with the editor, never in the window's undo manager
    /// — ⌘Z after committing must undo canvas edits, not dead keystrokes.
    private var textUndoManager: UndoManager?

    /// The in-place text editor while text is being typed.
    var textEditor: NSTextView? { activeTextEditor }

    /// Set for the rest of the event when the editor commits because focus
    /// moved away (see mouseDown).
    private var editorJustLostFocus = false

    private func beginTextEntry(at point: CGPoint) {
        pushUndo()
        let annotation = TextAnnotation(origin: point)
        annotation.color = activeColor
        annotation.fontSize = activeFontSize
        annotation.isBold = activeTextBold
        // The first line sits centered on the click.
        annotation.origin.y -= annotation.textSize.height / 2
        objects.append(annotation)
        beginEditing(annotation, isNew: true)
    }

    /// Opens the in-place editor on a text annotation or callout. New
    /// objects were recorded for undo when created; existing ones are here.
    private func beginEditing(_ object: any AnnotationObject, isNew: Bool) {
        let editor: AnnotationTextEditor
        let session: TextEditingSession
        switch object {
        case let text as TextAnnotation:
            editor = AnnotationTextEditor(font: text.font, color: text.color)
            editor.string = text.text
            session = TextEditingSession(target: text, isNew: isNew, originalText: text.text,
                                         originalFontSize: text.fontSize, originalBold: text.isBold, originalColor: text.color)
            text.isEditing = true
        case let callout as CalloutAnnotation:
            editor = AnnotationTextEditor(font: callout.font, color: callout.textColor)
            editor.string = callout.text
            session = TextEditingSession(target: callout, isNew: isNew, originalText: callout.text,
                                         originalFontSize: callout.fontSize, originalBold: callout.isBold, originalColor: callout.color)
            callout.isEditing = true
        default:
            return
        }
        if !isNew { pushUndo() }
        selectedObjects = []
        setHoveredObject(nil)
        textSession = session
        textUndoManager = UndoManager()
        activeTextEditor = editor
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.commitTextField() }
        addSubview(editor)
        editor.fitToText()
        positionTextEditor()
        window?.makeFirstResponder(editor)
        if !isNew { editor.selectAll(nil) }
        onOptionsChanged?()
        setNeedsDisplay(bounds)
    }

    private func positionTextEditor() {
        guard let editor = activeTextEditor, let target = textSession?.target else { return }
        let textOrigin: CGPoint
        switch target {
        case let text as TextAnnotation:       textOrigin = text.origin
        case let callout as CalloutAnnotation: textOrigin = callout.textOrigin
        default: return
        }
        let origin = layout.imageOrigin
        editor.setFrameOrigin(NSPoint(
            x: textOrigin.x + origin.x - AnnotationTextEditor.inset.width,
            y: textOrigin.y + origin.y - AnnotationTextEditor.inset.height
        ))
    }

    private func syncEditorStyle() {
        guard let editor = activeTextEditor, let target = textSession?.target else { return }
        switch target {
        case let text as TextAnnotation:       editor.setStyle(font: text.font, color: text.color)
        case let callout as CalloutAnnotation: editor.setStyle(font: callout.font, color: callout.textColor)
        default: break
        }
        positionTextEditor()
        setNeedsDisplay(bounds)
    }

    func commitTextField() {
        guard let editor = activeTextEditor, let session = textSession else { return }
        activeTextEditor = nil
        textSession = nil
        textUndoManager = nil
        editor.delegate = nil
        editor.onCommit = nil
        let editorWasFocused = window?.firstResponder === editor
        editor.removeFromSuperview()
        if editorWasFocused { window?.makeFirstResponder(self) }

        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.target {
        case let annotation as TextAnnotation:
            annotation.isEditing = false
            annotation.text = text
        case let callout as CalloutAnnotation:
            callout.isEditing = false
            callout.text = text
        default:
            break
        }

        if text.isEmpty {
            objects.removeAll { $0.id == session.target.id }
            if session.isNew { discardLastUndo() } // nothing was added after all
        } else if !session.isNew, isUnchanged(session, text: text) {
            discardLastUndo() // opened and closed without an edit
        }
        onOptionsChanged?()
        setNeedsDisplay(bounds)
    }

    private func isUnchanged(_ session: TextEditingSession, text: String) -> Bool {
        guard text == session.originalText else { return false }
        switch session.target {
        case let annotation as TextAnnotation:
            return annotation.fontSize == session.originalFontSize && annotation.isBold == session.originalBold
                && annotation.color == session.originalColor
        case let callout as CalloutAnnotation:
            return callout.fontSize == session.originalFontSize && callout.isBold == session.originalBold
                && callout.color == session.originalColor
        default:
            return true
        }
    }

    /// Commits whatever is mid-edit (text being typed, a crop being
    /// adjusted) so an export shows it.
    func commitPendingEdits() {
        commitTextField()
        if isEditingCrop { applyCrop() }
    }

    // MARK: – Style persistence

    /// Restores the last-used tool and styles from Settings.
    private func restorePersistedStyle() {
        if let tool = AnnotationTool(rawValue: Settings.annotationLastTool), tool != .crop {
            activeTool = tool
        }
        if let data = Settings.annotationLastColorData,
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            activeColor = color
        }
        activeLineWidth = CGFloat(Settings.annotationLastLineWidth)
        activeFontSize = CGFloat(Settings.annotationTextFontSize)
        activeTextBold = Settings.annotationTextBold
        activeRedactionStrength = CGFloat(Settings.annotationRedactionStrength)
        roundedRectangles = Settings.annotationRoundedRectangles
        spotlightEllipse = Settings.annotationSpotlightEllipse
    }

    private func persistActiveColor() {
        // Archived with secure coding so custom colors from any color space round-trip safely.
        Settings.annotationLastColorData = try? NSKeyedArchiver.archivedData(withRootObject: activeColor, requiringSecureCoding: true)
    }

    // MARK: – Styling
    //
    // Each setter becomes the default for new annotations and applies to the
    // selection (one undo step per slider drag) and to text being typed.

    func setActiveColor(_ color: NSColor) {
        activeColor = color
        if let target = textSession?.target {
            target.color = color
            syncEditorStyle()
        }
        // Blur, pixelate, and spotlight have no color of their own.
        let targets = selectedObjects.filter { !AnnotationRenderer.isScreenshotEffect($0) }
        guard !targets.isEmpty else { return }
        pushUndo(coalescing: "color")
        for obj in targets {
            obj.color = color
        }
        setNeedsDisplay(bounds)
    }

    func setActiveLineWidth(_ lineWidth: CGFloat) {
        activeLineWidth = lineWidth
        let targets = selectedObjects.filter { Self.usesLineWidth($0) }
        guard !targets.isEmpty else { return }
        pushUndo(coalescing: "lineWidth")
        for obj in targets {
            obj.lineWidth = Self.isHighlighter(obj) ? Self.highlighterWidth(forSize: lineWidth) : lineWidth
        }
        setNeedsDisplay(bounds)
    }

    /// Highlighters share the Size slider with the pens but run much wider:
    /// the default size (3) draws the classic 16 pt marker.
    static func highlighterWidth(forSize size: CGFloat) -> CGFloat {
        (size * 16 / 3).rounded()
    }

    static func isHighlighter(_ object: any AnnotationObject) -> Bool {
        object is HighlighterAnnotation || (object as? FreehandAnnotation)?.isHighlighter == true
    }

    static func usesLineWidth(_ object: any AnnotationObject) -> Bool {
        !(object is TextAnnotation || object is NumberedStepAnnotation || object is CalloutAnnotation
          || AnnotationRenderer.isScreenshotEffect(object))
    }

    func setActiveFontSize(_ size: CGFloat) {
        activeFontSize = size
        applyTextStyle(coalescing: "fontSize") { text in text.fontSize = size } callout: { callout in callout.fontSize = size }
    }

    func setActiveTextBold(_ bold: Bool) {
        activeTextBold = bold
        applyTextStyle(coalescing: "bold") { text in text.isBold = bold } callout: { callout in callout.isBold = bold }
    }

    private func applyTextStyle(coalescing key: String, text: (TextAnnotation) -> Void, callout: (CalloutAnnotation) -> Void) {
        switch textSession?.target {
        case let target as TextAnnotation:    text(target); syncEditorStyle()
        case let target as CalloutAnnotation: callout(target); syncEditorStyle()
        default: break
        }
        let targets = selectedObjects.filter { $0 is TextAnnotation || $0 is CalloutAnnotation }
        guard !targets.isEmpty else { return }
        pushUndo(coalescing: key)
        for obj in targets {
            if let target = obj as? TextAnnotation { text(target) }
            if let target = obj as? CalloutAnnotation { callout(target) }
        }
        setNeedsDisplay(bounds)
    }

    func setActiveRedactionStrength(_ strength: CGFloat) {
        let strength = min(max(strength, AnnotationRedaction.strengthRange.lowerBound), AnnotationRedaction.strengthRange.upperBound)
        activeRedactionStrength = strength
        let targets = selectedObjects.filter { $0 is BlurAnnotation || $0 is PixelateAnnotation }
        guard !targets.isEmpty else { return }
        pushUndo(coalescing: "strength")
        for obj in targets {
            (obj as? BlurAnnotation)?.strength = strength
            (obj as? PixelateAnnotation)?.strength = strength
        }
        setNeedsDisplay(bounds)
    }

    func setRoundedRectangles(_ rounded: Bool) {
        roundedRectangles = rounded
        let targets = selectedObjects.compactMap { $0 as? RectangleAnnotation }
        if !targets.isEmpty {
            pushUndo()
            for rectangle in targets {
                rectangle.cornerRadius = rounded ? RectangleAnnotation.roundedCornerRadius : 0
            }
            setNeedsDisplay(bounds)
        }
        onOptionsChanged?()
    }

    func setSpotlightEllipse(_ ellipse: Bool) {
        spotlightEllipse = ellipse
        let targets = selectedObjects.compactMap { $0 as? SpotlightAnnotation }
        if !targets.isEmpty {
            pushUndo()
            for spotlight in targets {
                spotlight.isEllipse = ellipse
            }
            setNeedsDisplay(bounds)
        }
        onOptionsChanged?()
    }

    func setBackgroundOptions(_ options: ScreenshotBackgroundOptions) {
        commitTextField()
        guard options != backgroundOptions else { return }
        pushUndo(coalescing: "background")
        backgroundOptions = options
        updateLayout(refit: false)
    }

    /// What the toolbar's options area shows: the selection's settings, or
    /// the active tool's defaults.
    var toolOptions: AnnotationToolOptions {
        var options = AnnotationToolOptions(
            context: .none,
            lineWidth: activeLineWidth,
            roundedCorners: roundedRectangles,
            fontSize: activeFontSize,
            isBold: activeTextBold,
            redactionStrength: activeRedactionStrength,
            spotlightEllipse: spotlightEllipse,
            canApplyCrop: canApplyCrop,
            canResetCrop: canResetCrop
        )
        if isEditingCrop {
            options.context = .crop
            return options
        }
        let styled = textSession?.target ?? selectedObjects.first
        guard let styled else {
            options.context = AnnotationToolOptions.context(for: activeTool)
            return options
        }
        options.context = AnnotationToolOptions.context(for: styled)
        switch styled {
        case let rectangle as RectangleAnnotation:
            options.lineWidth = rectangle.lineWidth
            options.roundedCorners = rectangle.cornerRadius > 0
        case let text as TextAnnotation:
            options.fontSize = text.fontSize
            options.isBold = text.isBold
        case let callout as CalloutAnnotation:
            options.fontSize = callout.fontSize
            options.isBold = callout.isBold
        case let blur as BlurAnnotation:
            options.redactionStrength = blur.strength
        case let pixelate as PixelateAnnotation:
            options.redactionStrength = pixelate.strength
        case let spotlight as SpotlightAnnotation:
            options.spotlightEllipse = spotlight.isEllipse
        default:
            if Self.isHighlighter(styled) {
                options.lineWidth = styled.lineWidth * 3 / 16
            } else if Self.usesLineWidth(styled) {
                options.lineWidth = styled.lineWidth
            }
        }
        return options
    }

    // MARK: – Undo / Redo
    //
    // A snapshot is the whole document — objects, crop, and backdrop — so
    // undo restores exactly what an export would have shown. Revisions
    // identify document states: saving records the current one, and the
    // editor is dirty whenever the document isn't at that revision (undoing
    // back to it counts as clean).

    private struct Snapshot {
        let objects: [any AnnotationObject]
        let crop: CGRect?
        let backgroundOptions: ScreenshotBackgroundOptions
        let revision: Int
    }

    private var undoSnapshots: [Snapshot] = []
    private var redoSnapshots: [Snapshot] = []
    private var redoBeforeLastPush: [Snapshot] = []
    private(set) var documentRevision = 0
    private var savedRevision = 0
    private var lastRevision = 0
    private var coalescingKey: String?
    private var coalescingDate: Date?

    var hasUnsavedChanges: Bool { documentRevision != savedRevision }
    var canUndo: Bool { !undoSnapshots.isEmpty }
    var canRedo: Bool { !redoSnapshots.isEmpty }

    /// Records that the document was saved or copied. Pass the revision that
    /// was exported so a slow save can't mark later edits as saved.
    func markSaved(revision: Int? = nil) {
        guard revision == nil || revision == documentRevision else { return }
        savedRevision = documentRevision
        onDirtyStateChanged?()
    }

    private var snapshot: Snapshot {
        Snapshot(objects: objects.map { $0.copy() }, crop: appliedCrop,
                 backgroundOptions: backgroundOptions, revision: documentRevision)
    }

    /// Call before every document edit. Edits with the same `coalescing` key
    /// less than a second apart share one undo step (slider drags, the color
    /// panel, arrow-key nudges); any other edit ends the burst.
    func pushUndo(coalescing key: String? = nil) {
        let now = Date()
        let continuesBurst = key != nil && key == coalescingKey
            && now.timeIntervalSince(coalescingDate ?? .distantPast) < 1
        if !continuesBurst {
            undoSnapshots.append(snapshot)
            redoBeforeLastPush = redoSnapshots
            redoSnapshots.removeAll()
        }
        coalescingKey = key
        coalescingDate = key == nil ? nil : now
        lastRevision += 1
        documentRevision = lastRevision
        onDirtyStateChanged?()
    }

    /// Takes back the last `pushUndo` when the edit it announced didn't happen.
    private func discardLastUndo() {
        guard let last = undoSnapshots.popLast() else { return }
        redoSnapshots = redoBeforeLastPush
        coalescingKey = nil
        documentRevision = last.revision
        onDirtyStateChanged?()
    }

    /// A drag is under way: undo waits for it to end, or the drag would
    /// finish on top of the restored state and leave it looking saved. The
    /// button check keeps a mouse-up lost to a modal from blocking undo.
    private var isDragging: Bool {
        (dragStart != nil || currentObject != nil || selectDragStart != nil || cropDrag != nil) && Self.mouseButtonIsDown()
    }

    static var mouseButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    func performUndo() {
        guard !isDragging else { return NSSound.beep() }
        commitTextField()
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(snapshot)
        restore(previous)
    }

    func performRedo() {
        guard !isDragging else { return NSSound.beep() }
        commitTextField()
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(snapshot)
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        coalescingKey = nil
        objects = snapshot.objects
        selectedObjects = []
        hoveredObjectID = nil
        let cropChanged = appliedCrop != snapshot.crop
        let backdropChanged = backgroundOptions != snapshot.backgroundOptions
        appliedCrop = snapshot.crop
        backgroundOptions = snapshot.backgroundOptions
        if isEditingCrop { pendingCrop = appliedCrop }
        documentRevision = snapshot.revision
        if backdropChanged { onBackgroundOptionsChanged?(backgroundOptions) }
        if cropChanged || backdropChanged {
            updateLayout(refit: cropChanged)
        } else {
            setNeedsDisplay(bounds)
        }
        onCropStateChanged?()
        onDirtyStateChanged?()
    }

    // MARK: – Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘Return finishes the text being typed (Return adds a line).
        if activeTextEditor != nil, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            commitTextField()
            return true
        }
        // Save and close work even while text is being typed — the text
        // commits first.
        guard flags.isDisjoint(with: [.shift, .option, .control]) else {
            return super.performKeyEquivalent(with: event)
        }
        switch AnnotationKeyboard.latinKey(for: event) {
        case "s":
            onSaveRequested?()
            return true
        case "w":
            window?.performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let key = AnnotationKeyboard.latinKey(for: event)

        // ⌘-key editor shortcuts: undo/redo, save, copy, close, zoom. Keys
        // are matched by their Latin letter so they work on any layout.
        if flags.contains(.command) {
            switch key {
            case "z":
                if flags.contains(.shift) {
                    performRedo()
                } else {
                    performUndo()
                }
                return
            case "s":
                onSaveRequested?()
                return
            case "c":
                // Only when no text annotation is being edited — copying inside
                // an active text field must keep native behavior
                if activeTextEditor == nil {
                    onCopyRequested?()
                    return
                }
            case "w":
                window?.performClose(nil)
                return
            case "=", "+":
                if let scrollView = enclosingScrollView, scrollView.allowsMagnification {
                    zoom(to: scrollView.magnification * 1.25, in: scrollView)
                    return
                }
            case "-":
                if let scrollView = enclosingScrollView, scrollView.allowsMagnification {
                    zoom(to: scrollView.magnification / 1.25, in: scrollView)
                    return
                }
            case "0":
                if let scrollView = enclosingScrollView, scrollView.allowsMagnification {
                    zoom(to: 1, in: scrollView) // Actual size
                    return
                }
            default: break
            }
        }

        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelected()
            return
        case kVK_Escape: // Escape: leave crop editing first, else clear selection
            if isEditingCrop {
                cancelCropEditing()
            } else if !selectedObjects.isEmpty {
                selectedObjects = []
                setNeedsDisplay(bounds)
            }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if isEditingCrop {
                applyCrop()
                return
            }
        default:
            break
        }

        // Arrow keys nudge the current selection (1px, ⇧ = 10px)
        if !flags.contains(.command), let delta = nudgeDelta(for: event) {
            nudgeSelection(by: delta)
            return
        }

        // Single-key tool shortcuts (only when no text field is active and no command key)
        if activeTextEditor == nil, !flags.contains(.command), !flags.contains(.control), let key {
            if key == "r", flags.contains(.option) {
                toggleRoundedCorners()
                return
            }
            if let tool = AnnotationTool.forShortcut(key, shift: flags.contains(.shift)) {
                activeTool = tool
                return
            }
        }
    }

    /// ⌥R: rounded corners on or off for rectangles (switching to the
    /// rectangle tool unless a rectangle is selected).
    func toggleRoundedCorners() {
        let rectangleSelected = selectedObjects.contains { $0 is RectangleAnnotation }
        if !rectangleSelected, activeTool != .rectangle, activeTool != .filledRectangle {
            activeTool = .rectangle
        }
        setRoundedRectangles(!roundedRectangles)
    }

    func deleteSelected() {
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        let ids = Set(selectedObjects.map(\.id))
        objects.removeAll { ids.contains($0.id) }
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    // MARK: – Zoom

    private func zoom(to magnification: CGFloat, in scrollView: NSScrollView) {
        // Keep the current visible center stable while zooming
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        scrollView.setMagnification(magnification, centeredAt: center)
        setNeedsDisplay(bounds) // chrome keeps its on-screen size
    }

    // MARK: – Arrow-key nudging

    private func nudgeDelta(for event: NSEvent) -> CGPoint? {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_LeftArrow:  return CGPoint(x: -step, y: 0)
        case kVK_RightArrow: return CGPoint(x: step, y: 0)
        case kVK_DownArrow:  return CGPoint(x: 0, y: step)   // isFlipped: +y is down
        case kVK_UpArrow:    return CGPoint(x: 0, y: -step)
        default:             return nil
        }
    }

    private func nudgeSelection(by delta: CGPoint) {
        guard !selectedObjects.isEmpty else { return }
        // A burst of nudges is one undo step; any other edit or a >1s pause
        // ends it.
        pushUndo(coalescing: "nudge")
        let previousRects = selectedObjects.map(\.bounds)
        for obj in selectedObjects {
            obj.move(by: delta)
        }
        if selectedObjects.contains(where: { $0 is SpotlightAnnotation }) {
            setNeedsDisplay(bounds)
            return
        }
        for rect in previousRects + selectedObjects.map(\.bounds) {
            setNeedsDisplay(documentRect: rect, padding: 12)
        }
    }

    // MARK: – Export

    /// The annotated screenshot at the screenshot's own pixel size, with no
    /// editing chrome (selection, hover, crop overlay) — independent of the
    /// window and the display it's on.
    func flatten() -> NSImage {
        let exportLayout = AnnotationCanvasLayout(
            imageSize: layout.imageSize,
            crop: appliedCrop,
            padding: layout.padding
        )
        let scene = AnnotationRenderer.Scene(
            image: backgroundImage,
            layout: exportLayout,
            backgroundOptions: backgroundOptions,
            objects: objects,
            fallbackSize: bounds.size
        )
        return renderer.export(scene) ?? NSImage()
    }

    // MARK: – Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    override func accessibilityLabel() -> String? { "Screenshot canvas" }

    override func accessibilityValue() -> Any? {
        let count = objects.count
        var value = count == 1 ? "1 annotation" : "\(count) annotations"
        if let selected = selectedObjects.first {
            value += ", \(Self.accessibilityName(for: selected)) selected"
        }
        if isEditingCrop { value += ", cropping" }
        return value
    }

    override func accessibilityHelp() -> String? {
        "Draw with the selected tool. Tool shortcuts: V select, A arrow, R rectangle, T text, O callout, "
            + "H highlighter, B blur, P pixelate, S spotlight, C crop."
    }

    override func accessibilityChildren() -> [Any]? {
        let annotations: [Any] = objects.map { object in
            let frame = window.map { $0.convertToScreen(convert(viewRect(fromDocument: selectionFrame(for: object)), to: nil)) } ?? .zero
            let element = NSAccessibilityElement.element(
                withRole: .layoutItem,
                frame: frame,
                label: Self.accessibilityName(for: object),
                parent: self
            ) as AnyObject
            return element
        }
        return (super.accessibilityChildren() ?? []) + annotations
    }

    static func accessibilityName(for object: any AnnotationObject) -> String {
        switch object {
        case let text as TextAnnotation:            return "Text: \(text.text)"
        case let callout as CalloutAnnotation:      return "Callout: \(callout.text)"
        case let step as NumberedStepAnnotation:    return "Step \(step.number)"
        case is ArrowAnnotation:                    return "Arrow"
        case let rectangle as RectangleAnnotation:
            let shape = rectangle.cornerRadius > 0 ? "rounded rectangle" : "rectangle"
            return rectangle.filled ? "Filled \(shape)" : (rectangle.cornerRadius > 0 ? "Rounded rectangle" : "Rectangle")
        case is EllipseAnnotation:                  return "Ellipse"
        case is LineAnnotation:                     return "Line"
        case let freehand as FreehandAnnotation:    return freehand.isHighlighter ? "Freehand highlight" : "Drawing"
        case is HighlighterAnnotation:              return "Highlight"
        case is BlurAnnotation:                     return "Blurred area"
        case is PixelateAnnotation:                 return "Pixelated area"
        case is SpotlightAnnotation:                return "Spotlight"
        default:                                    return "Annotation"
        }
    }
}

// MARK: – NSTextViewDelegate

extension AnnotationCanvas: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let editor = activeTextEditor, notification.object as AnyObject? === editor,
              let target = textSession?.target else { return }
        // Live, so a callout's bubble grows as you type.
        (target as? TextAnnotation)?.text = editor.string
        (target as? CalloutAnnotation)?.text = editor.string
        editor.fitToText()
        positionTextEditor()
        setNeedsDisplay(bounds)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as AnyObject? === activeTextEditor else { return }
        editorJustLostFocus = true
        DispatchQueue.main.async { [weak self] in self?.editorJustLostFocus = false }
        commitTextField()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        textUndoManager
    }
}

// MARK: – Toolbar options model

/// What the toolbar's contextual options area shows, and the values in it.
struct AnnotationToolOptions: Equatable {
    enum Context: Equatable {
        case none, stroke, rectangle, text, redaction, spotlight, crop
    }

    var context: Context = .none
    var lineWidth: CGFloat = 3
    var roundedCorners = false
    var fontSize: CGFloat = 18
    var isBold = true
    var redactionStrength: CGFloat = AnnotationRedaction.defaultStrength
    var spotlightEllipse = false
    var canApplyCrop = false
    var canResetCrop = false

    static func context(for tool: AnnotationTool) -> Context {
        switch tool {
        case .select, .numberedStep:                                        return .none
        case .arrow, .ellipse, .line, .freehand, .highlighter, .freehandHighlighter: return .stroke
        case .rectangle, .filledRectangle:                                  return .rectangle
        case .text, .callout:                                               return .text
        case .blur, .pixelate:                                              return .redaction
        case .spotlight:                                                    return .spotlight
        case .crop:                                                         return .crop
        }
    }

    static func context(for object: any AnnotationObject) -> Context {
        switch object {
        case is RectangleAnnotation:                        return .rectangle
        case is TextAnnotation, is CalloutAnnotation:       return .text
        case is BlurAnnotation, is PixelateAnnotation:      return .redaction
        case is SpotlightAnnotation:                        return .spotlight
        case is NumberedStepAnnotation:                     return .none
        default:                                            return .stroke
        }
    }
}

// MARK: – Keyboard layouts

enum AnnotationKeyboard {
    /// The Latin character a key types, so letter shortcuts keep working on
    /// non-Latin layouts (Russian, Greek, Hebrew…) — the way macOS matches
    /// menu shortcuts. Latin layouts (AZERTY, Dvorak) keep their own letters.
    @MainActor
    static func latinKey(for event: NSEvent) -> String? {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1,
           typed.unicodeScalars.allSatisfy(\.isASCII) {
            return typed
        }
        return asciiCapableCharacter(forKeyCode: event.keyCode) ?? ansiCharacters[event.keyCode]
    }

    /// What the key produces on the user's ASCII-capable layout (the Latin
    /// layout macOS pairs with a non-Latin one).
    @MainActor // `TISGetInputSourceProperty` must run on the main thread.
    private static func asciiCapableCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length).lowercased()
        guard string.count == 1, string.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return string
    }

    /// US-layout fallback by physical key, if the layout can't be read.
    private static let ansiCharacters: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_D): "d",
        UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h",
        UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o", UInt16(kVK_ANSI_P): "p",
        UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_0): "0",
    ]
}
