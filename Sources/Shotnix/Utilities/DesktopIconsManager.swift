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
        let val = value ? "1" : "0"
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["write", "com.apple.finder", "CreateDesktop", val]
        try? task.run(); task.waitUntilExit()

        // Restart Finder to apply
        let restart = Process()
        restart.launchPath = "/usr/bin/killall"
        restart.arguments = ["Finder"]
        try? restart.run()
    }
}
