import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var captureEngine: CaptureEngine!
    var hotkeyManager: HotkeyManager!
    var historyManager: HistoryManager!
    private let welcomeController = WelcomeWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureEngine = CaptureEngine()
        hotkeyManager = HotkeyManager()
        historyManager = HistoryManager()
        setupStatusItem()
        welcomeController.showIfNeeded()
        PermissionsManager.requestScreenRecordingPermission()
        hotkeyManager.register(captureEngine: captureEngine, historyManager: historyManager)
        NativeShortcutManager.promptIfNeeded()
    }

    // MARK: – Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotnix")
        button.image?.isTemplate = true
        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let about = NSMenuItem(title: "About Shotnix", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        menu.addItem(header: "Capture")
        menu.addItem(title: "Capture Area",         key: "4", action: #selector(captureArea))
        menu.addItem(title: "Capture Window",       key: "5", action: #selector(captureWindow))
        menu.addItem(title: "Capture Fullscreen",   key: "6", action: #selector(captureFullscreen))
        menu.addItem(title: "Capture Previous Area",key: "",  action: #selector(capturePrevious))
        menu.addItem(title: "Scrolling Capture",    key: "",  action: #selector(captureScrolling))
        menu.addItem(.separator())

        menu.addItem(header: "Tools")
        menu.addItem(title: "Capture Text (OCR)",   key: "",  action: #selector(captureText))
        menu.addItem(title: "Open History",         key: "",  action: #selector(openHistory))
        menu.addItem(title: "Annotate Last Screenshot", key: "", action: #selector(annotateLastScreenshot))
        menu.addItem(.separator())

        let hideIconsItem = NSMenuItem(title: "Hide Desktop Icons", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        hideIconsItem.target = self
        menu.addItem(hideIconsItem)
        menu.addItem(.separator())

        menu.addItem(title: "Preferences…",         key: ",", action: #selector(openPreferences))

        let quit = NSMenuItem(title: "Quit Shotnix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    // MARK: – Actions

    @objc func captureArea()         { Task { await captureEngine.startAreaCapture(historyManager: historyManager) } }
    @objc func captureWindow()       { Task { await captureEngine.startWindowCapture(historyManager: historyManager) } }
    @objc func captureFullscreen()   { Task { await captureEngine.captureFullscreen(historyManager: historyManager) } }
    @objc func capturePrevious()     { Task { await captureEngine.capturePreviousArea(historyManager: historyManager) } }
    @objc func captureScrolling()    { Task { await captureEngine.startScrollingCapture(historyManager: historyManager) } }
    @objc func captureText()         { Task { await captureEngine.startOCRCapture() } }
    @objc func annotateLastScreenshot() {
        guard let last = historyManager.items.first else { return }
        AnnotationWindowController.open(image: last.fullImage, historyItem: last, historyManager: historyManager)
    }
    @objc func openHistory()         { HistoryPanelController.shared.show(historyManager: historyManager) }
    @objc func toggleDesktopIcons()  { DesktopIconsManager.toggle() }
    @objc func openPreferences()     { PreferencesWindowController.shared.show(tab: .general) }
    @objc func openAbout()           { PreferencesWindowController.shared.show(tab: .about) }
}

// MARK: – NSMenu convenience

private extension NSMenu {
    func addItem(header text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        addItem(item)
    }

    func addItem(title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = NSApp.delegate
        addItem(item)
    }
}
