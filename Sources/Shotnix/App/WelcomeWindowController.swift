import AppKit

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func showIfNeeded() {
        guard !Settings.hasLaunchedBefore else { return }
        Settings.hasLaunchedBefore = true
        showWindow()
    }

    private func showWindow() {
        let width: CGFloat = 400
        let height: CGFloat = 300

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
        var y = height - 30

        // App icon
        let iconSize: CGFloat = 56
        let iconView = NSImageView(frame: NSRect(x: centerX - iconSize / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)
        y -= iconSize + 8

        // Title
        let title = NSTextField(labelWithString: "Welcome to Shotnix")
        title.font = .boldSystemFont(ofSize: 18)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: y - 24, width: width - 40, height: 24)
        container.addSubview(title)
        y -= 32

        // Description
        let desc = NSTextField(wrappingLabelWithString: "Shotnix is a lightweight screenshot tool that lives in your menu bar. Capture areas, windows, or your full screen with global hotkeys.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 30, y: y - 40, width: width - 60, height: 40)
        container.addSubview(desc)
        y -= 48

        // Permission notice
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: 30, y: y, width: width - 60, height: 1)
        container.addSubview(sep)
        y -= 16

        let lockIcon = NSImageView(frame: NSRect(x: 30, y: y - 16, width: 16, height: 16))
        lockIcon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        lockIcon.contentTintColor = .systemOrange
        container.addSubview(lockIcon)

        let permLabel = NSTextField(wrappingLabelWithString: "Screen Recording permission is required to capture screenshots. You can grant it now or later in System Settings.")
        permLabel.font = .systemFont(ofSize: 11)
        permLabel.textColor = .secondaryLabelColor
        permLabel.frame = NSRect(x: 52, y: y - 34, width: width - 82, height: 34)
        container.addSubview(permLabel)
        y -= 50

        // Buttons
        let btnWidth: CGFloat = 140
        let btnHeight: CGFloat = 28
        let gap: CGFloat = 12
        let totalBtnWidth = btnWidth * 2 + gap
        let btnX = centerX - totalBtnWidth / 2

        let skipBtn = NSButton(title: "Later", target: self, action: #selector(skipClicked))
        skipBtn.bezelStyle = .rounded
        skipBtn.frame = NSRect(x: btnX, y: 16, width: btnWidth, height: btnHeight)
        container.addSubview(skipBtn)

        let grantBtn = NSButton(title: "Grant Permission", target: self, action: #selector(grantClicked))
        grantBtn.bezelStyle = .rounded
        grantBtn.keyEquivalent = "\r"
        grantBtn.frame = NSRect(x: btnX + btnWidth + gap, y: 16, width: btnWidth, height: btnHeight)
        container.addSubview(grantBtn)
    }

    @objc private func grantClicked() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        closeWindow()
    }

    @objc private func skipClicked() {
        closeWindow()
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.prohibited)
    }
}
