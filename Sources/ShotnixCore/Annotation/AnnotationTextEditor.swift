import AppKit

/// In-place editor for text annotations and callouts: a borderless text view
/// that grows with its text. Return inserts a new line; ⌘Return, Escape,
/// Tab, or clicking away commits.
@MainActor
final class AnnotationTextEditor: NSTextView {

    /// Gap between the view's edge and the first glyph — room for the
    /// dashed editing frame. The canvas offsets the view by this much so
    /// glyphs sit exactly where the committed annotation draws them.
    static let inset = CGSize(width: 3, height: 2)

    var onCommit: (() -> Void)?
    var placeholder = "Type here\u{2026}"

    convenience init(font: NSFont, color: NSColor) {
        self.init(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        textContainerInset = Self.inset
        textContainer?.lineFragmentPadding = 0
        // Grow to fit instead of wrapping: line breaks are the user's.
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        maxSize = NSSize(width: 100_000, height: 100_000)
        setStyle(font: font, color: color)
        setAccessibilityLabel("Annotation text")
    }

    func setStyle(font: NSFont, color: NSColor) {
        self.font = font
        textColor = color
        insertionPointColor = color
        typingAttributes = [.font: font, .foregroundColor: color]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        minSize = NSSize(width: max(60, font.pointSize * 3), height: lineHeight + Self.inset.height * 2)
        sizeToFit()
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(cancelOperation(_:)), #selector(insertTab(_:)), #selector(insertBacktab(_:)):
            onCommit?()
        case #selector(insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.command) == true:
            onCommit?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let font {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: (textColor ?? .labelColor).withAlphaComponent(0.45)
            ]
            (placeholder as NSString).draw(at: NSPoint(x: Self.inset.width, y: Self.inset.height), withAttributes: attrs)
        }
        // Dashed frame so it's obvious where typing goes.
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.setLineDash([4, 3], count: 2, phase: 0)
        frame.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        frame.stroke()
    }
}
