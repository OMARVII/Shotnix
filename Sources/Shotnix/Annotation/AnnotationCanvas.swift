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
        let inset: CGFloat = 4
        let expanded = obj.bounds.insetBy(dx: -inset, dy: -inset)

        ctx.saveGState()

        // Dashed selection border
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.stroke(expanded)
        ctx.setLineDash(phase: 0, lengths: [])

        // 8 resize handles (corners + midpoints)
        let handleSize: CGFloat = 8
        for handleRect in resizeHandleRects(for: expanded, size: handleSize) {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(handleRect)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(handleRect)
        }

        ctx.restoreGState()
    }

    private func resizeHandleRects(for rect: CGRect, size: CGFloat) -> [CGRect] {
        let hs = size / 2
        return [
            CGRect(x: rect.minX - hs, y: rect.minY - hs, width: size, height: size),  // top-left (flipped)
            CGRect(x: rect.midX - hs, y: rect.minY - hs, width: size, height: size),  // top-center
            CGRect(x: rect.maxX - hs, y: rect.minY - hs, width: size, height: size),  // top-right
            CGRect(x: rect.minX - hs, y: rect.midY - hs, width: size, height: size),  // left-center
            CGRect(x: rect.maxX - hs, y: rect.midY - hs, width: size, height: size),  // right-center
            CGRect(x: rect.minX - hs, y: rect.maxY - hs, width: size, height: size),  // bottom-left
            CGRect(x: rect.midX - hs, y: rect.maxY - hs, width: size, height: size),  // bottom-center
            CGRect(x: rect.maxX - hs, y: rect.maxY - hs, width: size, height: size),  // bottom-right
        ]
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

    private func handleSelectDown(point: CGPoint) {
        let hit = objects.last(where: { $0.contains(point: point) })
        if let hit {
            if !selectedObjects.contains(where: { $0.id == hit.id }) {
                selectedObjects = [hit]
            }
            selectDragStart = point
            didPushSelectMoveUndo = false
            selectObjectStart = selectedObjects.map { ($0.id, CGPoint(x: $0.bounds.origin.x, y: $0.bounds.origin.y)) }
        } else {
            selectedObjects = []
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
        for obj in selectedObjects {
            obj.move(by: delta)
        }
        selectDragStart = point
        let currentRects = selectedObjects.map(\.bounds)
        for rect in previousRects + currentRects {
            setNeedsDisplay(rect.insetBy(dx: -12, dy: -12).intersection(bounds))
        }
    }

    private func handleSelectUp(point: CGPoint) {
        selectDragStart = nil
        didPushSelectMoveUndo = false
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
        // Temporarily hide crop overlay so it doesn't get saved into the final image
        let oldCrop = cropRect
        cropRect = nil
        
        // cacheDisplay(in:to:) correctly respects the view's isFlipped = true state,
        // avoiding the dreaded upside-down or shifted annotation bug caused by NSImage.lockFocus()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        
        cropRect = oldCrop
        
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: – NSTextFieldDelegate

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commitTextField() }
}
