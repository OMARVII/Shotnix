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

    private weak var content: NSView?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var descriptionLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var skipButton: NSButton?
    /// The height everything is laid out in: 470 pt as designed, more when a
    /// translation needs taller rows.
    private var contentHeight = WelcomeWindowController.size.height

    @discardableResult
    func showIfNeeded(onClose: (() -> Void)? = nil) -> Bool {
        guard !Settings.onboardingCompleted else { return false }
        guard window == nil else { return true }
        Settings.hasLaunchedBefore = true
        self.onClose = onClose
        showWindow()
        return true
    }

    /// What the checklist shows. `live` reads the Mac's current state.
    struct SetupState {
        var hasPermission: Bool
        var requestedPermission: Bool
        var nativeShortcutsEnabled: Bool
        var onboardingCompleted: Bool
        var captureAreaShortcut: String?

        @MainActor static var live: SetupState {
            SetupState(
                hasPermission: PermissionsManager.hasScreenRecordingPermission,
                requestedPermission: Settings.didRequestScreenRecordingPermission,
                nativeShortcutsEnabled: NativeShortcutManager.nativeShortcutsEnabled,
                onboardingCompleted: Settings.onboardingCompleted,
                captureAreaShortcut: ShotnixShortcut.captureArea.displayShortcut
            )
        }
    }

    private static let size = NSSize(width: 490, height: 470)

    private func showWindow() {
        let content = makeContent(state: .live)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: contentHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = content
        win.center()

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

    /// The window's content showing `state` (tests render it offscreen).
    func makeContent(state: SetupState) -> NSView {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        content = background
        buildContent(in: background)
        show(state)
        return background
    }

    private func buildContent(in container: NSView) {
        let iconView = NSImageView()
        iconView.image = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)
        self.iconView = iconView

        let title = NSTextField(labelWithString: L("Welcome to Shotnix"))
        title.font = .boldSystemFont(ofSize: 21)
        title.alignment = .center
        container.addSubview(title)
        titleLabel = title

        let desc = NSTextField(labelWithString: L("Three quick steps and you're capturing."))
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        container.addSubview(desc)
        descriptionLabel = desc

        let rowFrame = NSRect(x: 24, y: 0, width: Self.size.width - 48, height: ChecklistStepRow.designHeight)
        let permission = ChecklistStepRow(frame: rowFrame, step: "1", title: L("Allow Screen Recording"))
        container.addSubview(permission)
        permissionRow = permission

        let shortcuts = ChecklistStepRow(frame: rowFrame, step: "2", title: L("Free up ⌘⇧ shortcuts · optional"))
        container.addSubview(shortcuts)
        shortcutsRow = shortcuts

        let capture = ChecklistStepRow(frame: rowFrame, step: "3", title: L("Take your first screenshot"))
        container.addSubview(capture)
        captureRow = capture

        let hint = NSTextField(labelWithString: Self.shortcutsHint())
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        container.addSubview(hint)
        hintLabel = hint

        let skipBtn = NSButton(title: L("Skip Setup"), target: self, action: #selector(skipClicked))
        skipBtn.bezelStyle = .rounded
        skipBtn.controlSize = .regular
        container.addSubview(skipBtn)
        skipButton = skipBtn
    }

    /// Stacks the checklist from the top: header, the three rows (78 pt each
    /// as designed, taller when a translation needs it), then the shortcut
    /// hint and Skip Setup at the bottom. The window grows downward to fit.
    private func layoutContent() {
        guard let content, let permissionRow, let shortcutsRow, let captureRow,
              let iconView, let titleLabel, let descriptionLabel, let hintLabel, let skipButton else { return }
        let width = Self.size.width
        let rows = [permissionRow, shortcutsRow, captureRow]

        // The hint takes a second line only when a translation needs it.
        let hintWidth = width - 40
        let hintWraps = ceil(hintLabel.intrinsicContentSize.width) > hintWidth
        if hintWraps {
            hintLabel.cell?.wraps = true
            hintLabel.lineBreakMode = .byWordWrapping
            hintLabel.maximumNumberOfLines = 2
        }
        let hintHeight: CGFloat = hintWraps ? 28 : 14

        let rowsHeight = rows.reduce(0) { $0 + $1.frame.height } + 8 * CGFloat(rows.count - 1)
        let height = 148 + rowsHeight + 58 + hintHeight
        if height != contentHeight {
            contentHeight = height
            if let window, window.contentView === content {
                // Keep the top edge where it is.
                let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height), display: true)
            }
        }
        if window?.contentView !== content {
            content.setFrameSize(NSSize(width: width, height: height))
        }

        var y = height - 30
        iconView.frame = NSRect(x: width / 2 - 26, y: y - 52, width: 52, height: 52)
        y -= 58
        titleLabel.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
        y -= 28
        descriptionLabel.frame = NSRect(x: 44, y: y - 18, width: width - 88, height: 16)
        y -= 32
        for row in rows {
            row.setFrameOrigin(NSPoint(x: 24, y: y - row.frame.height))
            y -= row.frame.height + 8
        }
        hintLabel.frame = NSRect(x: 20, y: 52, width: hintWidth, height: hintHeight)

        skipButton.sizeToFit()
        let skipWidth = max(120, skipButton.frame.width + 24)
        skipButton.frame = NSRect(x: (width - skipWidth) / 2, y: 14, width: skipWidth, height: 30)
    }

    // MARK: – Live state

    private func refresh() {
        show(.live)
    }

    private func show(_ state: SetupState) {
        let hasPermission = state.hasPermission

        if hasPermission {
            permissionRow?.update(
                done: true,
                subtitle: L("Granted — captures, recordings, and OCR are ready."),
                primary: nil,
                secondary: nil
            )
        } else if state.requestedPermission {
            permissionRow?.update(
                done: false,
                subtitle: L("Enable Shotnix in System Settings, then relaunch so macOS applies it."),
                primary: (L("Open Settings"), { PermissionsManager.openScreenRecordingSettings() }),
                secondary: (L("Quit & Reopen"), { PermissionsManager.quitAndReopen() })
            )
        } else {
            permissionRow?.update(
                done: false,
                subtitle: L("Needed to capture the screen. macOS will ask once."),
                primary: (L("Allow Screen Recording"), { [weak self] in self?.allowPermissionClicked() }),
                secondary: nil
            )
        }

        if state.nativeShortcutsEnabled {
            shortcutsRow?.update(
                done: false,
                subtitle: L("Apple's screenshot shortcuts still own ⌘⇧3/4/5 — captures can double-trigger."),
                primary: (L("Disable Apple Shortcuts"), { [weak self] in self?.disableShortcutsClicked() }),
                secondary: nil
            )
        } else {
            shortcutsRow?.update(
                done: true,
                subtitle: L("Apple's shortcuts are out of the way."),
                primary: nil,
                secondary: nil
            )
        }

        if state.onboardingCompleted {
            captureRow?.update(
                done: true,
                subtitle: L("Nice shot. You're all set."),
                primary: nil,
                secondary: nil
            )
        } else {
            captureRow?.update(
                done: false,
                subtitle: hasPermission
                    ? Self.captureHint(captureAreaShortcut: state.captureAreaShortcut)
                    : L("Grant Screen Recording first, then try it here."),
                primary: (L("Take a Test Screenshot"), { [weak self] in self?.testCaptureHandler?() }),
                secondary: nil,
                primaryEnabled: hasPermission
            )
        }
        layoutContent()
    }

    // MARK: – Hints (the user's real bindings, never hardcoded keys)

    /// "⇧⌘4 area · ⇧⌘5 window · ⇧⌘3 fullscreen — Shotnix lives in your menu bar",
    /// leaving out anything the user unassigned. Each shortcut gets its own
    /// label, and the list goes into one sentence.
    static func shortcutsHint(shortcut: @MainActor (ShotnixShortcut) -> String? = { $0.displayShortcut }) -> String {
        let parts = [
            shortcut(.captureArea).map { L("\($0) area") },
            shortcut(.captureWindow).map { L("\($0) window") },
            shortcut(.captureFullscreenNative).map { L("\($0) fullscreen") },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return L("Shotnix lives in your menu bar") }
        return L("\(parts.joined(separator: " · ")) — Shotnix lives in your menu bar")
    }

    static func captureHint(captureAreaShortcut: String?) -> String {
        if let captureAreaShortcut {
            return L("Press \(captureAreaShortcut) anytime — or try it right now.")
        }
        return L("Try it right now — Capture Area is also in the menu bar.")
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
            ToastWindow.show(message: L("Apple screenshot shortcuts disabled."))
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

    /// The row's height as designed; a long translation can make it taller.
    static let designHeight: CGFloat = 78

    init(frame: NSRect, step: String, title: String) {
        titleField = NSTextField(labelWithString: title)
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor

        statusIcon.contentTintColor = .tertiaryLabelColor
        addSubview(statusIcon)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleField)

        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
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
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: done ? L("Done") : L("Pending"))?
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

        layoutContent()
    }

    /// The buttons sit beside the subtitle, as designed, while the subtitle
    /// fits there in up to three lines (English always does). A longer
    /// translation gets the row's full width, with the buttons on a line of
    /// their own below it, and the row grows to fit.
    private func layoutContent() {
        let textX: CGFloat = 44
        let trailing = frame.width - 14
        let buttons = [primaryButton, secondaryButton].filter { !$0.isHidden }
        let buttonWidths = buttons.map { button -> CGFloat in
            button.sizeToFit()
            return button.frame.width + 8
        }
        let buttonsWidth = buttonWidths.reduce(0, +) + 8 * CGFloat(max(0, buttons.count - 1))

        // As designed: 222 pt, ending at least 4 pt before the buttons.
        let besideWidth = min(frame.width - 220, trailing - buttonsWidth - 4 - textX)
        let stacked = subtitleLines(width: besideWidth) > 3
        let subtitleWidth = stacked ? trailing - textX : besideWidth
        // Room for three lines beside the buttons (the text starts at the
        // top, so shorter subtitles look as designed), or all of it below.
        let subtitleHeight = stacked
            ? max(28, ceil(subtitleSize(width: subtitleWidth).height) + 2)
            : 44

        let height = stacked
            ? max(Self.designHeight, 34 + subtitleHeight + (buttons.isEmpty ? 0 : 8 + 24) + 12)
            : Self.designHeight
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
        }

        statusIcon.frame = NSRect(x: 14, y: height - 34, width: 20, height: 20)
        titleField.frame = NSRect(x: textX, y: height - 32, width: frame.width - 60, height: 17)
        // The subtitle's first line stays where the design puts it.
        subtitleField.frame = NSRect(x: textX, y: height - 34 - subtitleHeight, width: subtitleWidth, height: subtitleHeight)

        var x = trailing
        for (button, width) in zip(buttons, buttonWidths) {
            x -= width
            button.frame = NSRect(x: x, y: stacked ? 12 : height - 60, width: width, height: 24)
            x -= 8
        }
    }

    private var subtitleLineHeight: CGFloat {
        guard let font = subtitleField.font else { return 14 }
        return font.ascender - font.descender + font.leading
    }

    /// The subtitle's size wrapped to `width`, erring toward more lines: it's
    /// laid out a few points narrower than the field.
    private func subtitleSize(width: CGFloat) -> NSSize {
        guard width > 8, let cell = subtitleField.cell else { return .zero }
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 6, height: 10_000))
    }

    private func subtitleLines(width: CGFloat) -> Int {
        max(1, Int((subtitleSize(width: width).height / subtitleLineHeight).rounded()))
    }

    @objc private func primaryTapped() { primaryHandler?() }
    @objc private func secondaryTapped() { secondaryHandler?() }
}
