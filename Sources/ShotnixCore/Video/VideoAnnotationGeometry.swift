import CoreGraphics
import Foundation

// MARK: - Arrow ends

extension VideoDemoOverlayEffect {
    /// Room kept around an arrow's line inside its box (for the head),
    /// video-normalized.
    static let arrowPadding = 0.02

    /// Where the arrow starts and points (video-normalized, y down). Arrows
    /// made before their ends were saved run from the box's lower left to
    /// its upper right, as they always did.
    var arrowPoints: (tail: CGPoint, head: CGPoint) {
        if let ends = arrowEnds {
            return (CGPoint(x: ends.tailX, y: ends.tailY), CGPoint(x: ends.headX, y: ends.headY))
        }
        let minX = x - width / 2
        let minY = y - height / 2
        return (
            CGPoint(x: minX + width * 0.1, y: minY + height * 0.9),
            CGPoint(x: minX + width * 0.88, y: minY + height * 0.12)
        )
    }

    /// Sets the ends and fits the box around them (the box is what the
    /// timeline, placement, and selection work with).
    mutating func setArrow(tail: CGPoint, head: CGPoint) {
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        let ends = VideoArrowEnds(tailX: clamp(tail.x), tailY: clamp(tail.y), headX: clamp(head.x), headY: clamp(head.y))
        arrowEnds = ends
        let pad = Self.arrowPadding
        x = (ends.tailX + ends.headX) / 2
        y = (ends.tailY + ends.headY) / 2
        width = max(abs(ends.headX - ends.tailX) + pad * 2, 0.04)
        height = max(abs(ends.headY - ends.tailY) + pad * 2, 0.03)
    }

    /// Carries saved arrow ends along when the box moves or is resized
    /// (a drag, a nudge): they keep their place inside it.
    mutating func refitArrowEnds(from old: VideoDemoOverlayEffect) {
        guard kind == .arrow, let ends = old.arrowEnds, ends == arrowEnds,
              old.x != x || old.y != y || old.width != width || old.height != height else { return }
        func map(_ value: Double, _ oldCenter: Double, _ oldSize: Double, _ center: Double, _ size: Double) -> Double {
            let fraction = oldSize > 0.0001 ? (value - (oldCenter - oldSize / 2)) / oldSize : 0.5
            return (center - size / 2) + fraction * size
        }
        arrowEnds = VideoArrowEnds(
            tailX: map(ends.tailX, old.x, old.width, x, width),
            tailY: map(ends.tailY, old.y, old.height, y, height),
            headX: map(ends.headX, old.x, old.width, x, width),
            headY: map(ends.headY, old.y, old.height, y, height)
        )
    }
}

extension VideoOverlayStyleMemory {
    /// The spotlight shape picked last (new spotlights start with it).
    static var shape: VideoOverlayShape {
        get { UserDefaults.standard.string(forKey: "videoOverlayShape.spotlight").flatMap(VideoOverlayShape.init(rawValue:)) ?? .rectangle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "videoOverlayShape.spotlight") }
    }
}

// MARK: - Hit testing

enum VideoAnnotationHitTest {
    /// Whether `point` (view points) lands on an annotation drawn in
    /// `rect`: on an arrow's line (not the empty corners of its box), inside
    /// a spotlight's ellipse, anywhere in the others.
    static func hits(_ effect: VideoDemoOverlayEffect, rect: CGRect, arrow: (tail: CGPoint, head: CGPoint)?, point: CGPoint, tolerance: CGFloat = 10) -> Bool {
        switch effect.kind {
        case .arrow:
            guard let arrow else { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return distance(from: point, toSegment: arrow.tail, arrow.head) <= tolerance
        case .spotlight where effect.shape == .ellipse:
            guard rect.width > 0, rect.height > 0 else { return false }
            let dx = (point.x - rect.midX) / (rect.width / 2 + tolerance)
            let dy = (point.y - rect.midY) / (rect.height / 2 + tolerance)
            return dx * dx + dy * dy <= 1
        default:
            return rect.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
