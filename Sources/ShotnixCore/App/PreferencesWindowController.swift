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

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .screenshots: return "Screenshots"
        case .recording: return "Recording"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .screenshots: return "camera"
        case .recording: return "record.circle"
        case .about: return "info.circle"
        }
    }
}

@MainActor
private final class PreferencesSelectionModel: ObservableObject {
    @Published var selectedTab: PreferencesTab = .general
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    
    static let shared = PreferencesWindowController()

    private let selection = PreferencesSelectionModel()
    
    private init() {
        let hostingController = NSHostingController(rootView: PreferencesRootView(selection: selection))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Shotnix Preferences"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ShotnixColors.editorStageTop
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 560, height: 620))
        window.minSize = NSSize(width: 520, height: 520)
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

        selection.selectedTab = tab
        window?.makeKeyAndOrderFront(nil)
    }
    
    func windowWillClose(_ notification: Notification) {
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: - SwiftUI Views

private struct PreferencesRootView: View {
    @ObservedObject var selection: PreferencesSelectionModel

    var body: some View {
        ZStack {
            ShotnixHUDBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                PreferencesTabStrip(selectedTab: $selection.selectedTab)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                Group {
                    switch selection.selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .shortcuts:
                        ShortcutsSettingsView()
                    case .screenshots:
                        ScreenshotsSettingsView()
                    case .recording:
                        RecordingSettingsView()
                    case .about:
                        AboutSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 620)
        .preferredColorScheme(.dark)
    }
}

private struct PreferencesTabStrip: View {
    @Binding var selectedTab: PreferencesTab

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    PreferencesTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
            }
            .frame(width: min(402, max(320, proxy.size.width - 118)))
            .position(x: proxy.size.width / 2, y: 46)
        }
        .frame(height: 86)
        .background(Color.black.opacity(0.12))
    }
}

private struct PreferencesTabButton: View {
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 20)

                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.62))
            .frame(width: 74, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

private struct PreferencesPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(maxWidth: 560, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct PreferencesPaneWithFooter<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            PreferencesPane {
                content
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18))
        }
    }
}

private struct PreferenceSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.86))

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreferenceRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            trailing
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: detail == nil ? 44 : 50, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct PreferenceDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 12)
    }
}

private struct PreferenceFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

private struct PreferenceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

private struct PreferenceMenuSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PreferenceOption<Value>]
    var width: CGFloat = 156
    var isEnabled = true

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? options.first?.title ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 6)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isEnabled ? 0.44 : 0.22))
            }
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.86 : 0.34))
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isEnabled ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isEnabled ? 0.10 : 0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct PreferenceSegmentedSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PreferenceOption<Value>]
    var width: CGFloat = 156

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(option.value == selection ? Color.white : Color.white.opacity(0.58))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option.value == selection ? Color.accentColor.opacity(0.95) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width, height: 28)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

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
        PreferencesPane {
            PreferenceSection("Startup") {
                PreferenceRow("Launch Shotnix at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin.toggle()
                            }
                        }
                }
            }

            PreferenceSection("Sounds") {
                PreferenceRow("Play capture sound") {
                    Toggle("", isOn: $playSounds)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceSection("Menu Bar") {
                PreferenceRow("Show menu bar icon") {
                    Toggle("", isOn: $showMenuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showMenuBarIcon) { newValue in
                            guard !newValue else { return }
                            DispatchQueue.main.async {
                                confirmHideMenuBarIcon()
                            }
                        }
                }

                PreferenceDivider()

                PreferenceRow("Hide desktop icons while capturing") {
                    Toggle("", isOn: $hideDesktopIcons)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceSection("After Capture") {
                PreferenceRow("Show Quick Access Overlay") {
                    Toggle("", isOn: $showOverlay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow("Save automatically") {
                    Toggle("", isOn: $saveAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow("Overlay position") {
                    PreferenceSegmentedSelector(
                        selection: $overlayOnLeft,
                        options: [
                            PreferenceOption(value: true, title: "Left"),
                            PreferenceOption(value: false, title: "Right")
                        ]
                    )
                }

                PreferenceDivider()

                PreferenceRow("Auto-dismiss overlay") {
                    PreferenceMenuSelector(
                        selection: $overlayTimeout,
                        options: [
                            PreferenceOption(value: 3.0, title: "3 seconds"),
                            PreferenceOption(value: 6.0, title: "6 seconds"),
                            PreferenceOption(value: 10.0, title: "10 seconds"),
                            PreferenceOption(value: 30.0, title: "30 seconds"),
                            PreferenceOption(value: -1.0, title: "Never")
                        ]
                    )
                }
            }

            PreferenceFootnote(text: "Choose what happens immediately after taking a screenshot.")
        }
    }

    /// The status item is the app's only entry point — confirm before hiding it
    /// and explain how to get back (relaunching Shotnix reopens Preferences).
    private func confirmHideMenuBarIcon() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hide the Menu Bar Icon?"
        alert.informativeText = "The menu bar icon is Shotnix's main entry point. While it is hidden, open Shotnix again from Finder, Launchpad, or Spotlight to bring these Preferences back."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() != .alertFirstButtonReturn {
            showMenuBarIcon = true
        }
    }
}
struct ShortcutsSettingsView: View {
    private var screenshotShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .screenshots }
    }

    private var toolShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .tools }
    }

    private var recordingShortcuts: [ShotnixShortcut] {
        ShotnixShortcut.allCases.filter { $0.section == .recording }
    }

    var body: some View {
        PreferencesPaneWithFooter {
            ShortcutSection(title: "Screenshots", shortcuts: screenshotShortcuts)

            PreferenceFootnote(text: "Hotkeys are system-wide and active while Shotnix is running. The ⌘⇧3 default works best after Apple's screenshot shortcut is disabled.")

            ShortcutSection(title: "Recording", shortcuts: recordingShortcuts)

            PreferenceFootnote(text: "Recording shortcuts are unassigned by default — click a field to set one. Stop Recording also cancels recording setup.")

            ShortcutSection(title: "Advanced Tools", shortcuts: toolShortcuts)
        } footer: {
            HStack {
                Button("Reset Defaults") {
                    HotkeyManager.resetDefaults()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Restore Apple Shortcuts") {
                    if NativeShortcutManager.restoreNativeShortcuts() {
                        ToastWindow.show(message: "Apple screenshot shortcuts restored.")
                    } else {
                        ToastWindow.show(message: "Could not restore Apple shortcuts.")
                        NativeShortcutManager.openKeyboardSettings()
                    }
                }
                .buttonStyle(.bordered)
                .help("Re-enable Apple's ⌘⇧3/4/5 screenshot shortcuts")
            }
        }
    }
}

private struct ShortcutSection: View {
    let title: String
    let shortcuts: [ShotnixShortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.86))

            VStack(spacing: 0) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRecorderRow(shortcut: shortcut)

                    if shortcut.id != shortcuts.last?.id {
                        Divider()
                            .padding(.leading, 14)
                            .overlay(Color.white.opacity(0.08))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutRecorderRow: View {
    let shortcut: ShotnixShortcut

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            KeyboardShortcuts.Recorder("", name: shortcut.name)
                .frame(width: 134)
        }
        .frame(height: 42)
        .padding(.horizontal, 14)
    }
}
struct ScreenshotsSettingsView: View {
    @AppStorage("screenshotFormat") var screenshotFormat = "png"
    @AppStorage("jpegQuality") var jpegQuality: Double = 0.95
    @AppStorage("afterCaptureCopyToClipboard") var copyToClipboard = true
    @AppStorage("autoSaveLocation") var autoSaveLocation = ""
    @AppStorage("filenameTemplate") var filenameTemplate = Settings.defaultFilenameTemplate

    var displayLocation: String {
        Settings.autoSaveLocation
    }

    private var filenamePreview: String {
        let trimmed = filenameTemplate.trimmingCharacters(in: .whitespaces)
        let template = trimmed.isEmpty ? Settings.defaultFilenameTemplate : filenameTemplate
        return "\(ImageExporter.renderFilenameTemplate(template)).\(screenshotFormat)"
    }

    var body: some View {
        PreferencesPane {
            PreferenceSection("Export Format") {
                PreferenceRow("Format") {
                    PreferenceMenuSelector(
                        selection: $screenshotFormat,
                        options: [
                            PreferenceOption(value: "png", title: "PNG"),
                            PreferenceOption(value: "jpeg", title: "JPEG"),
                            PreferenceOption(value: "webp", title: "WebP")
                        ]
                    )
                }

                if screenshotFormat == "jpeg" {
                    PreferenceDivider()

                    PreferenceRow("JPEG Quality") {
                        HStack(spacing: 8) {
                            Slider(value: $jpegQuality, in: 0.1...1.0)
                                .frame(width: 140)

                            Text("\(Int(jpegQuality * 100))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.56))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }

            PreferenceSection("Clipboard") {
                PreferenceRow("Copy screenshots to clipboard") {
                    Toggle("", isOn: $copyToClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceFootnote(text: "New screenshots are copied automatically. Turn this off if you only want to use the overlay or history actions.")

            PreferenceSection("Save Location") {
                PreferenceRow("Auto-save folder", detail: displayLocation) {
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
                    .buttonStyle(.bordered)
                }
            }

            PreferenceFootnote(text: "Directory where screenshots are saved if Auto-Save is enabled.")

            PreferenceSection("File Name") {
                PreferenceRow("Template") {
                    TextField("", text: $filenameTemplate, prompt: Text(Settings.defaultFilenameTemplate))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .frame(width: 230, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }

                PreferenceDivider()

                PreferenceRow("Preview") {
                    Text(filenamePreview)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            PreferenceFootnote(text: "Used for screenshots and recordings. Tokens: %y year, %m month, %d day, %H hour, %M minute, %S second. Leave empty to restore the default.")
        }
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
    @AppStorage("openVideoEditorAfterRecording") var openVideoEditorAfterRecording = true

    private var microphones: [MicrophoneOption] { MicrophoneDeviceProvider.options }

    var body: some View {
        PreferencesPane {
            PreferenceSection("Video") {
                PreferenceRow("Quality") {
                    PreferenceMenuSelector(
                        selection: $quality,
                        options: [
                            PreferenceOption(value: "balanced", title: "Balanced"),
                            PreferenceOption(value: "high", title: "High"),
                            PreferenceOption(value: "max", title: "Max")
                        ]
                    )
                }

                PreferenceDivider()

                PreferenceRow("Frame rate") {
                    PreferenceSegmentedSelector(
                        selection: $fps,
                        options: [
                            PreferenceOption(value: 30, title: "30 fps"),
                            PreferenceOption(value: 60, title: "60 fps")
                        ]
                    )
                }

                PreferenceDivider()

                PreferenceRow("Show cursor") {
                    Toggle("", isOn: $showsCursor)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow("Open editor after recording") {
                    Toggle("", isOn: $openVideoEditorAfterRecording)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceFootnote(text: "High is the default. Max keeps more detail for demos, but creates larger files.")

            PreferenceSection("Audio") {
                PreferenceRow("Record system audio") {
                    Toggle("", isOn: $systemAudio)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow("Record microphone") {
                    Toggle("", isOn: $microphone)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceDivider()

                PreferenceRow("Microphone") {
                    PreferenceMenuSelector(
                        selection: $microphoneDeviceID,
                        options: [PreferenceOption(value: "", title: "System Default")]
                            + microphones.map { PreferenceOption(value: $0.id, title: $0.name) },
                        width: 190,
                        isEnabled: microphone
                    )
                }
            }

            PreferenceFootnote(text: "Microphone recording requires macOS microphone permission. System audio excludes Shotnix sounds to avoid feedback.")
        }
    }
}

struct AboutSettingsView: View {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.18.0"
    
    var body: some View {
        PreferencesPane {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: "NSApplicationIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shotnix")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.94))
                    Text("Version \(version)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.48))
                }

                Spacer(minLength: 12)

                Button("Check for Updates") {
                    (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What's New")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.86))
                
                ScrollView {
                    Text("""
                    Version 0.18.0
                    • Recording hotkeys — assign shortcuts to start and stop recording, and Escape stops a recording in progress
                    • Multi-display polish — fullscreen capture asks which display (or all), and overlays, toasts, and pins appear on the screen you captured
                    • Custom file names — template with date/time tokens and live preview in Screenshots settings
                    • Copy Text from the post-capture overlay, and click the save toast to reveal the file in Finder
                    • Annotation editor — canvas zoom, Shift/Option drawing constraints, arrow-key nudging, and it remembers your tool, color, and line width
                    • Reliability — interrupted recordings are saved instead of lost, failed text extraction no longer clears your clipboard, and barcode scanning goes beyond QR

                    Version 0.17.4
                    • Cursor polish: adjustable cursor size, click spotlight, and motion-blur trail on fast moves
                    • Editors now stay reachable — open a photo or video editor and Shotnix gets a Dock icon and ⌘-Tab entry so you can always switch back

                    Version 0.17.3
                    • Premium effects: text labels, arrows, highlights, blur boxes, and exported callout layers
                    • Auto zoom presets, effect lane markers, smoother cursor interpolation, and social export polish

                    Version 0.17.2
                    • Per-segment speed controls: 0.5x, 1x, 1.5x, and 2x
                    • Clip mute plus fade-in/fade-out controls while preserving recorded audio tracks

                    Version 0.17.1
                    • Proper clip timeline with split at playhead, delete, ripple delete, undo/redo, and selected clip trim
                    • Export now stitches multi-segment compositions with cuts, speed, audio, cursor, and zoom mapping

                    Version 0.17.0
                    • Video Demo Editor foundation with preview stage, frame presets, backgrounds, trim, and MP4 export
                    • Video timeline now supports split, delete, ripple, selected clip trim, and stitched MP4 export
                    • Timeline UI now uses a ruler, video/audio track, zoom lane, trim handles, and full-height playhead
                    • Recordings can open directly into the video editor
                    • Command Center can open a video file or reopen the last recording

                    Version 0.16.0
                    • New Command Center replaces the plain menu bar dropdown
                    • Health status now surfaces permissions, shortcuts, updates, save folder, and version
                    • Quick Access, History, and pinned screenshot menus now share the premium HUD style

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
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .frame(height: 220)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 8) {
                Text("© 2026 Shotnix Contributors")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.42))
                Text("MIT License — Free and open source")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.36))

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        AboutLinkButton(title: "Website") {
                            openURL("https://shotnix.com/")
                        }

                        AboutLinkButton(title: "Support") {
                            openURL("https://shotnix.com/support")
                        }

                        AboutLinkButton(title: "GitHub") {
                            openURL("https://github.com/OMARVII/Shotnix")
                        }
                    }

                    HStack(spacing: 8) {
                        AboutLinkButton(title: "Privacy Policy") {
                            openURL("https://shotnix.com/privacy")
                        }

                        AboutLinkButton(title: "Report Issue") {
                            openURL("https://github.com/OMARVII/Shotnix/issues/new")
                        }
                    }
                }
                .frame(maxWidth: 378)
                .padding(.top, 4)
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AboutLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.82))
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(title)
    }
}
