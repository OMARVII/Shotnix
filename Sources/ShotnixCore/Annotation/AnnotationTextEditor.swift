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
        // TextKit 1: its layout matches how committed text is drawn, and it
        // reports the laid-out size the editor grows to.
        self.init(usingTextLayoutManager: false)
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
        let placeholderWidth = ceil((placeholder as NSString).size(withAttributes: [.font: font]).width)
        minSize = NSSize(width: placeholderWidth + Self.inset.width * 2, height: lineHeight + Self.inset.height * 2)
        fitToText()
        needsDisplay = true
    }

    /// Grows (or shrinks) to the laid-out text, never below the placeholder.
    func fitToText() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let size = NSSize(
            width: max(minSize.width, ceil(used.width) + Self.inset.width * 2 + 2), // + room for the caret
            height: max(minSize.height, ceil(used.height) + Self.inset.height * 2)
        )
        if frame.size != size { setFrameSize(size) }
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

    /// Drawn by the canvas behind this (transparent) view: the editor's own
    /// text layers would cover anything drawn here.
    func drawPlaceholderAndFrame(in ctx: CGContext) {
        if string.isEmpty, let font {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: (textColor ?? .labelColor).withAlphaComponent(0.45)
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (placeholder as NSString).draw(at: NSPoint(x: frame.minX + Self.inset.width, y: frame.minY + Self.inset.height), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Dashed frame just outside the text, so it's clear where typing goes.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(frame.insetBy(dx: -1.5, dy: -1.5))
        ctx.restoreGState()
    }
}
