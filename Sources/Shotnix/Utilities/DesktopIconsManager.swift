import AppKit

/// Temporarily hides/shows desktop icons by toggling Finder's CreateDesktop preference.
enum DesktopIconsManager {

    private static var isHidden = false

    static func toggle() {
        isHidden ? show() : hide()
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
        let appID = "com.apple.finder" as CFString
        CFPreferencesSetValue("CreateDesktop" as CFString, value as CFPropertyList, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

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
