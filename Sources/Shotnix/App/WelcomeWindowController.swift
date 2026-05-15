import AppKit

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    @discardableResult
    func showIfNeeded(onClose: (() -> Void)? = nil) -> Bool {
        guard !Settings.hasLaunchedBefore else { return false }
        self.onClose = onClose
        showWindow()
        return true
    }

    private func showWindow() {
        let width: CGFloat = 460
        let height: CGFloat = 360

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

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func buildContent(in container: NSView, width: CGFloat, height: CGFloat) {
        let centerX = width / 2
        var y = height - 34

        // App icon
        let iconSize: CGFloat = 56
        let iconView = NSImageView(frame: NSRect(x: centerX - iconSize / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)
        y -= iconSize + 8

        // Title
        let title = NSTextField(labelWithString: "Welcome to Shotnix")
        title.font = .boldSystemFont(ofSize: 22)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
        container.addSubview(title)
        y -= 32

        let desc = NSTextField(wrappingLabelWithString: "A fast menu bar workflow for screenshots, recordings, annotation, OCR, QR scanning, pinning, and local history.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 44, y: y - 42, width: width - 88, height: 42)
        container.addSubview(desc)
        y -= 52

        // Permission notice
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: 30, y: y, width: width - 60, height: 1)
        container.addSubview(sep)
        y -= 16

        let lockIcon = NSImageView(frame: NSRect(x: 44, y: y - 18, width: 18, height: 18))
        lockIcon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        lockIcon.contentTintColor = .systemOrange
        container.addSubview(lockIcon)

        let permLabel = NSTextField(wrappingLabelWithString: "Step 1 · Allow Screen Recording so Shotnix can capture screenshots, recordings, OCR selections, and QR scans.")
        permLabel.font = .systemFont(ofSize: 11)
        permLabel.textColor = .secondaryLabelColor
        permLabel.frame = NSRect(x: 70, y: y - 36, width: width - 114, height: 36)
        container.addSubview(permLabel)

        let shortcutIcon = NSImageView(frame: NSRect(x: 44, y: y - 62, width: 18, height: 18))
        shortcutIcon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        shortcutIcon.contentTintColor = .systemBlue
        container.addSubview(shortcutIcon)

        let shortcutLabel = NSTextField(wrappingLabelWithString: "Step 2 · Shotnix will help disable macOS screenshot shortcuts so captures do not double-trigger.")
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.frame = NSRect(x: 70, y: y - 82, width: width - 114, height: 36)
        container.addSubview(shortcutLabel)
        y -= 96

        // Buttons
        let btnWidth: CGFloat = 154
        let btnHeight: CGFloat = 32
        let gap: CGFloat = 12
        let totalBtnWidth = btnWidth * 2 + gap
        let btnX = centerX - totalBtnWidth / 2

        let skipBtn = NSButton(title: "Later", target: self, action: #selector(skipClicked))
        skipBtn.bezelStyle = .rounded
        skipBtn.frame = NSRect(x: btnX, y: 20, width: btnWidth, height: btnHeight)
        container.addSubview(skipBtn)

        let grantBtn = NSButton(title: "Enable Capture", target: self, action: #selector(grantClicked))
        grantBtn.bezelStyle = .rounded
        grantBtn.keyEquivalent = "\r"
        grantBtn.frame = NSRect(x: btnX + btnWidth + gap, y: 20, width: btnWidth, height: btnHeight)
        container.addSubview(grantBtn)
    }

    @objc private func grantClicked() {
        Settings.hasLaunchedBefore = true
        let granted = PermissionsManager.requestScreenRecordingPermission()
        if granted {
            closeWindow()
            return
        }

        if Settings.didRequestScreenRecordingPermission {
            showRestartAfterPermissionAlert()
        } else {
            PermissionsManager.openScreenRecordingSettings()
        }
        closeWindow()
    }

    @objc private func skipClicked() {
        Settings.hasLaunchedBefore = true
        closeWindow()
    }

    private func showRestartAfterPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Finish Permission in System Settings"
        alert.informativeText = "After enabling Shotnix in Screen & System Audio Recording, quit and reopen Shotnix so macOS applies the permission."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.openScreenRecordingSettings()
        }
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}
