import AppKit

@MainActor
final class QRCodeResultWindow: NSWindow, NSWindowDelegate {

    private static var current: QRCodeResultWindow?

    private let results: [QRCodeResult]
    private let payloads: [QRCodePayload]
    private let payloadText: String
    private let primaryPayload: QRCodePayload?

    static func show(results: [QRCodeResult]) {
        guard !results.isEmpty else { return }
        current?.close()
        let window = QRCodeResultWindow(results: results)
        current = window
        window.showWindow()
    }

    private init(results: [QRCodeResult]) {
        self.results = results
        self.payloads = results.map { QRCodePayload.parse($0.payload) }
        self.payloadText = Self.displayText(for: payloads)
        self.primaryPayload = payloads.first(where: { $0.actionURL != nil })

        let height: CGFloat = results.count > 1 ? 326 : 292
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = payloads.count == 1 ? payloads[0].title.replacingOccurrences(of: " found", with: "") : "QR Codes"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        level = .floating
        delegate = self
        center()
        buildContent(width: 500, height: height)
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
        icon.image = NSImage(systemSymbolName: "qrcode.viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        iconWrap.addSubview(icon)

        let titleText = payloads.count == 1 ? payloads[0].title : "\(payloads.count) QR codes found"
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .boldSystemFont(ofSize: 19)
        titleLabel.frame = NSRect(x: 78, y: height - 68, width: width - 102, height: 24)
        background.addSubview(titleLabel)

        let detail = detailText
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 78, y: height - 94, width: width - 102, height: 24)
        background.addSubview(detailLabel)

        let cardY: CGFloat = 70
        let cardHeight = height - 184
        let card = NSView(frame: NSRect(x: 24, y: cardY, width: width - 48, height: cardHeight))
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        background.addSubview(card)

        let badge = NSTextField(labelWithString: payloads.count == 1 ? "Decoded details" : "Decoded details")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .tertiaryLabelColor
        badge.frame = NSRect(x: 14, y: cardHeight - 28, width: card.bounds.width - 28, height: 14)
        card.addSubview(badge)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: card.bounds.width - 24, height: cardHeight - 48))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: scroll.bounds.height))
        textView.string = payloadText
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        scroll.documentView = textView
        card.addSubview(scroll)

        let buttonY: CGFloat = 18
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPayload))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.frame = NSRect(x: width - 224, y: buttonY, width: 86, height: 32)
        background.addSubview(copyButton)

        if let primaryPayload, primaryPayload.actionURL != nil, let actionTitle = primaryPayload.actionTitle {
            let openButton = NSButton(title: actionTitle, target: self, action: #selector(openPrimaryAction))
            openButton.bezelStyle = .rounded
            openButton.frame = NSRect(x: width - 128, y: buttonY, width: 104, height: 32)
            background.addSubview(openButton)
        } else {
            let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
            closeButton.bezelStyle = .rounded
            closeButton.frame = NSRect(x: width - 110, y: buttonY, width: 86, height: 32)
            background.addSubview(closeButton)
        }
    }

    private var detailText: String {
        if payloads.count == 1 {
            return payloads[0].detail
        }
        return "Review the decoded values before copying or opening."
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    @objc private func copyPayload() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payloads.map(\.copyValue).joined(separator: "\n\n"), forType: .string)
        ToastWindow.show(message: "QR copied to clipboard")
    }

    @objc private func openPrimaryAction() {
        guard let url = primaryPayload?.actionURL else { return }
        NSWorkspace.shared.open(url)
        close()
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

    private static func displayText(for payloads: [QRCodePayload]) -> String {
        if payloads.count == 1 {
            return payloads[0].displayText
        }
        return payloads.enumerated().map { index, payload in
            "QR \(index + 1) — \(payload.title.replacingOccurrences(of: " found", with: ""))\n\(payload.displayText)"
        }.joined(separator: "\n\n")
    }
}
