import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI
import ServiceManagement

enum PreferencesTab: Int, CaseIterable {
    case general = 0
    case shortcuts = 1
    case screenshots = 2
    case recording = 3
    case about = 4
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

        let recordingVC = NSHostingController(rootView: RecordingSettingsView())
        recordingVC.title = "Recording"
        let recordingItem = NSTabViewItem(viewController: recordingVC)
        recordingItem.label = "Recording"
        recordingItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        tabViewController.addTabViewItem(recordingItem)
        
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
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: - SwiftUI Views

struct GeneralSettingsView: View {
    @AppStorage("playSounds") var playSounds = true
    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("hideDesktopIconsWhileCapturing") var hideDesktopIcons = false
    @AppStorage("afterCaptureShowOverlay") var showOverlay = true
    @AppStorage("afterCaptureSaveAutomatically") var saveAutomatically = false
    @AppStorage("overlayOnLeft") var overlayOnLeft = true
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
    private var screenshotShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .screenshots }
    }

    private var toolShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .tools }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ShortcutSection(title: "Screenshots", shortcuts: screenshotShortcuts)

                    Text("Hotkeys are system-wide and active while Shotnix is running. The ⌘⇧3 default works best after Apple's screenshot shortcut is disabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ShortcutSection(title: "Advanced Tools", shortcuts: toolShortcuts)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Reset Defaults") {
                    HotkeyManager.resetDefaults()
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 520, height: 500, alignment: .topLeading)
    }
}

private struct ShortcutSection: View {
    let title: String
    let shortcuts: [ShotnixShortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRecorderRow(shortcut: shortcut)

                    if shortcut.id != shortcuts.last?.id {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
            )
        }
    }
}

private struct ShortcutRecorderRow: View {
    let shortcut: ShotnixShortcut

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            KeyboardShortcuts.Recorder("", name: shortcut.name)
                .frame(width: 134)
        }
        .frame(height: 40)
        .padding(.horizontal, 14)
    }
}
struct ScreenshotsSettingsView: View {
    @AppStorage("screenshotFormat") var screenshotFormat = "png"
    @AppStorage("jpegQuality") var jpegQuality: Double = 0.95
    @AppStorage("afterCaptureCopyToClipboard") var copyToClipboard = true
    @AppStorage("autoSaveLocation") var autoSaveLocation = ""

    var displayLocation: String {
        Settings.autoSaveLocation
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
                Toggle("Copy screenshots to clipboard", isOn: $copyToClipboard)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("New screenshots are copied automatically. Turn this off if you only want to use the overlay or history actions.")
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
                            if Settings.setAutoSaveLocation(url.path) {
                                autoSaveLocation = Settings.autoSaveLocation
                            } else {
                                ToastWindow.show(message: "Choose a writable folder for auto-save.")
                            }
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
        .frame(width: 500, height: 430)
    }
}

private struct MicrophoneOption: Identifiable {
    let id: String
    let name: String
}

private enum MicrophoneDeviceProvider {
    static var options: [MicrophoneOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        .map { MicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
    }
}

struct RecordingSettingsView: View {
    @AppStorage("recordingFPS") var fps = 30
    @AppStorage("recordingQuality") var quality = "high"
    @AppStorage("recordingShowsCursor") var showsCursor = true
    @AppStorage("recordingSystemAudio") var systemAudio = false
    @AppStorage("recordingMicrophone") var microphone = false
    @AppStorage("recordingMicrophoneDeviceID") var microphoneDeviceID = ""

    private var microphones: [MicrophoneOption] { MicrophoneDeviceProvider.options }

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $quality) {
                    Text("Balanced").tag("balanced")
                    Text("High").tag("high")
                    Text("Max").tag("max")
                }

                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }

                Toggle("Show cursor", isOn: $showsCursor)
            } header: {
                Text("Video")
            } footer: {
                Text("High is the default. Max keeps more detail for demos, but creates larger files.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Record system audio", isOn: $systemAudio)
                Toggle("Record microphone", isOn: $microphone)

                Picker("Microphone", selection: $microphoneDeviceID) {
                    Text("System Default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(!microphone)
            } header: {
                Text("Audio")
            } footer: {
                Text("Microphone recording requires macOS microphone permission. System audio excludes Shotnix sounds to avoid feedback.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 430)
    }
}

struct AboutSettingsView: View {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.15.4"
    
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
                    Version 0.15.4
                    • Quick Access thumbnails now show the full screenshot with a premium blurred backdrop
                    • DisplayLink still screenshots now retry through a stream capture path when the still image path returns black
                    • Shortcut preferences now scroll cleanly and keep Reset Defaults reachable

                    Version 0.15.3
                    • Screenshot captures now play a bundled Shotnix capture sound reliably
                    • The capture sound is packaged with the app bundle for signed releases

                    Version 0.15.2
                    • Quick Access thumbnail drag-and-drop now exports reliably to Finder and other apps
                    • Copy and Save buttons keep responding while thumbnail drag remains available from non-button areas

                    Version 0.15.1
                    • Annotation editor windows now open larger by default to reduce immediate scrolling
                    • Editor sizing stays capped to the visible screen for smaller or accessibility-scaled displays
                    • Crop confirmation now stays fully visible in the toolbar

                    Version 0.15.0
                    • First-run onboarding now guides Screen Recording and Apple screenshot shortcut setup
                    • Shotnix can disable conflicting macOS screenshot shortcuts and confirms when setup is ready
                    • The quick-access thumbnail now defaults to the left side on fresh installs

                    Version 0.14.1
                    • Overlay Save now writes to the configured Save Location immediately
                    • Save uses the same quick confirmation experience as Copy
                    • Record Window now captures the selected window more sharply

                    Version 0.14.0
                    • New screenshots copy to the clipboard by default
                    • Added a Screenshots preference to disable automatic clipboard copying

                    Version 0.13.0-beta
                    • Redesigned Capture History with premium dark-glass styling
                    • More compact four-column capture cards with smoother preview framing
                    • Refined history panel spacing, hover states, and card borders

                    Version 0.12.0-beta
                    • Custom image backdrops and generated image presets for presentation-ready exports
                    • Refined annotation editor chrome, toolbar spacing, and background popovers
                    • Numbered markers and color swatches render cleanly in the editor

                    Version 0.11.0-beta
                    • Per-image Backdrop controls for presentation-ready screenshot exports
                    • Annotation editor now previews styled backgrounds exactly as saved
                    • Save panels, editor restore, and local signing are more reliable

                    Version 0.10.2-beta
                    • Record Window now shows premium preview cards with app icons and target details
                    • Desktop/backstop windows are filtered out of the picker
                    • Select controls no longer crowd the right scrollbar edge

                    Version 0.10.1
                    • Back-to-back recordings and screenshots no longer get stuck after stopping recording
                    • Screen recordings preserve Retina scale for sharper MP4 output

                    Version 0.10.0-beta
                    • Record an area, selected window, or fullscreen display
                    • Configure system audio, microphone, cursor, quality, and FPS before recording
                    • Live recording HUD with timer, stop control, audio state, and mic level feedback
                    • Record Window now uses a selectable window picker instead of a blocking overlay

                    Version 0.9.9-beta
                    • QR code scanning from a selected screen area
                    • Smart QR results for links, email, phone, SMS, Wi-Fi, and plain text

                    Version 0.9.8-beta
                    • About now includes Website, GitHub, and Report Issue links
                    • First-launch welcome copy now better reflects the full capture workflow

                    Version 0.9.7-beta
                    • Closing a Shotnix window no longer drops the app from Cmd-Tab when other windows remain open
                    • Annotation editor toolbar no longer overlaps the traffic light buttons
                    • Arrow annotations render cleanly — shaft now stops at the arrowhead instead of overlapping it

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
                
                HStack(spacing: 12) {
                    Button("Website") {
                        openURL("https://shotnix.com/")
                    }
                    .buttonStyle(.link)

                    Button("Privacy Policy") {
                        openURL("https://shotnix.com/privacy")
                    }
                    .buttonStyle(.link)

                    Button("Support") {
                        openURL("https://shotnix.com/support")
                    }
                    .buttonStyle(.link)

                    Button("Check for Updates") {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
                    }
                    .buttonStyle(.link)

                    Button("GitHub") {
                        openURL("https://github.com/OMARVII/Shotnix")
                    }
                    .buttonStyle(.link)

                    Button("Report Issue") {
                        openURL("https://github.com/OMARVII/Shotnix/issues/new")
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(30)
        .frame(width: 500, height: 500)
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
