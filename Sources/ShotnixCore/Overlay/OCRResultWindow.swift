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
            ToastWindow.show(message: "✓ Text copied to clipboard", on: screen)
            return
        }
        ToastWindow.show(message: "✓ Text copied · \(extras) — click for options", duration: 5, on: screen) {
            show(result: result, on: screen)
        }
    }

    /// "a table, 2 links, 1 email address", or nil for plain text.
    static func extrasSummary(for result: OCRResult) -> String? {
        var parts: [String] = []
        if result.table != nil { parts.append("a table") }
        let emails = result.links.filter(\.isEmail).count
        let links = result.links.count - emails
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        if emails > 0 { parts.append(emails == 1 ? "1 email address" : "\(emails) email addresses") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
        title = "Recognized Text"
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

        let titleLabel = NSTextField(labelWithString: "Text copied to clipboard")
        titleLabel.font = .boldSystemFont(ofSize: 19)
        titleLabel.frame = NSRect(x: 78, y: height - 68, width: width - 102, height: 24)
        background.addSubview(titleLabel)

        let lineCount = result.text.split(separator: "\n").count
        var detail = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        if let extras = Self.extrasSummary(for: result) { detail += " · found \(extras)" }
        let detailLabel = NSTextField(labelWithString: detail)
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
                ? "Links (\(visibleLinks.count) of \(result.links.count))"
                : "Links")
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
        textView.setAccessibilityLabel("Recognized text")
        scroll.documentView = textView
        card.addSubview(scroll)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: width - 110, y: buttonY, width: 86, height: 32)
        background.addSubview(doneButton)

        let copyText = NSButton(title: "Copy Text", target: self, action: #selector(copyText))
        copyText.bezelStyle = .rounded
        copyText.frame = NSRect(x: width - 222, y: buttonY, width: 106, height: 32)
        background.addSubview(copyText)

        if result.table != nil {
            let copyTable = NSButton(title: "Copy as Table", target: self, action: #selector(copyTable))
            copyTable.bezelStyle = .rounded
            copyTable.frame = NSRect(x: width - 356, y: buttonY, width: 128, height: 32)
            copyTable.toolTip = "Copy the rows tab-separated, ready to paste into a spreadsheet"
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
        label.frame = NSRect(x: 48, y: y + 4, width: width - 48 - 170, height: 18)
        parent.addSubview(label)

        let open = NSButton(title: link.isEmail ? "Email" : "Open", target: self, action: #selector(openLink(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.tag = index
        open.setAccessibilityLabel(link.isEmail ? "Email \(shown)" : "Open \(shown)")
        open.frame = NSRect(x: width - 164, y: y, width: 70, height: 26)
        parent.addSubview(open)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyLink(_:)))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.tag = index
        copy.setAccessibilityLabel("Copy \(shown)")
        copy.frame = NSRect(x: width - 94, y: y, width: 70, height: 26)
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
        copyString(value, confirmation: link.isEmail ? "Email address copied" : "Link copied")
    }

    @objc private func copyText() {
        copyString(result.text, confirmation: "Text copied")
    }

    @objc private func copyTable() {
        guard let table = result.table else { return }
        copyString(table.tabSeparated, confirmation: "Table copied — paste it into a spreadsheet")
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
