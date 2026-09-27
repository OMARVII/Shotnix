import AppKit

/// Follow-up for Capture Text when the text holds more than plain lines:
/// open or copy the links it found, or copy a detected table as
/// tab-separated rows for a spreadsheet.
@MainActor
final class OCRResultWindow: NSWindow, NSWindowDelegate {

    private static var current: OCRResultWindow?
    private static let maxLinkRows = 4

    private let result: OCRResult

    /// The "text copied" toast. When the text has links or a table, the toast
    /// is clickable and opens this window — the panel only appears when the
    /// user asks for it, never stealing focus from a plain copy.
    static func showCopiedToast(for result: OCRResult, on screen: NSScreen?) {
        guard let extras = extrasSummary(for: result) else {
            ToastWindow.show(message: L("✓ Text copied to clipboard"), on: screen)
            return
        }
        ToastWindow.show(message: L("✓ Text copied · \(extras) — click for options"), duration: 5, on: screen) {
            show(result: result, on: screen)
        }
    }

    /// "a table, 2 links, 1 email address", or nil for plain text.
    static func extrasSummary(for result: OCRResult) -> String? {
        var parts: [String] = []
        if result.table != nil { parts.append(L("a table")) }
        let emails = result.links.filter(\.isEmail).count
        let links = result.links.count - emails
        if links > 0 { parts.append(L("\(links) links")) }
        if emails > 0 { parts.append(L("\(emails) email addresses")) }
        // Each language's list separator (Chinese joins with 、).
        return parts.isEmpty ? nil : parts.dropFirst().reduce(parts[0]) { list, part in L("\(list), \(part)") }
    }

    static func show(result: OCRResult, on screen: NSScreen? = nil) {
        current?.close()
        let window = OCRResultWindow(result: result)
        current = window
        // On the display the text was captured from.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        // Opened from a toast click — the user's action, so taking focus is fine.
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    init(result: OCRResult) {
        self.result = result
        let linkRows = min(result.links.count, Self.maxLinkRows)
        let width: CGFloat = 520
        let height: CGFloat = 300 + (linkRows > 0 ? CGFloat(linkRows) * 30 + 30 : 0)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = L("Recognized Text")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = .floating
        delegate = self
        center()
        buildContent(width: width, height: height)
    }

    private func buildContent(width: CGFloat, height: CGFloat) {
        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = background

        let iconWrap = NSView(frame: NSRect(x: 24, y: height - 82, width: 42, height: 42))
        iconWrap.wantsLayer = true
        iconWrap.layer?.cornerRadius = 13
        iconWrap.layer?.cornerCurve = .continuous
        iconWrap.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        iconWrap.layer?.borderWidth = 1
        iconWrap.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        background.addSubview(iconWrap)

        let icon = NSImageView(frame: NSRect(x: 9, y: 9, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: result.table != nil ? "tablecells" : "text.viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        iconWrap.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: L("Text copied to clipboard"))
        titleLabel.font = .boldSystemFont(ofSize: 19)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 78, y: height - 68, width: width - 102, height: 24)
        background.addSubview(titleLabel)

        let lineCount = result.text.split(separator: "\n").count
        let detail = Self.extrasSummary(for: result).map { L("\(lineCount) lines · found \($0)") } ?? L("\(lineCount) lines")
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 78, y: height - 90, width: width - 102, height: 18)
        background.addSubview(detailLabel)

        let buttonY: CGFloat = 18
        var linksTop: CGFloat = buttonY + 44
        let visibleLinks = Array(result.links.prefix(Self.maxLinkRows))
        if !visibleLinks.isEmpty {
            for (index, link) in visibleLinks.enumerated().reversed() {
                let rowY = linksTop + CGFloat(visibleLinks.count - 1 - index) * 30
                addLinkRow(link, index: index, y: rowY, width: width, in: background)
            }
            let header = NSTextField(labelWithString: result.links.count > visibleLinks.count
                ? L("Links (\(visibleLinks.count) of \(result.links.count))")
                : L("Links"))
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .tertiaryLabelColor
            header.frame = NSRect(x: 26, y: linksTop + CGFloat(visibleLinks.count) * 30 + 4, width: 200, height: 14)
            background.addSubview(header)
            linksTop += CGFloat(visibleLinks.count) * 30 + 30
        }

        let cardY = linksTop
        let cardHeight = height - 110 - cardY
        let card = NSView(frame: NSRect(x: 24, y: cardY, width: width - 48, height: cardHeight))
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        background.addSubview(card)

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 8, width: card.bounds.width - 20, height: cardHeight - 16))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.bounds.size))
        textView.string = result.table?.tabSeparated ?? result.text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.setAccessibilityLabel(L("Recognized text"))
        scroll.documentView = textView
        card.addSubview(scroll)

        // Right to left, 6 pt apart; each button fits its title (English
        // keeps its widths).
        let doneButton = NSButton(title: L("Done"), target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let doneWidth = TextFitting.buttonWidth(doneButton, minimum: 86)
        doneButton.frame = NSRect(x: width - 24 - doneWidth, y: buttonY, width: doneWidth, height: 32)
        background.addSubview(doneButton)

        let copyText = NSButton(title: L("Copy Text"), target: self, action: #selector(copyText))
        copyText.bezelStyle = .rounded
        let copyTextWidth = TextFitting.buttonWidth(copyText, minimum: 106)
        copyText.frame = NSRect(x: doneButton.frame.minX - 6 - copyTextWidth, y: buttonY, width: copyTextWidth, height: 32)
        background.addSubview(copyText)

        if result.table != nil {
            let copyTable = NSButton(title: L("Copy as Table"), target: self, action: #selector(copyTable))
            copyTable.bezelStyle = .rounded
            let copyTableWidth = TextFitting.buttonWidth(copyTable, minimum: 128)
            copyTable.frame = NSRect(x: copyText.frame.minX - 6 - copyTableWidth, y: buttonY, width: copyTableWidth, height: 32)
            copyTable.toolTip = L("Copy the rows tab-separated, ready to paste into a spreadsheet")
            background.addSubview(copyTable)
        }
    }

    private func addLinkRow(_ link: OCRLink, index: Int, y: CGFloat, width: CGFloat, in parent: NSView) {
        let symbol = NSImageView(frame: NSRect(x: 26, y: y + 5, width: 16, height: 16))
        symbol.image = NSImage(systemSymbolName: link.isEmail ? "envelope" : "link", accessibilityDescription: nil)
        symbol.contentTintColor = .secondaryLabelColor
        parent.addSubview(symbol)

        let shown = link.isEmail ? link.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : link.text
        let label = NSTextField(labelWithString: shown)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingMiddle

        let open = NSButton(title: link.isEmail ? L("Email") : L("Open"), target: self, action: #selector(openLink(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.tag = index
        open.setAccessibilityLabel(link.isEmail ? L("Email \(shown)") : L("Open \(shown)"))

        let copy = NSButton(title: L("Copy"), target: self, action: #selector(copyLink(_:)))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.tag = index
        copy.setAccessibilityLabel(L("Copy \(shown)"))

        // Right to left; the buttons fit their titles (English keeps 70 pt
        // each), Open and Email one width so the rows line up, and the
        // address takes the room left of them.
        let copyWidth = TextFitting.buttonWidth(copy, minimum: 70, padding: 20)
        copy.frame = NSRect(x: width - 24 - copyWidth, y: y, width: copyWidth, height: 26)
        let openFont = open.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let openWidth = max(70, TextFitting.widest([L("Open"), L("Email")], font: openFont) + 20)
        open.frame = NSRect(x: copy.frame.minX - openWidth, y: y, width: openWidth, height: 26)
        label.frame = NSRect(x: 48, y: y + 4, width: open.frame.minX - 6 - 48, height: 18)
        parent.addSubview(label)
        parent.addSubview(open)
        parent.addSubview(copy)
    }

    /// Esc closes, like Done.
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    @objc private func openLink(_ sender: NSButton) {
        guard result.links.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.open(result.links[sender.tag].url)
    }

    @objc private func copyLink(_ sender: NSButton) {
        guard result.links.indices.contains(sender.tag) else { return }
        let link = result.links[sender.tag]
        let value = link.isEmail ? link.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : link.url.absoluteString
        copyString(value, confirmation: link.isEmail ? L("Email address copied") : L("Link copied"))
    }

    @objc private func copyText() {
        copyString(result.text, confirmation: L("Text copied"))
    }

    @objc private func copyTable() {
        guard let table = result.table else { return }
        copyString(table.tabSeparated, confirmation: L("Table copied — paste it into a spreadsheet"))
    }

    private func copyString(_ string: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        ToastWindow.show(message: confirmation, on: screen)
    }

    @objc private func closeWindow() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self {
            Self.current = nil
        }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: self)
    }
}
