import AppKit

// MARK: – Tool Types

enum AnnotationTool: String, CaseIterable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, freehand
    case text, numberedStep, highlighter, blur, pixelate, crop

    var icon: String {
        switch self {
        case .select:          return "arrow.up.left.and.arrow.down.right"
        case .arrow:           return "arrow.up.right"
        case .rectangle:       return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse:         return "circle"
        case .line:            return "line.diagonal"
        case .freehand:        return "pencil"
        case .text:            return "textformat"
        case .numberedStep:    return "1.circle.fill"
        case .highlighter:     return "highlighter"
        case .blur:            return "camera.filters"
        case .pixelate:        return "square.grid.3x3.fill"
        case .crop:            return "crop"
        }
    }

    var tooltip: String {
        switch self {
        case .select:          return "Select (V)"
        case .arrow:           return "Arrow (A)"
        case .rectangle:       return "Rectangle (R)"
        case .filledRectangle: return "Filled Rectangle (\u{21E7}R)"
        case .ellipse:         return "Ellipse (E)"
        case .line:            return "Line (L)"
        case .freehand:        return "Freehand Draw (D)"
        case .text:            return "Text (T)"
        case .numberedStep:    return "Numbered Steps (N)"
        case .highlighter:     return "Highlighter (H)"
        case .blur:            return "Blur (B)"
        case .pixelate:        return "Pixelate (P)"
        case .crop:            return "Crop (C)"
        }
    }
}

// MARK: – Base Protocol

protocol AnnotationObject: AnyObject {
    var id: UUID { get }
    var color: NSColor { get set }
    var lineWidth: CGFloat { get set }
    var isSelected: Bool { get set }
    func draw(in context: CGContext, scale: CGFloat)
    func contains(point: CGPoint) -> Bool
    func move(by delta: CGPoint)
    func copy() -> any AnnotationObject
    var bounds: CGRect { get }
}

// MARK: – Arrow

final class ArrowAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint

    init(start: CGPoint, end: CGPoint) {
        self.startPoint = start
        self.endPoint = end
    }

    var bounds: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x) - lineWidth,
            y: min(startPoint.y, endPoint.y) - lineWidth,
            width: abs(endPoint.x - startPoint.x) + lineWidth * 2,
            height: abs(endPoint.y - startPoint.y) + lineWidth * 2
        )
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()

        // Arrowhead
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let arrowLen: CGFloat = lineWidth * 5
        let arrowAngle: CGFloat = .pi / 6
        let p1 = CGPoint(
            x: endPoint.x - arrowLen * cos(angle - arrowAngle),
            y: endPoint.y - arrowLen * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: endPoint.x - arrowLen * cos(angle + arrowAngle),
            y: endPoint.y - arrowLen * sin(angle + arrowAngle)
        )
        ctx.setFillColor(color.cgColor)
        ctx.move(to: endPoint)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()

        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool {
        let d = distanceFromLineSegment(point: point, a: startPoint, b: endPoint)
        return d < max(lineWidth + 4, 8)
    }

    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = ArrowAnnotation(start: startPoint, end: endPoint)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }

    private func distanceFromLineSegment(point p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(p.x-a.x, p.y-a.y) }
        let t = max(0, min(1, ((p.x-a.x)*dx + (p.y-a.y)*dy) / len2))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }
}

// MARK: – Rectangle

final class RectangleAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var isSelected = false
    var filled: Bool
    var rect: CGRect

    init(rect: CGRect, filled: Bool = false) {
        self.rect = rect
        self.filled = filled
    }

    var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        if filled {
            ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
            ctx.fill(rect)
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = RectangleAnnotation(rect: rect, filled: filled)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: – Ellipse

final class EllipseAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var isSelected = false
    var rect: CGRect

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = EllipseAnnotation(rect: rect)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: – Line

final class LineAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint

    init(start: CGPoint, end: CGPoint) {
        self.startPoint = start
        self.endPoint = end
    }

    var bounds: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x) - lineWidth,
            y: min(startPoint.y, endPoint.y) - lineWidth,
            width: abs(endPoint.x - startPoint.x) + lineWidth*2,
            height: abs(endPoint.y - startPoint.y) + lineWidth*2
        )
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool {
        let dx = endPoint.x - startPoint.x, dy = endPoint.y - startPoint.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(point.x-startPoint.x, point.y-startPoint.y) < 8 }
        let t = max(0, min(1, ((point.x-startPoint.x)*dx + (point.y-startPoint.y)*dy) / len2))
        return hypot(point.x-(startPoint.x+t*dx), point.y-(startPoint.y+t*dy)) < max(lineWidth+4, 8)
    }

    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = LineAnnotation(start: startPoint, end: endPoint)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: – Freehand

final class FreehandAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var isSelected = false
    var points: [CGPoint] = []

    var bounds: CGRect {
        guard !points.isEmpty else { return .zero }
        var minX = points[0].x, maxX = minX
        var minY = points[0].y, maxY = minY
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX-lineWidth, y: minY-lineWidth,
                      width: maxX-minX+lineWidth*2, height: maxY-minY+lineWidth*2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { bounds.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { points = points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) } }
    func copy() -> any AnnotationObject {
        let annotation = FreehandAnnotation()
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.points = points
        return annotation
    }
}

// MARK: – Highlighter

final class HighlighterAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemYellow
    var lineWidth: CGFloat = 16
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint

    init(start: CGPoint, end: CGPoint) {
        self.startPoint = start
        self.endPoint = end
    }

    var bounds: CGRect {
        CGRect(x: min(startPoint.x, endPoint.x) - lineWidth,
               y: min(startPoint.y, endPoint.y) - lineWidth,
               width: abs(endPoint.x - startPoint.x) + lineWidth*2,
               height: abs(endPoint.y - startPoint.y) + lineWidth*2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.butt)
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { bounds.contains(point) }
    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = HighlighterAnnotation(start: startPoint, end: endPoint)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: – Blur

final class BlurAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var radius: Double = 12
    var cachedRender: NSImage?
    var cachedRect: CGRect = .zero

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas using CIFilter
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = BlurAnnotation(rect: rect)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.radius = radius
        return annotation
    }
}

// MARK: – Pixelate

final class PixelateAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var scale: Double = 10
    var cachedRender: NSImage?
    var cachedRect: CGRect = .zero

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = PixelateAnnotation(rect: rect)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.scale = scale
        return annotation
    }
}

// MARK: – Text

final class TextAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 0
    var isSelected = false
    var origin: CGPoint
    var text: String = ""
    var fontSize: CGFloat = 18
    var font: NSFont { .boldSystemFont(ofSize: fontSize) }

    init(origin: CGPoint) { self.origin = origin }

    var bounds: CGRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGRect(origin: origin, size: CGSize(width: max(size.width, 40), height: max(size.height, 24)))
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func contains(point: CGPoint) -> Bool { bounds.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { origin.x += delta.x; origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = TextAnnotation(origin: origin)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.text = text
        annotation.fontSize = fontSize
        return annotation
    }
}

// MARK: – Numbered Step

final class NumberedStepAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 0
    var isSelected = false
    var origin: CGPoint
    var number: Int
    var diameter: CGFloat = 30

    private lazy var cachedTextLayout: (font: NSFont, attrs: [NSAttributedString.Key: Any], size: CGSize) = {
        let font = NSFont.boldSystemFont(ofSize: diameter * 0.55)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = ("\(number)" as NSString).size(withAttributes: attrs)
        return (font, attrs, size)
    }()

    init(center: CGPoint, number: Int) {
        self.origin = center
        self.number = number
    }

    var bounds: CGRect {
        CGRect(x: origin.x - diameter/2, y: origin.y - diameter/2,
               width: diameter, height: diameter)
    }

    func contains(point: CGPoint) -> Bool {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        return (dx*dx + dy*dy) <= (diameter/2 + 4) * (diameter/2 + 4)
    }

    func move(by delta: CGPoint) {
        origin.x += delta.x
        origin.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = NumberedStepAnnotation(center: origin, number: number)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.diameter = diameter
        return annotation
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()

        let circleRect = bounds

        // Shadow behind the circle
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                       color: NSColor.black.withAlphaComponent(0.3).cgColor)

        // Filled circle
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circleRect)

        // Reset shadow before drawing border and text
        ctx.setShadow(offset: .zero, blur: 0)

        // White border
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circleRect)

        // Number text (centered, white, bold) — font + size cached as lazy property
        let layout = cachedTextLayout
        let textOrigin = CGPoint(
            x: circleRect.midX - layout.size.width / 2,
            y: circleRect.midY - layout.size.height / 2
        )

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx
        ("\(number)" as NSString).draw(at: textOrigin, withAttributes: layout.attrs)
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }
}
