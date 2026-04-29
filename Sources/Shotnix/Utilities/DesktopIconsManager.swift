import AppKit

/// Temporarily hides/shows desktop icons by toggling Finder's CreateDesktop preference.
enum DesktopIconsManager {

    private static var isHidden = false
    private static let finderAppID = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString

    static var desktopIconsVisible: Bool {
        guard let value = CFPreferencesCopyAppValue(createDesktopKey, finderAppID) else { return true }
        return (value as? Bool) ?? true
    }

    static func toggle() {
        desktopIconsVisible ? hide() : show()
    }

    static func hideForCapture() -> Bool {
        guard desktopIconsVisible else {
            isHidden = true
            return false
        }
        hide()
        return true
    }

    static func showAfterCapture(ifHiddenByCapture hiddenByCapture: Bool) {
        guard hiddenByCapture else { return }
        show()
    }

    static func hide() {
        setCreateDesktop(false)
        isHidden = true
    }

    static func show() {
        setCreateDesktop(true)
        isHidden = false
    }

    private static func setCreateDesktop(_ value: Bool) {
        // Use native CFPreferences instead of 'defaults write' shell script
        CFPreferencesSetValue(createDesktopKey, value as CFPropertyList, finderAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(finderAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        // Gently restart Finder natively
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            // terminate() asks politely, allowing Finder to finish file copies.
            // If it fails to terminate, forceTerminate() kills it instantly.
            if !finder.terminate() {
                finder.forceTerminate()
            }
            
            // Wait slightly and relaunch Finder so the desktop reappears
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                    let config = NSWorkspace.OpenConfiguration()
                    config.promptsUserIfNeeded = false
                    NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
            }
        }
    }
}
