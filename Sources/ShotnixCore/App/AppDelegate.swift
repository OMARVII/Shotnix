import AppKit
import KeyboardShortcuts
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var captureEngine: CaptureEngine!
    var hotkeyManager: HotkeyManager!
    var historyManager: HistoryManager!
    private let welcomeController = WelcomeWindowController()
    private let menuPresenter = ShotnixModernMenuPresenter()
    private var updateController: AppUpdateController!
    private var didRegisterHotkeys = false

    // Clicking the Dock icon (shown while an editor is open) restores a buried or minimized editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if VideoDemoEditorWindowController.hasOpenEditors {
                VideoDemoEditorWindowController.bringOpenEditorsToFront()
            }
            if AnnotationWindowController.hasOpenEditors {
                AnnotationWindowController.bringOpenEditorsToFront()
            }
        }
        // Escape hatch: the status item is the app's only entry point. While it
        // is hidden, launching Shotnix again (Finder, Spotlight, Launchpad)
        // lands here — show Preferences so the user can turn the icon back on.
        if !Settings.showMenuBarIcon {
            PreferencesWindowController.shared.show(tab: .general)
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateController = AppUpdateController()
        captureEngine = CaptureEngine()
        captureEngine.recordingFinishedHandler = { url in
            Settings.lastRecordingPath = url.path
            let shouldAutoOpen = Settings.openVideoEditorAfterRecording
            let openEditor = {
                DispatchQueue.main.async {
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    VideoDemoPostRecordingPanel.dismissActive()
                    VideoDemoEditorWindowController.open(videoURL: url)
                }
            }
            VideoDemoPostRecordingPanel.show(
                videoURL: url,
                autoOpen: false,
                openHandler: openEditor
            )
            if shouldAutoOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    openEditor()
                }
            }
        }
        hotkeyManager = HotkeyManager()
        historyManager = HistoryManager()
        setupMainMenu()
        setupStatusItem()
        registerHotkeys()
        CaptureEngine.warmCaptureSound()
        let promptForNativeShortcuts = { [weak self] in
            NativeShortcutManager.promptIfNeeded {
                self?.registerHotkeys()
                self?.showReadyToastIfNeeded(delay: 2.2)
            }
        }
        if !welcomeController.showIfNeeded(onClose: promptForNativeShortcuts) {
            promptForNativeShortcuts()
            // Escape hatch on cold launch: applicationShouldHandleReopen only
            // fires for an already-running app, so with the status item hidden
            // a fresh launch would otherwise be completely invisible.
            if !Settings.showMenuBarIcon {
                PreferencesWindowController.shared.show(tab: .general)
            }
        }
    }

    private func registerHotkeys() {
        hotkeyManager.register(captureEngine: captureEngine, historyManager: historyManager)
        didRegisterHotkeys = true
    }

    private func showReadyToastIfNeeded(delay: TimeInterval = 0) {
        let show = { @MainActor in
            guard Settings.hasLaunchedBefore,
                  !Settings.didShowReadyToast,
                  PermissionsManager.hasScreenRecordingPermission,
                  !NativeShortcutManager.nativeShortcutsEnabled else { return }

            Settings.didShowReadyToast = true
            ToastWindow.show(message: "Shotnix is ready to use!", duration: 3.0, anchorView: self.statusItem.button)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                show()
            }
        } else {
            show()
        }
    }

    // MARK: – Status bar

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Shotnix")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Shotnix")
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Shotnix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Standard Edit menu — LSUIElement apps get no default menus, so without
        // it ⌘X/C/V/A/Z have no responder route (breaking paste into text
        // annotation fields and save-panel filename fields). The items target
        // the app delegate instead of using plain nil-target standard selectors:
        // a matching menu item consumes its key equivalent even while disabled,
        // so nil-target items would starve the keyDown-based shortcuts in
        // custom windows (annotation canvas ⌘Z/⌘C, quick access overlay ⌘C)
        // and shadow the Timeline menu's ⌘Z. See the Edit menu routing section.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Undo", action: #selector(editUndo(_:)), key: "z", modifiers: [.command]))
        editMenu.addItem(menuItem("Redo", action: #selector(editRedo(_:)), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(menuItem("Cut", action: #selector(editCut(_:)), key: "x", modifiers: [.command]))
        editMenu.addItem(menuItem("Copy", action: #selector(editCopy(_:)), key: "c", modifiers: [.command]))
        editMenu.addItem(menuItem("Paste", action: #selector(editPaste(_:)), key: "v", modifiers: [.command]))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(menuItem("Select All", action: #selector(editSelectAll(_:)), key: "a", modifiers: [.command]))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let timelineMenuItem = NSMenuItem()
        let timelineMenu = NSMenu(title: "Timeline")
        timelineMenu.addItem(menuItem("Split at Playhead", action: #selector(timelineSplit(_:)), key: "s", modifiers: []))
        timelineMenu.addItem(menuItem("Delete Selection", action: #selector(timelineDeleteSelection(_:)), key: "\u{8}", modifiers: []))
        timelineMenu.addItem(NSMenuItem.separator())
        timelineMenu.addItem(menuItem("Set In to Playhead", action: #selector(timelineTrimIn(_:)), key: "i", modifiers: []))
        timelineMenu.addItem(menuItem("Set Out to Playhead", action: #selector(timelineTrimOut(_:)), key: "o", modifiers: []))
        timelineMenu.addItem(menuItem("Mute Clip", action: #selector(timelineMuteClip(_:)), key: "m", modifiers: []))
        timelineMenu.addItem(NSMenuItem.separator())
        timelineMenu.addItem(menuItem("Undo Timeline Edit", action: #selector(timelineUndo(_:)), key: "z", modifiers: [.command]))
        timelineMenu.addItem(menuItem("Redo Timeline Edit", action: #selector(timelineRedo(_:)), key: "Z", modifiers: [.command, .shift]))
        timelineMenuItem.submenu = timelineMenu
        mainMenu.addItem(timelineMenuItem)

        // Minimal Window menu with the standard window-management commands.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(responderMenuItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(responderMenuItem("Zoom", action: #selector(NSWindow.performZoom(_:)), key: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(responderMenuItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), key: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// Menu item with no explicit target — the action resolves through the
    /// responder chain (text fields, editors, key window).
    private func responderMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = Settings.showMenuBarIcon
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
        let icon = NSImage(systemSymbolName: "crop", accessibilityDescription: "Shotnix")?
            .withSymbolConfiguration(config)
        icon?.isTemplate = true
        button.image = icon
        button.target = self
        button.action = #selector(toggleCommandCenter)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Keep the icon in sync with the "Show menu bar icon" preference,
        // which is toggled live from the General preferences pane.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        // Posted on whichever thread wrote the defaults (Sparkle writes from
        // background queues); NSStatusItem must only be touched on main.
        if Thread.isMainThread {
            updateStatusItemVisibility()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItemVisibility()
            }
        }
    }

    private func updateStatusItemVisibility() {
        guard let statusItem else { return }
        let shouldShow = Settings.showMenuBarIcon
        guard statusItem.isVisible != shouldShow else { return }
        statusItem.isVisible = shouldShow
    }

    // MARK: – Actions

    @objc func captureArea()         { Task { await captureEngine.startAreaCapture(historyManager: historyManager) } }
    @objc func captureWindow()       { Task { await captureEngine.startWindowCapture(historyManager: historyManager) } }
    @objc func captureFullscreen()   { Task { await captureEngine.captureFullscreen(historyManager: historyManager) } }
    @objc func capturePrevious()     { Task { await captureEngine.capturePreviousArea(historyManager: historyManager) } }
    @objc func captureScrolling()    { Task { await captureEngine.startScrollingCapture(historyManager: historyManager) } }
    @objc func recordArea()          { Task { await captureEngine.startAreaRecording() } }
    @objc func recordWindow()        { Task { await captureEngine.startWindowRecording() } }
    @objc func recordFullscreen()    { Task { await captureEngine.startFullscreenRecording() } }
    @objc func stopRecording()       { captureEngine.stopRecording() }
    @objc func captureText()         { Task { await captureEngine.startOCRCapture() } }
    @objc func scanQRCode()          { Task { await captureEngine.startQRCodeCapture() } }
    @objc func showEditor()          { AnnotationWindowController.bringOpenEditorsToFront() }
    @objc func showVideoEditor() {
        if VideoDemoEditorWindowController.hasOpenEditors {
            VideoDemoEditorWindowController.bringOpenEditorsToFront()
        } else if let url = Settings.resolvedLastRecordingURL {
            Settings.lastRecordingPath = url.path
            VideoDemoEditorWindowController.open(videoURL: url)
        } else {
            openVideoEditor()
        }
    }
    @objc func editLastRecording() {
        guard let url = Settings.resolvedLastRecordingURL else {
            openVideoEditor()
            return
        }
        Settings.lastRecordingPath = url.path
        VideoDemoEditorWindowController.open(videoURL: url)
    }
    @objc func openVideoEditor() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.lastRecordingPath = url.path
        VideoDemoEditorWindowController.open(videoURL: url)
    }
    @objc func annotateLastScreenshot() {
        guard let last = historyManager.items.first else { return }
        AnnotationWindowController.open(image: last.fullImage, historyItem: last, historyManager: historyManager)
    }
    @objc func openHistory()         { HistoryPanelController.shared.show(historyManager: historyManager) }
    @objc func toggleDesktopIcons()  { DesktopIconsManager.toggle() }
    @objc func openPreferences()     { PreferencesWindowController.shared.show(tab: .general) }
    @objc func openShortcutsPreferences() { PreferencesWindowController.shared.show(tab: .shortcuts) }
    @objc func openAbout()           { PreferencesWindowController.shared.show(tab: .about) }
    @objc func checkForUpdates(_ sender: Any?) { updateController?.checkForUpdates(sender) }
    @objc func timelineSplit(_ sender: Any?) { VideoDemoEditorWindowController.splitActiveEditor() }
    @objc func timelineDeleteSelection(_ sender: Any?) { VideoDemoEditorWindowController.deleteActiveSelection() }
    @objc func timelineTrimIn(_ sender: Any?) { VideoDemoEditorWindowController.trimActiveInToPlayhead() }
    @objc func timelineTrimOut(_ sender: Any?) { VideoDemoEditorWindowController.trimActiveOutToPlayhead() }
    @objc func timelineMuteClip(_ sender: Any?) { VideoDemoEditorWindowController.muteActiveClip() }
    @objc func timelineUndo(_ sender: Any?) { VideoDemoEditorWindowController.undoActiveTimelineEdit() }
    @objc func timelineRedo(_ sender: Any?) { VideoDemoEditorWindowController.redoActiveTimelineEdit() }

    // MARK: – Edit menu routing
    //
    // AppKit consumes a menu item's key equivalent even when the item is
    // disabled, so plain nil-target Edit items would swallow ⌘Z/⌘C before the
    // keyDown-based shortcuts in custom windows (annotation canvas, quick
    // access overlay) or the Timeline menu ever see them. These handlers try
    // the focused responder first and then fall back to app-specific handling.

    @objc func editUndo(_ sender: Any?) {
        // Focused text contexts (field editors, save panels) win.
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canUndo {
            undoManager.undo()
            return
        }
        // The video editor's timeline undo stack is separate from NSUndoManager.
        if NSApp.keyWindow?.delegate is VideoDemoEditorWindowController {
            VideoDemoEditorWindowController.undoActiveTimelineEdit()
            return
        }
        // Windows with keyDown-based undo (annotation canvas) get the raw event.
        replayKeyEquivalent(characters: "z", keyCode: 6, modifiers: [.command])
    }

    @objc func editRedo(_ sender: Any?) {
        if let undoManager = NSApp.keyWindow?.firstResponder?.undoManager, undoManager.canRedo {
            undoManager.redo()
            return
        }
        if NSApp.keyWindow?.delegate is VideoDemoEditorWindowController {
            VideoDemoEditorWindowController.redoActiveTimelineEdit()
            return
        }
        replayKeyEquivalent(characters: "z", keyCode: 6, modifiers: [.command, .shift])
    }

    @objc func editCut(_ sender: Any?)       { dispatchEditAction(#selector(NSText.cut(_:)), characters: "x", keyCode: 7) }
    @objc func editCopy(_ sender: Any?)      { dispatchEditAction(#selector(NSText.copy(_:)), characters: "c", keyCode: 8) }
    @objc func editPaste(_ sender: Any?)     { dispatchEditAction(#selector(NSText.paste(_:)), characters: "v", keyCode: 9) }
    @objc func editSelectAll(_ sender: Any?) { dispatchEditAction(#selector(NSText.selectAll(_:)), characters: "a", keyCode: 0) }

    /// Sends a standard editing action through the responder chain (text views,
    /// field editors). If nothing claims it, replays the shortcut as a plain
    /// keyDown so custom windows keep their keyDown-based ⌘-key handling.
    private func dispatchEditAction(_ action: Selector, characters: String, keyCode: UInt16) {
        if NSApp.sendAction(action, to: nil, from: nil) { return }
        replayKeyEquivalent(characters: characters, keyCode: keyCode, modifiers: [.command])
    }

    /// Re-delivers a shortcut to the key window's first responder as a keyDown.
    /// Safe from re-entry: direct keyDown dispatch never re-enters menu
    /// key-equivalent processing.
    private func replayKeyEquivalent(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: modifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: characters,
                  charactersIgnoringModifiers: characters,
                  isARepeat: false,
                  keyCode: keyCode
              ) else { return }
        window.firstResponder?.keyDown(with: event)
    }

    @objc private func toggleCommandCenter(_ sender: Any?) {
        if menuPresenter.isShown {
            menuPresenter.dismiss()
            return
        }

        guard let button = statusItem.button else { return }
        menuPresenter.showCommandCenter(
            sections: commandCenterSections(),
            healthRows: ShotnixHealthModel.rows(snapshot: .live(updatesConfigured: AppUpdateConfiguration.current != nil)),
            healthActions: healthActions(),
            relativeTo: button
        )
    }

    private func commandCenterSections() -> [ShotnixMenuSection] {
        [
            ShotnixMenuSection(id: "capture", title: "Capture", actions: [
                action(id: "capture.area", title: "Capture Area", symbol: "rectangle.dashed", shortcut: .shotnixCaptureArea, role: .primary) { [weak self] in self?.captureArea() },
                action(id: "capture.window", title: "Capture Window", symbol: "macwindow", shortcut: .shotnixCaptureWindow) { [weak self] in self?.captureWindow() },
                action(id: "capture.fullscreen", title: "Capture Fullscreen", symbol: "rectangle.on.rectangle", shortcut: .shotnixCaptureFullscreenNative) { [weak self] in self?.captureFullscreen() },
                action(id: "capture.previous", title: "Capture Previous Area", symbol: "arrow.counterclockwise.circle", shortcut: .shotnixCapturePreviousArea) { [weak self] in self?.capturePrevious() },
                action(id: "capture.scrolling", title: "Scrolling Capture", symbol: "scroll", shortcut: .shotnixCaptureScrolling) { [weak self] in self?.captureScrolling() },
            ]),
            ShotnixMenuSection(id: "record", title: "Record", actions: [
                action(id: "record.area", title: "Record Area", symbol: "record.circle", shortcut: .shotnixRecordArea, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordArea() },
                action(id: "record.window", title: "Record Window", symbol: "macwindow.badge.plus", shortcut: .shotnixRecordWindow, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordWindow() },
                action(id: "record.fullscreen", title: "Record Fullscreen", symbol: "rectangle.fill.on.rectangle.fill", shortcut: .shotnixRecordFullscreen, isEnabled: captureEngine?.recordingActionsEnabled ?? false) { [weak self] in self?.recordFullscreen() },
                action(
                    id: "record.stop",
                    title: captureEngine?.recordingStopTitle ?? "Stop Recording",
                    symbol: "stop.circle",
                    shortcut: .shotnixStopRecording,
                    isEnabled: captureEngine?.recordingStopEnabled ?? false,
                    role: .destructive
                ) { [weak self] in self?.stopRecording() },
            ]),
            ShotnixMenuSection(id: "tools", title: "Tools", actions: [
                action(id: "tools.ocr", title: "Capture Text", symbol: "text.viewfinder", shortcut: .shotnixCaptureText) { [weak self] in self?.captureText() },
                action(id: "tools.qr", title: "Scan QR Code", symbol: "qrcode.viewfinder") { [weak self] in self?.scanQRCode() },
                action(id: "tools.video-editor", title: "Open Video Editor", symbol: "film.stack", role: .primary) { [weak self] in self?.openVideoEditor() },
                action(id: "tools.last-recording", title: "Edit Last Recording", symbol: "play.rectangle.on.rectangle") { [weak self] in self?.editLastRecording() },
                action(id: "tools.annotate-last", title: "Annotate Last Screenshot", symbol: "pencil.tip.crop.circle", isEnabled: !(historyManager?.items.isEmpty ?? true)) { [weak self] in self?.annotateLastScreenshot() },
            ]),
            ShotnixMenuSection(id: "utility", title: "Utility", actions: [
                action(id: "utility.history", title: "Open History", symbol: "clock.arrow.circlepath") { [weak self] in self?.openHistory() },
                action(id: "utility.editor", title: "Show Editor", symbol: "pencil.and.outline", isEnabled: AnnotationWindowController.hasOpenEditors) { [weak self] in self?.showEditor() },
                action(id: "utility.video-editor", title: "Show Video Editor", symbol: "film") { [weak self] in self?.showVideoEditor() },
                action(id: "utility.desktop-icons", title: DesktopIconsManager.desktopIconsVisible ? "Hide Desktop Icons" : "Show Desktop Icons", symbol: DesktopIconsManager.desktopIconsVisible ? "eye.slash" : "eye") { [weak self] in self?.toggleDesktopIcons() },
            ]),
            ShotnixMenuSection(id: "settings", title: "Settings", actions: [
                action(id: "settings.preferences", title: "Preferences", symbol: "gearshape", shortcutText: "⌘,") { [weak self] in self?.openPreferences() },
                action(id: "settings.about", title: "About Shotnix", symbol: "info.circle") { [weak self] in self?.openAbout() },
                action(id: "settings.update", title: "Check for Updates", symbol: "arrow.triangle.2.circlepath", isEnabled: updateController?.canCheckForUpdates ?? false) { [weak self] in self?.checkForUpdates(nil) },
                action(id: "settings.quit", title: "Quit Shotnix", symbol: "power", shortcutText: "⌘Q", role: .destructive) { NSApp.terminate(nil) },
            ]),
        ]
    }

    private func healthActions() -> [ShotnixHealthKind: () -> Void] {
        [
            .screenRecording: { PermissionsManager.openScreenRecordingSettings() },
            .nativeShortcuts: {
                if NativeShortcutManager.disableNativeShortcuts() {
                    ToastWindow.show(message: "Apple screenshot shortcuts disabled.")
                } else {
                    NativeShortcutManager.openKeyboardSettings()
                }
            },
            .updates: { [weak self] in self?.checkForUpdates(nil) },
            .autoSave: { [weak self] in self?.chooseAutoSaveFolder() },
            .shortcuts: { [weak self] in self?.openShortcutsPreferences() }
        ]
    }

    private func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Settings.setAutoSaveLocation(url.path) {
            ToastWindow.show(message: "Save folder updated.")
        } else {
            ToastWindow.show(message: "Choose a writable folder.")
        }
    }

    private func action(
        id: String,
        title: String,
        symbol: String,
        shortcut: KeyboardShortcuts.Name? = nil,
        shortcutText: String? = nil,
        isEnabled: Bool = true,
        role: ShotnixMenuRole = .normal,
        handler: @escaping () -> Void
    ) -> ShotnixMenuAction {
        ShotnixMenuAction(
            id: id,
            title: title,
            symbolName: symbol,
            shortcut: shortcutText ?? shortcut.flatMap(shortcutDisplay),
            isEnabled: isEnabled,
            role: role,
            handler: handler
        )
    }

    private func shortcutDisplay(for name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
