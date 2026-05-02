import AppKit

/// The main drawing surface for the annotation editor.
/// Handles tool interaction, renders all annotation objects, and manages undo.
@MainActor
final class AnnotationCanvas: NSView {

    // MARK: – State

    var backgroundImage: NSImage?
    var objects: [any AnnotationObject] = []
    var selectedObjects: [any AnnotationObject] = []
    var activeTool: AnnotationTool = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
            onToolChanged?(activeTool)
        }
    }
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3

    var onToolChanged: ((AnnotationTool) -> Void)?

    // Undo/redo managed via undoSnapshots/redoSnapshots below

    // In-progress drawing state
    private var currentObject: (any AnnotationObject)?
    private var dragStart: CGPoint?
    private var lastDragPoint: CGPoint?

    // Text editing
    private var activeTextField: NSTextField?

    // Crop overlay
    var cropRect: CGRect?
    var onCropChanged: ((CGRect?) -> Void)?

    // MARK: – Init

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true } // Easier coordinate math (top-left origin)

    // MARK: - Cursor Management

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        switch activeTool {
        case .select:                                      cursor = .arrow
        case .arrow, .rectangle, .filledRectangle, .ellipse: cursor = .crosshair
        case .line, .freehand, .highlighter:               cursor = .crosshair
        case .text:                                        cursor = .iBeam
        case .numberedStep:                                cursor = .pointingHand
        case .blur, .pixelate, .crop:                      cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: – Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Background image
        if let img = backgroundImage {
            img.draw(in: bounds)
        }

        // 2. Blur and pixelate (CIFilter applied to background region)
        for obj in objects {
            if let blur = obj as? BlurAnnotation {
                drawBlur(blur, ctx: ctx)
            } else if let px = obj as? PixelateAnnotation {
                drawPixelate(px, ctx: ctx)
            }
        }

        // 3. All other annotations
        for obj in objects {
            if obj is BlurAnnotation || obj is PixelateAnnotation { continue }
            obj.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
        }

        // 4. In-progress object
        currentObject?.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)

        // 5. Selection handles
        for obj in selectedObjects {
            drawSelectionHandle(for: obj, ctx: ctx)
        }

        // 6. Crop overlay
        if let crop = cropRect {
            drawCropOverlay(crop, ctx: ctx)
        }
    }

    /// Convert a view rect (flipped, top-left origin) to CGImage coordinates (also top-left origin).
    private func viewRectToCGImageRect(_ viewRect: CGRect, imageSize: CGSize) -> CGRect {
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        return CGRect(
            x: viewRect.origin.x * scaleX,
            y: viewRect.origin.y * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY
        )
    }

    private func drawBlur(_ blur: BlurAnnotation, ctx: CGContext) {
        if blur.rect == blur.cachedRect, let cached = blur.cachedRender {
            cached.draw(in: blur.rect)
            return
        }
        guard let bg = backgroundImage, let cgImg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let imgSize = CGSize(width: cgImg.width, height: cgImg.height)
        let cropRect = viewRectToCGImageRect(blur.rect, imageSize: imgSize)
        guard let croppedCG = cgImg.cropping(to: cropRect) else { return }
        let ci = CIImage(cgImage: croppedCG)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(blur.radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return }
        let clamped = output.cropped(to: ci.extent)
        let rep = NSCIImageRep(ciImage: clamped)
        let result = NSImage(size: blur.rect.size)
        result.addRepresentation(rep)
        result.draw(in: blur.rect)
        blur.cachedRender = result
        blur.cachedRect = blur.rect
    }

    private func drawPixelate(_ px: PixelateAnnotation, ctx: CGContext) {
        if px.rect == px.cachedRect, let cached = px.cachedRender {
            cached.draw(in: px.rect)
            return
        }
        guard let bg = backgroundImage, let cgImg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let imgSize = CGSize(width: cgImg.width, height: cgImg.height)
        let cropRect = viewRectToCGImageRect(px.rect, imageSize: imgSize)
        guard let cropped = cgImg.cropping(to: cropRect) else { return }
        let ci = CIImage(cgImage: cropped)
        guard let filter = CIFilter(name: "CIPixellate") else { return }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(max(px.scale, 4), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return }
        let clamped = output.cropped(to: ci.extent)
        let rep = NSCIImageRep(ciImage: clamped)
        let result = NSImage(size: px.rect.size)
        result.addRepresentation(rep)
        result.draw(in: px.rect)
        px.cachedRender = result
        px.cachedRect = px.rect
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

        let inset: CGFloat = 4
        let expanded = obj.bounds.insetBy(dx: -inset, dy: -inset)

        ctx.saveGState()

        let accent = NSColor.controlAccentColor
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(expanded)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setShadow(offset: .zero, blur: 0)

        for handle in ResizeHandle.allCases {
            drawResizeHandle(at: resizeHandleCenter(for: expanded, handle: handle), handle: handle, accent: accent, ctx: ctx)
        }

        ctx.restoreGState()
    }

    private func drawEndpointSelection(start: CGPoint, end: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawRoundHandle(at: start, radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: end, radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        ctx.restoreGState()
    }

    private func drawArrowSelection(for arrow: ArrowAnnotation, ctx: CGContext) {
        ctx.saveGState()

        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
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
        ctx.setLineWidth(1)
        ctx.move(to: curveMidpoint)
        ctx.addLine(to: controlPoint)
        ctx.strokePath()

        drawRoundHandle(at: arrow.handlePoint(.start), radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: arrow.handlePoint(.end), radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: controlPoint, radius: 7.5, fill: accent, stroke: .white, ctx: ctx)

        ctx.restoreGState()
    }

    private func drawRoundHandle(at point: CGPoint, radius: CGFloat, fill: NSColor, stroke: NSColor, ctx: CGContext) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)
    }

    private func drawResizeHandle(at point: CGPoint, handle: ResizeHandle, accent: NSColor, ctx: CGContext) {
        let radius: CGFloat = isCornerHandle(handle) ? 5.5 : 4.5
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

    private func drawCropOverlay(_ crop: CGRect, ctx: CGContext) {
        ctx.saveGState()
        // Dim outside crop
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        let outer = bounds
        for rect in [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: crop.minY - outer.minY),
            CGRect(x: outer.minX, y: crop.maxY, width: outer.width, height: outer.maxY - crop.maxY),
            CGRect(x: outer.minX, y: crop.minY, width: crop.minX - outer.minX, height: crop.height),
            CGRect(x: crop.maxX, y: crop.minY, width: outer.maxX - crop.maxX, height: crop.height),
        ] {
            ctx.fill(rect)
        }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(crop)
        ctx.restoreGState()
    }

    // MARK: – Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitTextField()

        if activeTool == .select {
            handleSelectDown(point: point)
            return
        }
        if activeTool == .crop {
            dragStart = point
            cropRect = CGRect(origin: point, size: .zero)
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
            setNeedsDisplay(bounds)
            return
        }

        pushUndo()
        dragStart = point
        lastDragPoint = point
        currentObject = makeObject(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select {
            handleSelectDrag(point: point)
            return
        }
        if activeTool == .crop, let start = dragStart {
            let previous = cropRect
            cropRect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            onCropChanged?(cropRect)
            invalidate(previous, cropRect, padding: 2)
            return
        }

        let previousBounds = currentObject?.bounds
        updateCurrentObject(to: point)
        lastDragPoint = point
        invalidate(previousBounds, currentObject?.bounds, padding: activeLineWidth + 12)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select {
            handleSelectUp(point: point)
            return
        }
        if activeTool == .crop {
            onCropChanged?(cropRect)
            dragStart = nil
            return
        }
        if let obj = currentObject {
            objects.append(obj)
            currentObject = nil
        }
        dragStart = nil
        setNeedsDisplay(bounds)
    }

    // MARK: – Select tool

    private var selectDragStart: CGPoint?
    private var selectObjectStart: [(UUID, CGPoint)] = []
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
        case resize(any AnnotationObject, ResizeHandle)
    }

    private enum EndpointHandle {
        case start, end
    }

    private func handleSelectDown(point: CGPoint) {
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

        let hit = objects.last(where: { $0.contains(point: point) })
        if let hit {
            if !selectedObjects.contains(where: { $0.id == hit.id }) {
                selectedObjects = [hit]
            }
            selectDragStart = point
            selectDragAction = .move
            didPushSelectMoveUndo = false
            selectObjectStart = selectedObjects.map { ($0.id, CGPoint(x: $0.bounds.origin.x, y: $0.bounds.origin.y)) }
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
        case .resize(let object, let handle):
            resize(object, handle: handle, by: delta)
        case .move, nil:
            for obj in selectedObjects {
                obj.move(by: delta)
            }
        }
        selectDragStart = point
        let currentRects = selectedObjects.map(\.bounds)
        for rect in previousRects + currentRects {
            setNeedsDisplay(rect.insetBy(dx: -12, dy: -12).intersection(bounds))
        }
    }

    private func handleSelectUp(point: CGPoint) {
        selectDragStart = nil
        selectDragAction = nil
        didPushSelectMoveUndo = false
    }

    private func editHandleHit(at point: CGPoint) -> (object: (any AnnotationObject)?, action: SelectDragAction)? {
        for obj in selectedObjects.reversed() {
            if let arrow = obj as? ArrowAnnotation {
                for handle in [ArrowHandle.control, .end, .start] {
                    let center = arrow.handlePoint(handle)
                    let radius = handle == .control ? CGFloat(9) : CGFloat(8)
                    if hit(point, center: center, radius: radius + 4) {
                        return (arrow, .arrowHandle(arrow, handle))
                    }
                }
                continue
            }

            if let line = obj as? LineAnnotation {
                if hit(point, center: line.startPoint, radius: 10) { return (line, .lineEndpoint(line, .start)) }
                if hit(point, center: line.endPoint, radius: 10) { return (line, .lineEndpoint(line, .end)) }
                continue
            }

            if let highlighter = obj as? HighlighterAnnotation {
                if hit(point, center: highlighter.startPoint, radius: 10) { return (highlighter, .highlighterEndpoint(highlighter, .start)) }
                if hit(point, center: highlighter.endPoint, radius: 10) { return (highlighter, .highlighterEndpoint(highlighter, .end)) }
                continue
            }

            let expanded = obj.bounds.insetBy(dx: -4, dy: -4)
            for handle in ResizeHandle.allCases {
                if hit(point, center: resizeHandleCenter(for: expanded, handle: handle), radius: 10) {
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
            blur.cachedRender = nil
        case let pixelate as PixelateAnnotation:
            pixelate.rect = newRect
            pixelate.cachedRender = nil
        case let text as TextAnnotation:
            let oldHeight = max(sourceRect.height, 1)
            let scale = max(newRect.height, 1) / oldHeight
            text.origin = newRect.origin
            text.fontSize = min(96, max(8, text.fontSize * scale))
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
        case .rectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: false)
            r.color = activeColor; r.lineWidth = activeLineWidth; return r
        case .filledRectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: true)
            r.color = activeColor; r.lineWidth = activeLineWidth; return r
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
            h.color = activeColor; return h
        case .blur:
            let b = BlurAnnotation(rect: CGRect(origin: point, size: .zero))
            return b
        case .pixelate:
            let p = PixelateAnnotation(rect: CGRect(origin: point, size: .zero))
            return p
        default: return nil
        }
    }

    private func updateCurrentObject(to point: CGPoint) {
        guard let start = dragStart else { return }
        switch currentObject {
        case let a as ArrowAnnotation:       a.endPoint = point
        case let r as RectangleAnnotation:   r.rect = rectFrom(start, to: point)
        case let e as EllipseAnnotation:     e.rect = rectFrom(start, to: point)
        case let l as LineAnnotation:        l.endPoint = point
        case let f as FreehandAnnotation:
            if let last = f.points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
            f.points.append(point)
        case let h as HighlighterAnnotation: h.endPoint = point
        case let b as BlurAnnotation:        b.rect = rectFrom(start, to: point)
        case let p as PixelateAnnotation:    p.rect = rectFrom(start, to: point)
        default: break
        }
    }

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }

    private func invalidate(_ oldRect: CGRect?, _ newRect: CGRect?, padding: CGFloat) {
        if let oldRect {
            setNeedsDisplay(oldRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
        if let newRect {
            setNeedsDisplay(newRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
    }

    private func nextStepNumber() -> Int {
        let existing = objects.compactMap { ($0 as? NumberedStepAnnotation)?.number }
        return (existing.max() ?? 0) + 1
    }

    // MARK: – Text

    private func beginTextEntry(at point: CGPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 20, width: 200, height: 30))
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = true
        field.font = .boldSystemFont(ofSize: 18)
        field.textColor = activeColor
        field.placeholderString = "Type here…"
        field.delegate = self
        addSubview(field)
        field.becomeFirstResponder()
        activeTextField = field
    }

    func commitTextField() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            pushUndo()
            let ann = TextAnnotation(origin: field.frame.origin)
            ann.text = text
            ann.color = activeColor
            ann.fontSize = 18
            objects.append(ann)
        }
        field.removeFromSuperview()
        activeTextField = nil
        setNeedsDisplay(bounds)
    }

    // MARK: – Styling

    func setActiveColor(_ color: NSColor) {
        activeColor = color
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        for obj in selectedObjects {
            obj.color = color
        }
        setNeedsDisplay(bounds)
    }

    func setActiveLineWidth(_ lineWidth: CGFloat) {
        activeLineWidth = lineWidth
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        for obj in selectedObjects where !(obj is TextAnnotation) && !(obj is NumberedStepAnnotation) {
            obj.lineWidth = lineWidth
        }
        setNeedsDisplay(bounds)
    }

    // MARK: – Undo / Redo
    //
    // Undo snapshots store a *count* of objects at that point.
    // Since objects are only appended (not mutated in undo-tracked operations),
    // we can restore by trimming back to that count.
    // For delete operations, we store the full removed array.

    private var undoSnapshots: [(objects: [any AnnotationObject], selected: [any AnnotationObject])] = []
    private var redoSnapshots: [(objects: [any AnnotationObject], selected: [any AnnotationObject])] = []

    func pushUndo() {
        undoSnapshots.append((objects: objects.map { $0.copy() }, selected: selectedObjects.map { $0.copy() }))
        redoSnapshots.removeAll()
    }

    func performUndo() {
        guard let prev = undoSnapshots.popLast() else { return }
        redoSnapshots.append((objects: objects.map { $0.copy() }, selected: selectedObjects.map { $0.copy() }))
        objects = prev.objects
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    func performRedo() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append((objects: objects.map { $0.copy() }, selected: selectedObjects.map { $0.copy() }))
        objects = next.objects
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Z / ⌘⇧Z for undo/redo
        if event.modifierFlags.contains(.command) && event.keyCode == 6 {
            if event.modifierFlags.contains(.shift) {
                performRedo()
            } else {
                performUndo()
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete/Backspace
            deleteSelected()
            return
        }

        // Single-key tool shortcuts (only when no text field is active and no command key)
        if activeTextField == nil && !event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": activeTool = .select; return
            case "a": activeTool = .arrow; return
            case "r":
                if event.modifierFlags.contains(.shift) { activeTool = .filledRectangle }
                else { activeTool = .rectangle }
                return
            case "e": activeTool = .ellipse; return
            case "l": activeTool = .line; return
            case "d": activeTool = .freehand; return
            case "t": activeTool = .text; return
            case "n": activeTool = .numberedStep; return
            case "h": activeTool = .highlighter; return
            case "b": activeTool = .blur; return
            case "p": activeTool = .pixelate; return
            case "c": activeTool = .crop; return
            default: break
            }
        }
    }

    func deleteSelected() {
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        let ids = Set(selectedObjects.map(\.id))
        objects.removeAll { ids.contains($0.id) }
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    // MARK: – Crop

    func applyCrop() -> NSImage? {
        guard let crop = cropRect, !crop.isEmpty else { return nil }
        
        // Flatten the canvas first so annotations are preserved in the crop
        let flat = flatten()
        let result = NSImage(size: crop.size)
        
        // NSImage drawing context is bottom-up (origin at bottom-left).
        // Our canvas is top-down (isFlipped = true). 
        // We must flip the crop rectangle's Y coordinate before drawing from it!
        var flippedCrop = crop
        flippedCrop.origin.y = bounds.height - crop.maxY
        
        result.lockFocus()
        flat.draw(in: CGRect(origin: .zero, size: crop.size),
                  from: flippedCrop, operation: .copy, fraction: 1)
        result.unlockFocus()
        
        cropRect = nil
        return result
    }

    // MARK: – Flatten to NSImage

    func flatten() -> NSImage {
        // Temporarily hide editing chrome so it doesn't get saved into the final image.
        let oldCrop = cropRect
        let oldSelection = selectedObjects
        cropRect = nil
        selectedObjects = []
        
        // cacheDisplay(in:to:) correctly respects the view's isFlipped = true state,
        // avoiding the dreaded upside-down or shifted annotation bug caused by NSImage.lockFocus()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            cropRect = oldCrop
            selectedObjects = oldSelection
            return NSImage()
        }
        cacheDisplay(in: bounds, to: rep)

        cropRect = oldCrop
        selectedObjects = oldSelection
        
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: – NSTextFieldDelegate

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commitTextField() }
}
