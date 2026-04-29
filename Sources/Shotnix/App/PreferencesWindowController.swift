import AppKit
import SwiftUI
import ServiceManagement

enum PreferencesTab: Int, CaseIterable {
    case general = 0
    case shortcuts = 1
    case screenshots = 2
    case about = 3
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    
    static let shared = PreferencesWindowController()
    
    private init() {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        
        let generalVC = NSHostingController(rootView: GeneralSettingsView())
        generalVC.title = "General"
        let generalItem = NSTabViewItem(viewController: generalVC)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        tabViewController.addTabViewItem(generalItem)
        
        let shortcutsVC = NSHostingController(rootView: ShortcutsSettingsView())
        shortcutsVC.title = "Shortcuts"
        let shortcutsItem = NSTabViewItem(viewController: shortcutsVC)
        shortcutsItem.label = "Shortcuts"
        shortcutsItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        tabViewController.addTabViewItem(shortcutsItem)
        
        let screenshotsVC = NSHostingController(rootView: ScreenshotsSettingsView())
        screenshotsVC.title = "Screenshots"
        let screenshotsItem = NSTabViewItem(viewController: screenshotsVC)
        screenshotsItem.label = "Screenshots"
        screenshotsItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        tabViewController.addTabViewItem(screenshotsItem)
        
        let aboutVC = NSHostingController(rootView: AboutSettingsView())
        aboutVC.title = "About"
        let aboutItem = NSTabViewItem(viewController: aboutVC)
        aboutItem.label = "About"
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        tabViewController.addTabViewItem(aboutItem)
        
        let window = NSWindow(contentViewController: tabViewController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        window.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func show(tab: PreferencesTab = .general) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        
        if let tabVC = window?.contentViewController as? NSTabViewController {
            tabVC.selectedTabViewItemIndex = tab.rawValue
        }
        
        window?.makeKeyAndOrderFront(nil)
    }
    
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }
}

// MARK: - SwiftUI Views

struct GeneralSettingsView: View {
    @AppStorage("playSounds") var playSounds = true
    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("hideDesktopIconsWhileCapturing") var hideDesktopIcons = false
    @AppStorage("afterCaptureShowOverlay") var showOverlay = true
    @AppStorage("afterCaptureCopyToClipboard") var copyToClipboard = false
    @AppStorage("afterCaptureSaveAutomatically") var saveAutomatically = false
    @AppStorage("overlayOnLeft") var overlayOnLeft = false
    @AppStorage("overlayTimeout") var overlayTimeout: Double = 6.0
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch Shotnix at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin.toggle()
                        }
                    }
            } header: {
                Text("Startup")
            }
            
            Section {
                Toggle("Play capture sound", isOn: $playSounds)
            } header: {
                Text("Sounds")
            }
            
            Section {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
            } header: {
                Text("Menu Bar")
            }
            
            Section {
                Toggle("Show Quick Access Overlay", isOn: $showOverlay)
                Toggle("Copy file to clipboard", isOn: $copyToClipboard)
                Toggle("Save automatically", isOn: $saveAutomatically)
                
                Picker("Overlay position", selection: $overlayOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                
                Picker("Auto-dismiss overlay", selection: $overlayTimeout) {
                    Text("3 seconds").tag(3.0)
                    Text("6 seconds").tag(6.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("Never").tag(-1.0)
                }
            } header: {
                Text("After Capture")
            } footer: {
                Text("Choose what happens immediately after taking a screenshot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 500)
    }
}
struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Capture Area", key: "⌘⇧4")
                ShortcutRow(title: "Capture Window", key: "⌘⇧5")
                ShortcutRow(title: "Capture Fullscreen", key: "⌘⇧3 / ⌘⇧6")
                ShortcutRow(title: "Capture Previous Area", key: "⌘⇧7")
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Hotkeys are system-wide and always active while the app is running.")
            }
            
            Section {
                ShortcutRow(title: "OCR / Capture Text", key: "⌘⇧O")
                ShortcutRow(title: "Scrolling Capture", key: "⌘⇧S")
            } header: {
                Text("Advanced Tools")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 350)
    }
}

struct ShortcutRow: View {
    let title: String
    let key: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.unemphasizedSelectedContentBackgroundColor))
                .cornerRadius(6)
        }
    }
}
struct ScreenshotsSettingsView: View {
    @AppStorage("screenshotFormat") var screenshotFormat = "png"
    @AppStorage("jpegQuality") var jpegQuality: Double = 0.95
    @AppStorage("autoSaveLocation") var autoSaveLocation = ""

    var displayLocation: String {
        if autoSaveLocation.isEmpty {
            return ("~/Desktop" as NSString).expandingTildeInPath
        }
        return autoSaveLocation
    }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $screenshotFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                    Text("WebP").tag("webp")
                }
                
                if screenshotFormat == "jpeg" {
                    HStack {
                        Text("JPEG Quality")
                        Spacer()
                        Slider(value: $jpegQuality, in: 0.1...1.0)
                            .frame(width: 150)
                        Text("\(Int(jpegQuality * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 45, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Export Format")
            }
            
            Section {
                HStack {
                    Text(displayLocation)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: displayLocation)
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            autoSaveLocation = url.path
                        }
                    }
                }
            } header: {
                Text("Save Location")
            } footer: {
                Text("Directory where screenshots are saved if Auto-Save is enabled.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 350)
    }
}
struct AboutSettingsView: View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.6-beta"
    
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSImage(named: "NSApplicationIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            VStack(spacing: 4) {
                Text("Shotnix")
                    .font(.system(size: 22, weight: .bold))
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What's New")
                    .font(.headline)
                
                ScrollView {
                    Text("""
                    Version 0.9.6-beta
                    • ⌘⇧3 fullscreen capture alias
                    • Fixed annotation move undo correctness
                    • Hide desktop icons while capturing now works during capture flows
                    • Safer WebP fallback and release signing cleanup
                    • Performance polish for annotation, overlay, history, and scrolling capture

                    Version 0.9.5-beta
                    • Premium branding, app icon, menu bar icon, and first-launch welcome screen
                    • Adaptive colors and haptic feedback
                    • Premium DMG installer branding

                    Version 0.9.2-beta
                    • WebP export support (macOS 14+)
                    • First-launch onboarding with permission guide
                    • After-capture auto-actions (auto-copy, auto-save)
                    • Fixed multi-display capture coordinates
                    • Screenshot colors now match display calibration exactly

                    Version 0.9.1-beta
                    • Pixel-perfect screenshot quality (fixed CoreGraphics resampling blur)
                    • Correct DPI metadata for Retina captures
                    • Timestamped filenames — "Shotnix 2026-04-12 at 10.30.48"
                    • Auto-disable conflicting macOS screenshot shortcuts on first launch
                    • Fixed windows not coming to front (preferences, history, annotation)
                    • Crash guards for empty screen arrays and async cleanup races

                    Version 0.9.0-beta
                    • Area, window, and fullscreen capture
                    • Scrolling capture for long content
                    • OCR text recognition (⌘⇧O)
                    • Full annotation editor
                    • Quick access overlay with drag-and-drop
                    • Pin screenshots to desktop
                    • Capture history with grid browser
                    • Global hotkeys (⌘⇧3/4/5/6/7)
                    • Launch at login support
                    • Full settings window
                    """)
                    .font(.system(size: 12))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(Color(NSColor.gridColor))
                .frame(height: 160)
            }
            
            VStack(spacing: 4) {
                Text("© 2026 Shotnix Contributors")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("MIT License — Free and open source")
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/OMARVII/Shotnix") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(30)
        .frame(width: 500, height: 500)
    }
}
