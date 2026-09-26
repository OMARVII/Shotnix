import AppKit

/// A thin dashed outline just outside an area recording, so the edges of
/// what's recorded stay visible. Click-through, drawn outside the recorded
/// pixels, and — like all of Shotnix's floating UI — kept out of the video.
@MainActor
final class RecordingAreaOutlineWindow: NSPanel {
    /// Points between the recorded area and the stroke.
    static let gap: CGFloat = 3
    static let lineWidth: CGFloat = 2

    private let outline: RecordingAreaOutlineView

    init(around rect: CGRect) {
        let inset = Self.gap + Self.lineWidth
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        outline = RecordingAreaOutlineView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = outline
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    func setPaused(_ paused: Bool) {
        outline.paused = paused
    }
}

@MainActor
private final class RecordingAreaOutlineView: NSView {
    var paused = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let width = RecordingAreaOutlineWindow.lineWidth
        let path = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        let pattern: [CGFloat] = [7, 5]
        path.setLineDash(pattern, count: pattern.count, phase: 0)
        (paused ? NSColor.systemYellow : NSColor.systemRed).withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}
