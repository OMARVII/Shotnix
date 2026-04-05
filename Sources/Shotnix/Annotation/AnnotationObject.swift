import AppKit

// MARK: – Tool Types

enum AnnotationTool: String, CaseIterable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, freehand
    case text, highlighter, blur, pixelate, crop

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
        case .highlighter:     return "highlighter"
        case .blur:            return "camera.filters"
        case .pixelate:        return "square.grid.3x3.fill"
        case .crop:            return "crop"
        }
    }

    var tooltip: String {
        switch self {
        case .select:          return "Select"
        case .arrow:           return "Arrow"
        case .rectangle:       return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse:         return "Ellipse"
        case .line:            return "Line"
        case .freehand:        return "Freehand Draw"
        case .text:            return "Text"
        case .highlighter:     return "Highlighter"
        case .blur:            return "Blur"
        case .pixelate:        return "Pixelate"
        case .crop:            return "Crop"
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
}

// MARK: – Blur

final class BlurAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var radius: Double = 12

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas using CIFilter
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
}

// MARK: – Pixelate

final class PixelateAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var scale: Double = 10

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
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
}
