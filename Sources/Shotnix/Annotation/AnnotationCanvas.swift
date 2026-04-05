import AppKit

/// The main drawing surface for the annotation editor.
/// Handles tool interaction, renders all annotation objects, and manages undo.
@MainActor
final class AnnotationCanvas: NSView {

    // MARK: – State

    var backgroundImage: NSImage?
    var objects: [any AnnotationObject] = []
    var selectedObjects: [any AnnotationObject] = []
    var activeTool: AnnotationTool = .arrow
    var activeColor: NSColor = .systemRed
    var activeLineWidth: CGFloat = 3

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
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true } // Easier coordinate math (top-left origin)

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
        guard let bg = backgroundImage, let cgImg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let imgSize = CGSize(width: cgImg.width, height: cgImg.height)
        let cropRect = viewRectToCGImageRect(blur.rect, imageSize: imgSize)
        guard let croppedCG = cgImg.cropping(to: cropRect) else { return }
        let ci = CIImage(cgImage: croppedCG)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(blur.radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return }
        // Clamp to avoid infinite extent
        let clamped = output.cropped(to: ci.extent)
        let rep = NSCIImageRep(ciImage: clamped)
        let result = NSImage(size: blur.rect.size)
        result.addRepresentation(rep)
        result.draw(in: blur.rect)
    }

    private func drawPixelate(_ px: PixelateAnnotation, ctx: CGContext) {
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
    }

    private func drawSelectionHandle(for obj: any AnnotationObject, ctx: CGContext) {
        let r = obj.bounds.insetBy(dx: -4, dy: -4)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)
        ctx.restoreGState()
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
            cropRect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            onCropChanged?(cropRect)
            setNeedsDisplay(bounds)
            return
        }

        updateCurrentObject(to: point)
        lastDragPoint = point
        setNeedsDisplay(bounds)
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

    private func handleSelectDown(point: CGPoint) {
        let hit = objects.last(where: { $0.contains(point: point) })
        if let hit {
            if !selectedObjects.contains(where: { $0.id == hit.id }) {
                selectedObjects = [hit]
            }
            selectDragStart = point
            selectObjectStart = selectedObjects.map { ($0.id, CGPoint(x: $0.bounds.origin.x, y: $0.bounds.origin.y)) }
        } else {
            selectedObjects = []
        }
        setNeedsDisplay(bounds)
    }

    private func handleSelectDrag(point: CGPoint) {
        guard let start = selectDragStart else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        for obj in selectedObjects {
            obj.move(by: delta)
        }
        selectDragStart = point
        setNeedsDisplay(bounds)
    }

    private func handleSelectUp(point: CGPoint) {
        selectDragStart = nil
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
        case let f as FreehandAnnotation:    f.points.append(point)
        case let h as HighlighterAnnotation: h.endPoint = point
        case let b as BlurAnnotation:        b.rect = rectFrom(start, to: point)
        case let p as PixelateAnnotation:    p.rect = rectFrom(start, to: point)
        default: break
        }
    }

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
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
        // Snapshot: copy the array (shallow — but since we only add/remove,
        // the previously committed objects are never mutated)
        undoSnapshots.append((objects: Array(objects), selected: Array(selectedObjects)))
        redoSnapshots.removeAll()
    }

    func performUndo() {
        guard let prev = undoSnapshots.popLast() else { return }
        redoSnapshots.append((objects: Array(objects), selected: Array(selectedObjects)))
        objects = prev.objects
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    func performRedo() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append((objects: Array(objects), selected: Array(selectedObjects)))
        objects = next.objects
        selectedObjects = []
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.keyCode == 6 {
            if event.modifierFlags.contains(.shift) {
                performRedo()   // ⌘⇧Z
            } else {
                performUndo()   // ⌘Z
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete/Backspace
            deleteSelected()
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
        guard let crop = cropRect, !crop.isEmpty, let bg = backgroundImage else { return nil }
        let result = NSImage(size: crop.size)
        result.lockFocus()
        bg.draw(in: CGRect(origin: .zero, size: crop.size),
                from: crop, operation: .copy, fraction: 1)
        result.unlockFocus()
        cropRect = nil
        return result
    }

    // MARK: – Flatten to NSImage

    func flatten() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        draw(bounds)
        img.unlockFocus()
        return img
    }
}

// MARK: – NSTextFieldDelegate

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commitTextField() }
}
