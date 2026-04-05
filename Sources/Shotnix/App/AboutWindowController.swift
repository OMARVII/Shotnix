import AppKit

@MainActor
final class AboutWindowController: NSObject {

    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Shotnix"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = buildContent()
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func buildContent() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 130, y: 220, width: 100, height: 100))
        if let icon = NSImage(named: "NSApplicationIcon") {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "Shotnix")
        nameLabel.font = .boldSystemFont(ofSize: 22)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 20, y: 180, width: 320, height: 30)
        view.addSubview(nameLabel)

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 20, y: 158, width: 320, height: 18)
        view.addSubview(versionLabel)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: 40, y: 148, width: 280, height: 1)
        view.addSubview(sep)

        // Description
        let desc = NSTextField(wrappingLabelWithString: "A fast, focused screenshot utility for macOS.\nCapture, annotate, pin, and extract text — all from your menu bar.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .labelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 30, y: 98, width: 300, height: 46)
        view.addSubview(desc)

        // Website
        let linkBtn = NSButton(title: "GitHub", target: self, action: #selector(openWebsite))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.font = .systemFont(ofSize: 12)
        linkBtn.contentTintColor = .linkColor
        linkBtn.frame = NSRect(x: 130, y: 72, width: 100, height: 20)
        view.addSubview(linkBtn)

        // Copyright
        let copyright = NSTextField(labelWithString: "\u{00A9} 2025 Shotnix Contributors")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center
        copyright.frame = NSRect(x: 20, y: 46, width: 320, height: 18)
        view.addSubview(copyright)

        // Rights notice
        let rights = NSTextField(labelWithString: "MIT License \u{2014} Free and open source.")
        rights.font = .systemFont(ofSize: 10)
        rights.textColor = .tertiaryLabelColor
        rights.alignment = .center
        rights.frame = NSRect(x: 20, y: 24, width: 320, height: 16)
        view.addSubview(rights)

        return view
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://github.com/OMARVII/Shotnix")!)
    }
}
