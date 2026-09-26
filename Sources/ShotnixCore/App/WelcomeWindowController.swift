import AppKit

/// First-launch setup checklist. Unlike the old one-shot welcome screen, this
/// window reflects live state, offers the restart macOS requires after
/// granting Screen Recording, and only counts onboarding as complete once the
/// user takes their first screenshot (or explicitly skips setup). Until then
/// it reappears on every launch.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    /// Set by the AppDelegate — triggers a real area capture for step 3.
    var testCaptureHandler: (() -> Void)?

    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var refreshTimer: Timer?
    private var captureObserver: NSObjectProtocol?

    private var permissionRow: ChecklistStepRow?
    private var shortcutsRow: ChecklistStepRow?
    private var captureRow: ChecklistStepRow?

    @discardableResult
    func showIfNeeded(onClose: (() -> Void)? = nil) -> Bool {
        guard !Settings.onboardingCompleted else { return false }
        guard window == nil else { return true }
        Settings.hasLaunchedBefore = true
        self.onClose = onClose
        showWindow()
        return true
    }

    private func showWindow() {
        let width: CGFloat = 490
        let height: CGFloat = 470

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        win.contentView = background

        buildContent(in: background, width: width, height: height)
        refresh()

        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win

        // Permission and shortcut state change outside this window (System
        // Settings, the macOS grant dialog) — poll so rows update live.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        captureObserver = NotificationCenter.default.addObserver(
            forName: .shotnixDidFinishFirstCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.firstCaptureCompleted() }
        }
    }

    private func buildContent(in container: NSView, width: CGFloat, height: CGFloat) {
        let centerX = width / 2
        var y = height - 30

        let iconSize: CGFloat = 52
        let iconView = NSImageView(frame: NSRect(x: centerX - iconSize / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)
        y -= iconSize + 6

        let title = NSTextField(labelWithString: "Welcome to Shotnix")
        title.font = .boldSystemFont(ofSize: 21)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
        container.addSubview(title)
        y -= 28

        let desc = NSTextField(labelWithString: "Three quick steps and you're capturing.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 44, y: y - 18, width: width - 88, height: 16)
        container.addSubview(desc)
        y -= 32

        let rowHeight: CGFloat = 78
        let rowX: CGFloat = 24
        let rowWidth = width - 48

        let permission = ChecklistStepRow(
            frame: NSRect(x: rowX, y: y - rowHeight, width: rowWidth, height: rowHeight),
            step: "1",
            title: "Allow Screen Recording"
        )
        container.addSubview(permission)
        permissionRow = permission
        y -= rowHeight + 8

        let shortcuts = ChecklistStepRow(
            frame: NSRect(x: rowX, y: y - rowHeight, width: rowWidth, height: rowHeight),
            step: "2",
            title: "Free up ⌘⇧ shortcuts · optional"
        )
        container.addSubview(shortcuts)
        shortcutsRow = shortcuts
        y -= rowHeight + 8

        let capture = ChecklistStepRow(
            frame: NSRect(x: rowX, y: y - rowHeight, width: rowWidth, height: rowHeight),
            step: "3",
            title: "Take your first screenshot"
        )
        container.addSubview(capture)
        captureRow = capture
        y -= rowHeight + 6

        let hint = NSTextField(labelWithString: Self.shortcutsHint())
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: 52, width: width - 40, height: 14)
        container.addSubview(hint)

        let skipBtn = NSButton(title: "Skip Setup", target: self, action: #selector(skipClicked))
        skipBtn.bezelStyle = .rounded
        skipBtn.controlSize = .regular
        skipBtn.frame = NSRect(x: centerX - 60, y: 14, width: 120, height: 30)
        container.addSubview(skipBtn)
    }

    // MARK: – Live state

    private func refresh() {
        let hasPermission = PermissionsManager.hasScreenRecordingPermission

        if hasPermission {
            permissionRow?.update(
                done: true,
                subtitle: "Granted — captures, recordings, and OCR are ready.",
                primary: nil,
                secondary: nil
            )
        } else if Settings.didRequestScreenRecordingPermission {
            permissionRow?.update(
                done: false,
                subtitle: "Enable Shotnix in System Settings, then relaunch so macOS applies it.",
                primary: ("Open Settings", { PermissionsManager.openScreenRecordingSettings() }),
                secondary: ("Quit & Reopen", { PermissionsManager.quitAndReopen() })
            )
        } else {
            permissionRow?.update(
                done: false,
                subtitle: "Needed to capture the screen. macOS will ask once.",
                primary: ("Allow Screen Recording", { [weak self] in self?.allowPermissionClicked() }),
                secondary: nil
            )
        }

        if NativeShortcutManager.nativeShortcutsEnabled {
            shortcutsRow?.update(
                done: false,
                subtitle: "Apple's screenshot shortcuts still own ⌘⇧3/4/5 — captures can double-trigger.",
                primary: ("Disable Apple Shortcuts", { [weak self] in self?.disableShortcutsClicked() }),
                secondary: nil
            )
        } else {
            shortcutsRow?.update(
                done: true,
                subtitle: "Apple's shortcuts are out of the way.",
                primary: nil,
                secondary: nil
            )
        }

        if Settings.onboardingCompleted {
            captureRow?.update(
                done: true,
                subtitle: "Nice shot. You're all set.",
                primary: nil,
                secondary: nil
            )
        } else {
            captureRow?.update(
                done: false,
                subtitle: hasPermission
                    ? Self.captureHint(captureAreaShortcut: ShotnixShortcut.captureArea.displayShortcut)
                    : "Grant Screen Recording first, then try it here.",
                primary: ("Take a Test Screenshot", { [weak self] in self?.testCaptureHandler?() }),
                secondary: nil,
                primaryEnabled: hasPermission
            )
        }
    }

    // MARK: – Hints (the user's real bindings, never hardcoded keys)

    /// "⇧⌘4 area · ⇧⌘5 window · ⇧⌘3 fullscreen — Shotnix lives in your menu bar",
    /// leaving out anything the user unassigned.
    static func shortcutsHint(shortcut: @MainActor (ShotnixShortcut) -> String? = { $0.displayShortcut }) -> String {
        let parts = [(ShotnixShortcut.captureArea, "area"), (.captureWindow, "window"), (.captureFullscreenNative, "fullscreen")]
            .compactMap { item, label in shortcut(item).map { "\($0) \(label)" } }
        let home = "Shotnix lives in your menu bar"
        return parts.isEmpty ? home : "\(parts.joined(separator: " · ")) — \(home)"
    }

    static func captureHint(captureAreaShortcut: String?) -> String {
        if let captureAreaShortcut {
            return "Press \(captureAreaShortcut) anytime — or try it right now."
        }
        return "Try it right now — Capture Area is also in the menu bar."
    }

    private func allowPermissionClicked() {
        let alreadyRequested = Settings.didRequestScreenRecordingPermission
        let granted = PermissionsManager.requestScreenRecordingPermission()
        if !granted && alreadyRequested {
            PermissionsManager.openScreenRecordingSettings()
        }
        refresh()
    }

    private func disableShortcutsClicked() {
        if NativeShortcutManager.disableNativeShortcuts() {
            ToastWindow.show(message: "Apple screenshot shortcuts disabled.")
        } else {
            NativeShortcutManager.openKeyboardSettings()
        }
        refresh()
    }

    private func firstCaptureCompleted() {
        refresh()
        // Let the completed state land visually, then get out of the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.closeWindow()
        }
    }

    @objc private func skipClicked() {
        Settings.onboardingCompleted = true
        closeWindow()
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
            self.captureObserver = nil
        }
        window = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: – Checklist row

/// One step in the setup checklist: status icon, title, live subtitle, and up
/// to two action buttons whose handlers are swapped on every refresh.
@MainActor
private final class ChecklistStepRow: NSView {

    private let statusIcon = NSImageView()
    private let titleField: NSTextField
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private var primaryHandler: (() -> Void)?
    private var secondaryHandler: (() -> Void)?

    init(frame: NSRect, step: String, title: String) {
        titleField = NSTextField(labelWithString: title)
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor

        statusIcon.frame = NSRect(x: 14, y: frame.height - 34, width: 20, height: 20)
        statusIcon.contentTintColor = .tertiaryLabelColor
        addSubview(statusIcon)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.frame = NSRect(x: 44, y: frame.height - 32, width: frame.width - 60, height: 17)
        addSubview(titleField)

        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.frame = NSRect(x: 44, y: frame.height - 62, width: frame.width - 220, height: 28)
        addSubview(subtitleField)

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.font = .systemFont(ofSize: 11, weight: .medium)
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        addSubview(primaryButton)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .small
        secondaryButton.font = .systemFont(ofSize: 11, weight: .medium)
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryTapped)
        addSubview(secondaryButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        done: Bool,
        subtitle: String,
        primary: (title: String, handler: () -> Void)?,
        secondary: (title: String, handler: () -> Void)?,
        primaryEnabled: Bool = true
    ) {
        let symbol = done ? "checkmark.circle.fill" : "circle"
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: done ? "Done" : "Pending")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        statusIcon.contentTintColor = done ? .systemGreen : .tertiaryLabelColor
        if subtitleField.stringValue != subtitle {
            subtitleField.stringValue = subtitle
        }

        if let primary {
            primaryHandler = primary.handler
            primaryButton.isHidden = false
            primaryButton.isEnabled = primaryEnabled
            if primaryButton.title != primary.title {
                primaryButton.title = primary.title
            }
        } else {
            primaryHandler = nil
            primaryButton.isHidden = true
        }

        if let secondary {
            secondaryHandler = secondary.handler
            secondaryButton.isHidden = false
            if secondaryButton.title != secondary.title {
                secondaryButton.title = secondary.title
            }
        } else {
            secondaryHandler = nil
            secondaryButton.isHidden = true
        }

        layoutButtons()
    }

    private func layoutButtons() {
        var x = frame.width - 14
        for button in [primaryButton, secondaryButton] where !button.isHidden {
            button.sizeToFit()
            let size = NSSize(width: button.frame.width + 8, height: 24)
            x -= size.width
            button.frame = NSRect(x: x, y: frame.height - 60, width: size.width, height: size.height)
            x -= 8
        }
    }

    @objc private func primaryTapped() { primaryHandler?() }
    @objc private func secondaryTapped() { secondaryHandler?() }
}
