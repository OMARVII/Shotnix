import AppKit
import ServiceManagement

enum PreferencesTab: Int, CaseIterable {
    case general = 0
    case shortcuts = 1
    case screenshots = 2
    case about = 3

    var title: String {
        switch self {
        case .general:     return "General"
        case .shortcuts:   return "Shortcuts"
        case .screenshots: return "Screenshots"
        case .about:       return "About"
        }
    }

    var iconName: String {
        switch self {
        case .general:     return "gearshape"
        case .shortcuts:   return "keyboard"
        case .screenshots: return "camera"
        case .about:       return "info.circle"
        }
    }
}

@MainActor
final class PreferencesWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {

    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    private var contentBox: NSView?
    private var currentTab: PreferencesTab = .general
    private let toolbarID = NSToolbar.Identifier("PreferencesToolbar")

    private var jpegQualitySlider: NSSlider?
    private var jpegQualityLabel: NSTextField?
    private var jpegQualityRow: NSView?

    func show(tab: PreferencesTab = .general) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            switchTab(to: tab)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = tab.title
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let toolbar = NSToolbar(identifier: toolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = itemIdentifier(for: tab)
        win.toolbar = toolbar

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        win.contentView = container
        contentBox = container

        window = win
        currentTab = tab
        loadTabContent(tab)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        contentBox = nil
        NSApp.setActivationPolicy(.prohibited)
    }

    // MARK: - Tab switching

    private func switchTab(to tab: PreferencesTab) {
        guard let win = window else { return }
        win.toolbar?.selectedItemIdentifier = itemIdentifier(for: tab)
        win.title = tab.title
        currentTab = tab
        loadTabContent(tab)
    }

    private func loadTabContent(_ tab: PreferencesTab) {
        guard let container = contentBox else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let content: NSView
        switch tab {
        case .general:     content = buildGeneralTab()
        case .shortcuts:   content = buildShortcutsTab()
        case .screenshots: content = buildScreenshotsTab()
        case .about:       content = buildAboutTab()
        }

        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }

    // MARK: - NSToolbarDelegate

    private func itemIdentifier(for tab: PreferencesTab) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("tab_\(tab.rawValue)")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesTab.allCases.map { itemIdentifier(for: $0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = PreferencesTab.allCases.first(where: { itemIdentifier(for: $0) == identifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.iconName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        item.tag = tab.rawValue
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = PreferencesTab(rawValue: sender.tag) else { return }
        switchTab(to: tab)
    }

    // MARK: - General Tab

    private func buildGeneralTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        let inset: CGFloat = 40
        let contentWidth: CGFloat = 620 - inset * 2
        var y: CGFloat = 470

        // Startup
        addSectionHeader("Startup", to: view, y: &y, inset: inset)

        let loginToggle = NSButton(checkboxWithTitle: "Launch Shotnix at login", target: self, action: #selector(toggleLoginItem(_:)))
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(loginToggle)
        y -= 30

        addSeparator(to: view, y: &y, inset: inset, width: contentWidth)

        // Sounds
        addSectionHeader("Sounds", to: view, y: &y, inset: inset)

        let soundToggle = NSButton(checkboxWithTitle: "Play capture sound", target: self, action: #selector(playSoundsChanged(_:)))
        soundToggle.state = Settings.playSounds ? .on : .off
        soundToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(soundToggle)
        y -= 30

        addSeparator(to: view, y: &y, inset: inset, width: contentWidth)

        // Menu Bar
        addSectionHeader("Menu Bar", to: view, y: &y, inset: inset)

        let menuBarToggle = NSButton(checkboxWithTitle: "Show menu bar icon", target: self, action: #selector(showMenuBarIconChanged(_:)))
        menuBarToggle.state = Settings.showMenuBarIcon ? .on : .off
        menuBarToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(menuBarToggle)
        y -= 24

        let hideIconsToggle = NSButton(checkboxWithTitle: "Hide desktop icons while capturing", target: self, action: #selector(hideDesktopIconsChanged(_:)))
        hideIconsToggle.state = Settings.hideDesktopIconsWhileCapturing ? .on : .off
        hideIconsToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(hideIconsToggle)
        y -= 30

        addSeparator(to: view, y: &y, inset: inset, width: contentWidth)

        // After Capture
        addSectionHeader("After Capture", to: view, y: &y, inset: inset)

        let afterDesc = NSTextField(wrappingLabelWithString: "Choose what happens after taking a screenshot:")
        afterDesc.font = .systemFont(ofSize: 11)
        afterDesc.textColor = .secondaryLabelColor
        afterDesc.frame = NSRect(x: inset, y: y, width: contentWidth, height: 16)
        view.addSubview(afterDesc)
        y -= 26

        let overlayToggle = NSButton(checkboxWithTitle: "Show Quick Access Overlay", target: self, action: #selector(afterCaptureShowOverlayChanged(_:)))
        overlayToggle.state = Settings.afterCaptureShowOverlay ? .on : .off
        overlayToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(overlayToggle)
        y -= 24

        let clipboardToggle = NSButton(checkboxWithTitle: "Copy file to clipboard", target: self, action: #selector(afterCaptureCopyChanged(_:)))
        clipboardToggle.state = Settings.afterCaptureCopyToClipboard ? .on : .off
        clipboardToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(clipboardToggle)
        y -= 24

        let autoSaveToggle = NSButton(checkboxWithTitle: "Save automatically", target: self, action: #selector(afterCaptureSaveChanged(_:)))
        autoSaveToggle.state = Settings.afterCaptureSaveAutomatically ? .on : .off
        autoSaveToggle.frame = NSRect(x: inset, y: y, width: contentWidth, height: 20)
        view.addSubview(autoSaveToggle)
        y -= 30

        // Overlay position
        let posLabel = NSTextField(labelWithString: "Overlay position:")
        posLabel.frame = NSRect(x: inset, y: y + 2, width: 120, height: 20)
        view.addSubview(posLabel)

        let positionControl = NSSegmentedControl(
            labels: ["Left", "Right"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(positionChanged(_:))
        )
        positionControl.frame = NSRect(x: inset + 130, y: y, width: 140, height: 24)
        positionControl.selectedSegment = Settings.overlayOnLeft ? 0 : 1
        view.addSubview(positionControl)
        y -= 30

        // Auto-dismiss
        let timeoutLabel = NSTextField(labelWithString: "Auto-dismiss:")
        timeoutLabel.frame = NSRect(x: inset, y: y + 2, width: 120, height: 20)
        view.addSubview(timeoutLabel)

        let timeoutPopup = NSPopUpButton(frame: NSRect(x: inset + 130, y: y, width: 180, height: 24), pullsDown: false)
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
        let current = Settings.overlayTimeout
        let idx = options.firstIndex(where: { $0.1 == current }) ?? 1
        timeoutPopup.selectItem(at: idx)
        timeoutPopup.target = self
        timeoutPopup.action = #selector(timeoutChanged(_:))
        view.addSubview(timeoutPopup)

        return view
    }

    // MARK: - Shortcuts Tab

    private func buildShortcutsTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        let inset: CGFloat = 40
        let contentWidth: CGFloat = 620 - inset * 2
        var y: CGFloat = 470

        addSectionHeader("Keyboard Shortcuts", to: view, y: &y, inset: inset)

        let desc = NSTextField(wrappingLabelWithString: "These shortcuts are system-wide and always active while Shotnix is running.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.frame = NSRect(x: inset, y: y, width: contentWidth, height: 16)
        view.addSubview(desc)
        y -= 30

        let shortcuts: [(String, String)] = [
            ("Capture Area",       "\u{2318}\u{21E7}4"),
            ("Capture Window",     "\u{2318}\u{21E7}5"),
            ("Capture Fullscreen", "\u{2318}\u{21E7}6"),
            ("Capture Previous Area", "\u{2318}\u{21E7}7"),
            ("OCR / Capture Text", "\u{2318}\u{21E7}O"),
            ("Scrolling Capture",  "\u{2318}\u{21E7}S"),
        ]

        for (title, key) in shortcuts {
            let row = NSView(frame: NSRect(x: inset, y: y, width: contentWidth, height: 28))

            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.frame = NSRect(x: 0, y: 4, width: 240, height: 20)
            row.addSubview(titleLabel)

            let keyBg = NSView(frame: NSRect(x: contentWidth - 100, y: 2, width: 80, height: 24))
            keyBg.wantsLayer = true
            keyBg.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            keyBg.layer?.cornerRadius = 5
            row.addSubview(keyBg)

            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.alignment = .center
            keyLabel.frame = NSRect(x: contentWidth - 100, y: 4, width: 80, height: 20)
            row.addSubview(keyLabel)

            view.addSubview(row)
            y -= 34
        }

        y -= 10
        let note = NSTextField(wrappingLabelWithString: "Hotkeys are system-wide and always active while the app is running.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: inset, y: y, width: contentWidth, height: 16)
        view.addSubview(note)

        return view
    }

    // MARK: - Screenshots Tab

    private func buildScreenshotsTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        let inset: CGFloat = 40
        let contentWidth: CGFloat = 620 - inset * 2
        var y: CGFloat = 470

        addSectionHeader("Export Format", to: view, y: &y, inset: inset)

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.frame = NSRect(x: inset, y: y + 2, width: 120, height: 20)
        view.addSubview(formatLabel)

        let formatPopup = NSPopUpButton(frame: NSRect(x: inset + 130, y: y, width: 140, height: 24), pullsDown: false)
        let formats: [(String, String)] = [("PNG", "png"), ("JPEG", "jpeg"), ("WebP", "webp")]
        for (title, value) in formats {
            formatPopup.addItem(withTitle: title)
            formatPopup.lastItem?.representedObject = value
        }
        let selectedIdx = formats.firstIndex(where: { $0.1 == Settings.screenshotFormat }) ?? 0
        formatPopup.selectItem(at: selectedIdx)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        view.addSubview(formatPopup)
        y -= 36

        // JPEG Quality row (hidden when PNG selected)
        let qualityRow = NSView(frame: NSRect(x: inset, y: y, width: contentWidth, height: 24))

        let qualityLabel = NSTextField(labelWithString: "JPEG Quality:")
        qualityLabel.frame = NSRect(x: 0, y: 2, width: 120, height: 20)
        qualityRow.addSubview(qualityLabel)

        let slider = NSSlider(value: Settings.jpegQuality * 100,
                              minValue: 10, maxValue: 100,
                              target: self, action: #selector(jpegQualityChanged(_:)))
        slider.frame = NSRect(x: 130, y: 2, width: 240, height: 20)
        qualityRow.addSubview(slider)
        jpegQualitySlider = slider

        let pctLabel = NSTextField(labelWithString: "\(Int(Settings.jpegQuality * 100))%")
        pctLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pctLabel.frame = NSRect(x: 380, y: 2, width: 50, height: 20)
        qualityRow.addSubview(pctLabel)
        jpegQualityLabel = pctLabel

        qualityRow.isHidden = (Settings.screenshotFormat != "jpeg")
        view.addSubview(qualityRow)
        jpegQualityRow = qualityRow
        y -= 36

        addSeparator(to: view, y: &y, inset: inset, width: contentWidth)

        addSectionHeader("Save Location", to: view, y: &y, inset: inset)

        let pathLabel = NSTextField(labelWithString: Settings.autoSaveLocation)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: inset, y: y + 2, width: contentWidth - 90, height: 20)
        pathLabel.tag = 100
        view.addSubview(pathLabel)

        let chooseBtn = NSButton(title: "Choose...", target: self, action: #selector(chooseAutoSaveLocation(_:)))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.frame = NSRect(x: inset + contentWidth - 80, y: y, width: 80, height: 24)
        view.addSubview(chooseBtn)

        return view
    }

    // MARK: - About Tab

    private func buildAboutTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        let centerX: CGFloat = 310
        var y: CGFloat = 480

        // App icon
        let iconSize: CGFloat = 80
        let iconView = NSImageView(frame: NSRect(x: centerX - iconSize / 2, y: y - iconSize, width: iconSize, height: iconSize))
        if let icon = NSImage(named: "NSApplicationIcon") {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)
        y -= iconSize + 8

        // App name
        let nameLabel = NSTextField(labelWithString: "Shotnix")
        nameLabel.font = .boldSystemFont(ofSize: 22)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 40, y: y - 28, width: 540, height: 28)
        view.addSubview(nameLabel)
        y -= 34

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.2-beta"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 40, y: y - 18, width: 540, height: 18)
        view.addSubview(versionLabel)
        y -= 28

        addSeparator(to: view, y: &y, inset: 40, width: 540)

        // What's New header
        let whatsNewLabel = NSTextField(labelWithString: "What's New")
        whatsNewLabel.font = .boldSystemFont(ofSize: 14)
        whatsNewLabel.frame = NSRect(x: 40, y: y - 20, width: 540, height: 20)
        view.addSubview(whatsNewLabel)
        y -= 28

        // Scrollable changelog
        let scrollHeight: CGFloat = 180
        let scrollView = NSScrollView(frame: NSRect(x: 40, y: y - scrollHeight, width: 540, height: scrollHeight))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: scrollHeight))
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .systemFont(ofSize: 12)
        textView.string = """
        Version 0.9.2-beta
        \u{2022} WebP export support (macOS 14+)
        \u{2022} First-launch onboarding with permission guide
        \u{2022} After-capture auto-actions (auto-copy, auto-save)
        \u{2022} Fixed multi-display capture coordinates
        \u{2022} Screenshot colors now match display calibration exactly

        Version 0.9.1-beta
        \u{2022} Pixel-perfect screenshot quality (fixed CoreGraphics resampling blur)
        \u{2022} Correct DPI metadata for Retina captures
        \u{2022} Timestamped filenames \u{2014} "Shotnix 2026-04-12 at 10.30.48"
        \u{2022} Auto-disable conflicting macOS screenshot shortcuts on first launch
        \u{2022} Fixed windows not coming to front (preferences, history, annotation)
        \u{2022} Crash guards for empty screen arrays and async cleanup races

        Version 0.9.0-beta
        \u{2022} Area, window, and fullscreen capture
        \u{2022} Scrolling capture for long content
        \u{2022} OCR text recognition (\u{2318}\u{21E7}O)
        \u{2022} Full annotation editor \u{2014} arrows, shapes, blur, text, crop
        \u{2022} Quick access overlay with drag-and-drop
        \u{2022} Pin screenshots to desktop
        \u{2022} Capture history with grid browser
        \u{2022} Global hotkeys (\u{2318}\u{21E7}4/5/6/7)
        \u{2022} Launch at login support
        \u{2022} Full settings window (General, Shortcuts, Screenshots, About)
        \u{2022} Keyboard shortcuts on overlay (\u{2318}C copy, \u{2318}S save, \u{2318}E edit)
        \u{2022} Right-click context menu on overlay
        """

        scrollView.documentView = textView
        view.addSubview(scrollView)
        y -= scrollHeight + 16

        // Copyright
        let copyright = NSTextField(labelWithString: "\u{00A9} 2026 Shotnix Contributors")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center
        copyright.frame = NSRect(x: 40, y: y - 16, width: 540, height: 16)
        view.addSubview(copyright)
        y -= 22

        // License
        let license = NSTextField(labelWithString: "MIT License \u{2014} Free and open source")
        license.font = .systemFont(ofSize: 10)
        license.textColor = .tertiaryLabelColor
        license.alignment = .center
        license.frame = NSRect(x: 40, y: y - 14, width: 540, height: 14)
        view.addSubview(license)
        y -= 22

        // GitHub link
        let gitHubBtn = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        gitHubBtn.bezelStyle = .inline
        gitHubBtn.isBordered = false
        gitHubBtn.font = .systemFont(ofSize: 12)
        gitHubBtn.contentTintColor = .linkColor
        gitHubBtn.frame = NSRect(x: centerX - 30, y: y - 18, width: 60, height: 18)
        view.addSubview(gitHubBtn)

        return view
    }

    // MARK: - Layout Helpers

    private func addSectionHeader(_ text: String, to view: NSView, y: inout CGFloat, inset: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        label.frame = NSRect(x: inset, y: y, width: 300, height: 18)
        view.addSubview(label)
        y -= 26
    }

    private func addSeparator(to view: NSView, y: inout CGFloat, inset: CGFloat, width: CGFloat) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: inset, y: y, width: width, height: 1)
        view.addSubview(sep)
        y -= 16
    }

    // MARK: - Actions: General

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

    @objc private func playSoundsChanged(_ sender: NSButton) {
        Settings.playSounds = sender.state == .on
    }

    @objc private func showMenuBarIconChanged(_ sender: NSButton) {
        Settings.showMenuBarIcon = sender.state == .on
    }

    @objc private func hideDesktopIconsChanged(_ sender: NSButton) {
        Settings.hideDesktopIconsWhileCapturing = sender.state == .on
    }

    @objc private func afterCaptureShowOverlayChanged(_ sender: NSButton) {
        Settings.afterCaptureShowOverlay = sender.state == .on
    }

    @objc private func afterCaptureCopyChanged(_ sender: NSButton) {
        Settings.afterCaptureCopyToClipboard = sender.state == .on
    }

    @objc private func afterCaptureSaveChanged(_ sender: NSButton) {
        Settings.afterCaptureSaveAutomatically = sender.state == .on
    }

    @objc private func positionChanged(_ sender: NSSegmentedControl) {
        Settings.overlayOnLeft = sender.selectedSegment == 0
    }

    @objc private func timeoutChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Double {
            Settings.overlayTimeout = value
        }
    }

    // MARK: - Actions: Screenshots

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let format = sender.selectedItem?.representedObject as? String ?? "png"
        Settings.screenshotFormat = format
        jpegQualityRow?.isHidden = format != "jpeg"
    }

    @objc private func jpegQualityChanged(_ sender: NSSlider) {
        let value = sender.doubleValue / 100.0
        Settings.jpegQuality = value
        jpegQualityLabel?.stringValue = "\(Int(sender.doubleValue))%"
    }

    @objc private func chooseAutoSaveLocation(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.autoSaveLocation = url.path
        if let pathLabel = sender.superview?.subviews.first(where: { $0.tag == 100 }) as? NSTextField {
            pathLabel.stringValue = url.path
        }
    }

    // MARK: - Actions: About

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/OMARVII/Shotnix")!)
    }
}
