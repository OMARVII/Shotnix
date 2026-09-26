import AppKit

// MARK: – Tool Types

enum AnnotationTool: String, CaseIterable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, freehand
    case text, callout, numberedStep, highlighter, freehandHighlighter
    case blur, pixelate, spotlight, crop

    var icon: String {
        switch self {
        case .select:              return "cursorarrow"
        case .arrow:               return "arrow.up.right"
        case .rectangle:           return "rectangle"
        case .filledRectangle:     return "rectangle.fill"
        case .ellipse:             return "circle"
        case .line:                return "line.diagonal"
        case .freehand:            return "pencil"
        case .text:                return "textformat"
        case .callout:             return "text.bubble"
        case .numberedStep:        return "1.circle.fill"
        case .highlighter:         return "highlighter"
        case .freehandHighlighter: return "scribble.variable"
        case .blur:                return "camera.filters"
        case .pixelate:            return "square.grid.3x3.fill"
        case .spotlight:           return "flashlight.on.fill"
        case .crop:                return "crop"
        }
    }

    /// Name read by VoiceOver and shown in the tooltip.
    var name: String {
        switch self {
        case .select:              return "Select"
        case .arrow:               return "Arrow"
        case .rectangle:           return "Rectangle"
        case .filledRectangle:     return "Filled Rectangle"
        case .ellipse:             return "Ellipse"
        case .line:                return "Line"
        case .freehand:            return "Freehand Draw"
        case .text:                return "Text"
        case .callout:             return "Callout"
        case .numberedStep:        return "Numbered Steps"
        case .highlighter:         return "Highlighter"
        case .freehandHighlighter: return "Freehand Highlighter"
        case .blur:                return "Blur"
        case .pixelate:            return "Pixelate"
        case .spotlight:           return "Spotlight"
        case .crop:                return "Crop"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .select:              return "V"
        case .arrow:               return "A"
        case .rectangle:           return "R"
        case .filledRectangle:     return "\u{21E7}R"
        case .ellipse:             return "E"
        case .line:                return "L"
        case .freehand:            return "D"
        case .text:                return "T"
        case .callout:             return "O"
        case .numberedStep:        return "N"
        case .highlighter:         return "H"
        case .freehandHighlighter: return "\u{21E7}H"
        case .blur:                return "B"
        case .pixelate:            return "P"
        case .spotlight:           return "S"
        case .crop:                return "C"
        }
    }

    var tooltip: String { "\(name) (\(shortcutLabel))" }

    /// The tool a single-key shortcut selects. `key` is the lowercase Latin
    /// letter of the pressed key (see `AnnotationKeyboard.latinKey(for:)`).
    static func forShortcut(_ key: String, shift: Bool) -> AnnotationTool? {
        switch key {
        case "v": return .select
        case "a": return .arrow
        case "r": return shift ? .filledRectangle : .rectangle
        case "e": return .ellipse
        case "l": return .line
        case "d": return .freehand
        case "t": return .text
        case "o": return .callout
        case "n": return .numberedStep
        case "h": return shift ? .freehandHighlighter : .highlighter
        case "b": return .blur
        case "p": return .pixelate
        case "s": return .spotlight
        case "c": return .crop
        default:  return nil
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
    /// Hit test while a drawing tool is active. Shapes only grab near their
    /// outline so a drag inside one draws a new annotation; solid objects
    /// (text, steps, callouts, strokes) grab wherever `contains` does.
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool
    func move(by delta: CGPoint)
    func copy() -> any AnnotationObject
    var bounds: CGRect { get }
}

extension AnnotationObject {
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool { contains(point: point) }
}

// MARK: – Hit-testing geometry

enum AnnotationGeometry {
    static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x)*dx + (p.y - a.y)*dy) / len2))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }

    static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var closest = CGFloat.greatestFiniteMagnitude
        for (a, b) in zip(points, points.dropFirst()) {
            closest = min(closest, distance(from: p, toSegmentFrom: a, to: b))
        }
        return closest
    }

    /// Within `band` of the rectangle's edge, inside or out. Rects too small
    /// to have an inside count as all edge.
    static func rectOutlineContains(_ rect: CGRect, point: CGPoint, band: CGFloat) -> Bool {
        guard rect.insetBy(dx: -band, dy: -band).contains(point) else { return false }
        let inner = rect.insetBy(dx: band, dy: band)
        return inner.isNull || inner.isEmpty || !inner.contains(point)
    }

    static func ellipseContains(_ rect: CGRect, point: CGPoint) -> Bool {
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (point.x - rect.midX) / rx
        let ny = (point.y - rect.midY) / ry
        return nx*nx + ny*ny <= 1
    }

    static func ellipseOutlineContains(_ rect: CGRect, point: CGPoint, band: CGFloat) -> Bool {
        guard ellipseContains(rect.insetBy(dx: -band, dy: -band), point: point) else { return false }
        let inner = rect.insetBy(dx: band, dy: band)
        return inner.isNull || inner.isEmpty || !ellipseContains(inner, point: point)
    }

    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: – Arrow

final class ArrowAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint
    var controlPoint: CGPoint?

    init(start: CGPoint, end: CGPoint) {
        self.startPoint = start
        self.endPoint = end
    }

    var bounds: CGRect {
        var points = [startPoint, endPoint]
        if let controlPoint { points.append(controlPoint) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let padding = max(lineWidth * 6, 18)
        return CGRect(x: minX - padding, y: minY - padding,
                      width: maxX - minX + padding * 2,
                      height: maxY - minY + padding * 2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        let tangentStart = controlPoint ?? startPoint
        let dx = endPoint.x - tangentStart.x
        let dy = endPoint.y - tangentStart.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        let unitX = dx / length
        let unitY = dy / length
        let arrowLen: CGFloat = lineWidth * 5
        let arrowAngle: CGFloat = .pi / 6
        let headInset = min(arrowLen * cos(arrowAngle), length * 0.7)
        let shaftEnd = CGPoint(
            x: endPoint.x - unitX * headInset,
            y: endPoint.y - unitY * headInset
        )

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        ctx.move(to: startPoint)
        if let controlPoint {
            ctx.addQuadCurve(to: shaftEnd, control: controlPoint)
        } else {
            ctx.addLine(to: shaftEnd)
        }
        ctx.strokePath()

        let angle = atan2(dy, dx)
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
        let d: CGFloat
        if let controlPoint {
            d = distanceFromQuadraticCurve(point: point, control: controlPoint)
        } else {
            d = distanceFromLineSegment(point: point, a: startPoint, b: endPoint)
        }
        return d < max(lineWidth + 4, 8)
    }

    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
        controlPoint = controlPoint.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    func copy() -> any AnnotationObject {
        let annotation = ArrowAnnotation(start: startPoint, end: endPoint)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.controlPoint = controlPoint
        return annotation
    }

    func handlePoint(_ handle: ArrowHandle) -> CGPoint {
        switch handle {
        case .start:   return startPoint
        case .end:     return endPoint
        case .control: return controlPoint ?? midpoint
        }
    }

    func setHandle(_ handle: ArrowHandle, to point: CGPoint) {
        switch handle {
        case .start:   startPoint = point
        case .end:     endPoint = point
        case .control: controlPoint = point
        }
    }

    var midpoint: CGPoint {
        CGPoint(x: (startPoint.x + endPoint.x) / 2, y: (startPoint.y + endPoint.y) / 2)
    }

    func pointOnCurve(at t: CGFloat) -> CGPoint {
        guard let controlPoint else {
            return CGPoint(x: startPoint.x + (endPoint.x - startPoint.x) * t,
                           y: startPoint.y + (endPoint.y - startPoint.y) * t)
        }
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * startPoint.x + 2 * mt * t * controlPoint.x + t * t * endPoint.x,
            y: mt * mt * startPoint.y + 2 * mt * t * controlPoint.y + t * t * endPoint.y
        )
    }

    private func distanceFromLineSegment(point p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        AnnotationGeometry.distance(from: p, toSegmentFrom: a, to: b)
    }

    private func distanceFromQuadraticCurve(point: CGPoint, control: CGPoint) -> CGFloat {
        var closest = CGFloat.greatestFiniteMagnitude
        var previous = startPoint
        for step in 1...28 {
            let current = pointOnCurve(at: CGFloat(step) / 28)
            closest = min(closest, distanceFromLineSegment(point: point, a: previous, b: current))
            previous = current
        }
        return closest
    }
}

enum ArrowHandle {
    case start, end, control
}

// MARK: – Rectangle

final class RectangleAnnotation: AnnotationObject {
    /// Corner radius new rounded rectangles get.
    static let roundedCornerRadius: CGFloat = 12

    let id = UUID()
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var isSelected = false
    var filled: Bool
    var rect: CGRect
    /// 0 = square corners. Never more than half the short side when drawn.
    var cornerRadius: CGFloat = 0

    init(rect: CGRect, filled: Bool = false) {
        self.rect = rect
        self.filled = filled
    }

    var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    var path: CGPath {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        if filled {
            ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        AnnotationGeometry.rectOutlineContains(rect, point: point, band: lineWidth / 2 + tolerance)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = RectangleAnnotation(rect: rect, filled: filled)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.cornerRadius = cornerRadius
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
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        AnnotationGeometry.ellipseOutlineContains(rect, point: point, band: lineWidth / 2 + tolerance)
    }
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
    /// Marker ink instead of pen: translucent, flat-ended, multiplied into
    /// the screenshot so dark text under it stays crisp.
    var isHighlighter = false

    var bounds: CGRect {
        guard !points.isEmpty else { return .zero }
        return AnnotationGeometry.boundingRect(of: points).insetBy(dx: -lineWidth, dy: -lineWidth)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        if isHighlighter {
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
            ctx.setLineCap(.butt)
        } else {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineCap(.round)
        }
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        // One path, one stroke: overlapping parts of a highlighter stroke
        // don't darken twice.
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { bounds.insetBy(dx: -8, dy: -8).contains(point) }
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        AnnotationGeometry.distance(from: point, toPolyline: points) <= lineWidth / 2 + tolerance
    }
    func move(by delta: CGPoint) { points = points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) } }
    func copy() -> any AnnotationObject {
        let annotation = FreehandAnnotation()
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.points = points
        annotation.isHighlighter = isHighlighter
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

    // The stroke itself, not its bounding box — a diagonal highlight would
    // otherwise grab clicks in the empty corners around it.
    func contains(point: CGPoint) -> Bool {
        AnnotationGeometry.distance(from: point, toSegmentFrom: startPoint, to: endPoint) <= lineWidth / 2 + 4
    }
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

// MARK: – Redaction (blur / pixelate)

enum AnnotationRedaction {
    /// Default blur radius / pixel block size, in points.
    static let defaultStrength: CGFloat = 12
    static let strengthRange: ClosedRange<CGFloat> = 4...40
}

final class BlurAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    /// Blur radius in points — scaled to the screenshot's pixel density when
    /// rendered, so it's equally strong on Retina and 1x captures.
    var strength: CGFloat = AnnotationRedaction.defaultStrength

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered by AnnotationRenderer from the screenshot's pixels
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        AnnotationGeometry.rectOutlineContains(rect, point: point, band: tolerance)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = BlurAnnotation(rect: rect)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.strength = strength
        return annotation
    }
}

final class PixelateAnnotation: AnnotationObject {
    let id = UUID()
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    /// Pixel block size in points (scaled to pixel density when rendered).
    var strength: CGFloat = AnnotationRedaction.defaultStrength

    init(rect: CGRect) { self.rect = rect }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered by AnnotationRenderer from the screenshot's pixels
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        AnnotationGeometry.rectOutlineContains(rect, point: point, band: tolerance)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = PixelateAnnotation(rect: rect)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.strength = strength
        return annotation
    }
}

// MARK: – Spotlight

/// Dims the screenshot everywhere except its rect or ellipse. All spotlights
/// share one dimmed layer (drawn by AnnotationRenderer), so two spotlights
/// never darken each other's opening.
final class SpotlightAnnotation: AnnotationObject {
    static let dimAlpha: CGFloat = 0.55

    let id = UUID()
    var color: NSColor = .black
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var isEllipse: Bool

    init(rect: CGRect, isEllipse: Bool = false) {
        self.rect = rect
        self.isEllipse = isEllipse
    }

    var bounds: CGRect { rect }

    var holePath: CGPath {
        isEllipse ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered by AnnotationRenderer together with every other spotlight
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func outlineContains(point: CGPoint, tolerance: CGFloat) -> Bool {
        isEllipse
            ? AnnotationGeometry.ellipseOutlineContains(rect, point: point, band: tolerance)
            : AnnotationGeometry.rectOutlineContains(rect, point: point, band: tolerance)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = SpotlightAnnotation(rect: rect, isEllipse: isEllipse)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: – Text layout

/// Multi-line text measuring and drawing shared by text annotations,
/// callouts, and the in-place editor, so all three lay lines out alike.
enum AnnotationText {
    static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func font(size: CGFloat, bold: Bool) -> NSFont {
        bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    static func size(of text: String, font: NSFont) -> CGSize {
        let measured = (text.isEmpty ? " " : text) as NSString
        let rect = measured.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: drawingOptions,
            attributes: [.font: font]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    static func draw(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: CGRect, context ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(with: rect, options: drawingOptions, attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
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
    var isBold = true
    /// Hidden while the in-place editor shows its text.
    var isEditing = false
    var font: NSFont { AnnotationText.font(size: fontSize, bold: isBold) }

    init(origin: CGPoint) { self.origin = origin }

    var textSize: CGSize { AnnotationText.size(of: text, font: font) }

    var bounds: CGRect {
        let size = textSize
        return CGRect(origin: origin, size: CGSize(width: max(size.width, 40), height: max(size.height, 24)))
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard !text.isEmpty, !isEditing else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        AnnotationText.draw(text, attributes: attrs, in: CGRect(origin: origin, size: textSize), context: ctx)
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
        annotation.isBold = isBold
        return annotation
    }
}

// MARK: – Callout

/// Text in a rounded speech bubble with a tail pointing at `tail`. The
/// bubble fits its text; resizing scales the font, like text annotations.
final class CalloutAnnotation: AnnotationObject {
    static let padding = CGSize(width: 12, height: 8)
    static let minimumBubbleSize = CGSize(width: 48, height: 34)

    let id = UUID()
    /// Bubble fill; the text picks black or white against it.
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 0
    var isSelected = false
    var origin: CGPoint
    var tail: CGPoint
    var text: String = ""
    var fontSize: CGFloat = 16
    var isBold = true
    /// Text hidden while the in-place editor shows it.
    var isEditing = false

    init(origin: CGPoint, tail: CGPoint) {
        self.origin = origin
        self.tail = tail
    }

    var font: NSFont { AnnotationText.font(size: fontSize, bold: isBold) }

    var textColor: NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var textSize: CGSize { AnnotationText.size(of: text, font: font) }

    var bubbleRect: CGRect {
        let size = textSize
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: max(size.width + Self.padding.width * 2, Self.minimumBubbleSize.width),
            height: max(size.height + Self.padding.height * 2, Self.minimumBubbleSize.height)
        )
    }

    /// Where the text (and the editor's text) starts.
    var textOrigin: CGPoint {
        let bubble = bubbleRect
        let size = textSize
        return CGPoint(x: bubble.minX + Self.padding.width, y: bubble.midY - size.height / 2)
    }

    var cornerRadius: CGFloat { min(12, bubbleRect.height / 2) }

    var bounds: CGRect {
        bubbleRect.union(CGRect(origin: tail, size: .zero))
    }

    /// Triangle from just inside the bubble out to the tip; nil while the
    /// tip is inside the bubble.
    var tailPath: CGPath? {
        let rect = bubbleRect
        guard !rect.insetBy(dx: -2, dy: -2).contains(tail) else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = tail.x - center.x, dy = tail.y - center.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let ux = dx / length, uy = dy / length
        // Where the center→tip ray leaves the bubble
        let exitX = ux == 0 ? CGFloat.greatestFiniteMagnitude : (rect.width / 2) / abs(ux)
        let exitY = uy == 0 ? CGFloat.greatestFiniteMagnitude : (rect.height / 2) / abs(uy)
        let exit = min(exitX, exitY)
        let halfWidth = min(max(min(rect.width, rect.height) * 0.22, 6), 14)
        // Starting the base inside the bubble keeps the join seamless.
        let baseDistance = max(0, exit - halfWidth - 2)
        let base = CGPoint(x: center.x + ux * baseDistance, y: center.y + uy * baseDistance)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        path.addLine(to: tail)
        path.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        path.closeSubpath()
        return path
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        let bubble = bubbleRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        // One transparency layer so bubble and tail cast a single shadow
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        if let tailPath { ctx.addPath(tailPath) }
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        guard !text.isEmpty, !isEditing else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        AnnotationText.draw(text, attributes: attrs, in: CGRect(origin: textOrigin, size: textSize), context: ctx)
    }

    func contains(point: CGPoint) -> Bool {
        if bubbleRect.insetBy(dx: -4, dy: -4).contains(point) { return true }
        guard tailPath != nil else { return false }
        let center = CGPoint(x: bubbleRect.midX, y: bubbleRect.midY)
        return AnnotationGeometry.distance(from: point, toSegmentFrom: center, to: tail) <= 8
    }

    func move(by delta: CGPoint) {
        origin.x += delta.x; origin.y += delta.y
        tail.x += delta.x;   tail.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = CalloutAnnotation(origin: origin, tail: tail)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.text = text
        annotation.fontSize = fontSize
        annotation.isBold = isBold
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

    private var textLayout: (font: NSFont, attrs: [NSAttributedString.Key: Any], size: CGSize) {
        let font = NSFont.boldSystemFont(ofSize: diameter * 0.55)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let size = ("\(number)" as NSString).size(withAttributes: attrs)
        return (font, attrs, size)
    }

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

        let layout = textLayout
        let textRect = CGRect(
            x: circleRect.minX,
            y: circleRect.midY - layout.size.height / 2 - 1,
            width: circleRect.width,
            height: layout.size.height + 2
        )

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx
        ("\(number)" as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: layout.attrs
        )
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }
}
