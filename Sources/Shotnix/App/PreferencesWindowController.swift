import AppKit
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSObject {

    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Shotnix — Preferences"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = buildContent()
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func buildContent() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 440))
        var y: CGFloat = 396

        // MARK: General
        addLabel("General", to: view, at: NSPoint(x: 20, y: y), bold: true)
        y -= 30

        let loginToggle = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLoginItem))
        loginToggle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        view.addSubview(loginToggle)
        y -= 36

        // MARK: Separator
        let sep1 = NSBox(); sep1.boxType = .separator
        sep1.frame = NSRect(x: 20, y: y, width: 380, height: 1)
        view.addSubview(sep1)
        y -= 20

        // MARK: Quick Access Overlay
        addLabel("Quick Access Overlay", to: view, at: NSPoint(x: 20, y: y), bold: true)
        y -= 30

        // Position
        addLabel("Position:", to: view, at: NSPoint(x: 20, y: y + 2))
        let positionControl = NSSegmentedControl(
            labels: ["Left", "Right"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(positionChanged(_:))
        )
        positionControl.frame = NSRect(x: 140, y: y, width: 160, height: 24)
        positionControl.selectedSegment = Settings.overlayOnLeft ? 0 : 1
        view.addSubview(positionControl)
        y -= 36

        // Timeout
        addLabel("Auto-dismiss:", to: view, at: NSPoint(x: 20, y: y + 2))
        let timeoutPopup = NSPopUpButton(frame: NSRect(x: 140, y: y, width: 180, height: 24), pullsDown: false)
        let options: [(String, Double)] = [
            ("3 seconds", 3),
            ("6 seconds", 6),
            ("10 seconds", 10),
            ("30 seconds", 30),
            ("Never (keep visible)", -1),
        ]
        for (label, value) in options {
            timeoutPopup.addItem(withTitle: label)
            timeoutPopup.lastItem?.representedObject = value
        }
        // Select current value
        let current = Settings.overlayTimeout
        let idx = options.firstIndex(where: { $0.1 == current }) ?? 1
        timeoutPopup.selectItem(at: idx)
        timeoutPopup.target = self
        timeoutPopup.action = #selector(timeoutChanged(_:))
        view.addSubview(timeoutPopup)
        y -= 14

        let timeoutHint = NSTextField(labelWithString: "\"Never\" keeps the overlay until you dismiss it manually.")
        timeoutHint.font = .systemFont(ofSize: 10)
        timeoutHint.textColor = .secondaryLabelColor
        timeoutHint.frame = NSRect(x: 20, y: y, width: 380, height: 14)
        view.addSubview(timeoutHint)
        y -= 36

        // MARK: Separator
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.frame = NSRect(x: 20, y: y, width: 380, height: 1)
        view.addSubview(sep2)
        y -= 20

        // MARK: Hotkeys
        addLabel("Default Hotkeys", to: view, at: NSPoint(x: 20, y: y), bold: true)
        y -= 28
        for (title, key) in [
            ("Capture Area",       "⌘⇧4"),
            ("Capture Window",     "⌘⇧5"),
            ("Capture Fullscreen", "⌘⇧6"),
            ("Capture Previous",   "⌘⇧7"),
            ("OCR / Capture Text", "⌘⇧O"),
            ("Scrolling Capture",  "⌘⇧S"),
        ] {
            let row = NSView(frame: NSRect(x: 20, y: y, width: 380, height: 20))
            let lbl = NSTextField(labelWithString: title)
            lbl.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
            let keyLbl = NSTextField(labelWithString: key)
            keyLbl.frame = NSRect(x: 220, y: 0, width: 160, height: 20)
            keyLbl.textColor = .secondaryLabelColor
            row.addSubview(lbl); row.addSubview(keyLbl)
            view.addSubview(row)
            y -= 22
        }

        return view
    }

    // MARK: – Helpers

    private func addLabel(_ text: String, to view: NSView, at point: NSPoint, bold: Bool = false) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        lbl.frame = NSRect(origin: point, size: CGSize(width: 380, height: 20))
        view.addSubview(lbl)
    }

    // MARK: – Actions

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = (sender.state == .on) ? .off : .on
        }
    }

    @objc private func positionChanged(_ sender: NSSegmentedControl) {
        Settings.overlayOnLeft = sender.selectedSegment == 0
    }

    @objc private func timeoutChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Double {
            Settings.overlayTimeout = value
        }
    }
}
