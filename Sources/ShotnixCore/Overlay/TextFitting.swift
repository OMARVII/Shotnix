import AppKit

/// Widths that fit translated text. Each keeps the English layout's width
/// as its minimum, so English looks exactly as designed while longer
/// languages (German runs about 30% longer) grow instead of cutting words off.
enum TextFitting {
    /// The width `text` needs in `font`, rounded up to whole points.
    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The widest of `texts` in `font`.
    static func widest(_ texts: [String], font: NSFont) -> CGFloat {
        texts.map { width(of: $0, font: font) }.max() ?? 0
    }

    /// A push button's width: its title plus `padding`, never below `minimum`.
    @MainActor
    static func buttonWidth(_ button: NSButton, minimum: CGFloat, padding: CGFloat = 26) -> CGFloat {
        let font = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return max(minimum, width(of: button.title, font: font) + padding)
    }
}
