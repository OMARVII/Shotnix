import AppKit
import ScreenCaptureKit

/// The menu's "Hide Desktop Icons" toggle: flips Finder's CreateDesktop
/// preference, which persists until toggled back. Per-capture hiding uses
/// DesktopIconsCover instead — it never touches Finder.
enum DesktopIconsManager {

    private static let finderAppID = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString

    static var desktopIconsVisible: Bool {
        guard let value = CFPreferencesCopyAppValue(createDesktopKey, finderAppID) else { return true }
        return (value as? Bool) ?? true
    }

    static func toggle() {
        desktopIconsVisible ? hide() : show()
    }

    static func hide() {
        setCreateDesktop(false)
    }

    static func show() {
        setCreateDesktop(true)
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

/// "Hide desktop icons while capturing" without restarting Finder: every
/// screen gets a window showing its own desktop picture, just above the icon
/// layer and below everything else. Captures include these windows (see
/// CaptureEngine), so icons, widgets, and stray files vanish from the shot.
/// They belong to Shotnix, so they disappear with it if it ever quits
/// mid-capture — nothing is left hidden.
@MainActor
final class DesktopIconsCover {

    /// One level above the desktop icons — below every app window.
    static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private(set) var windows: [NSWindow] = []

    static func isCoverWindow(_ window: NSWindow) -> Bool {
        window is DesktopCoverWindow
    }

    /// How long a ScreenCaptureKit call may take before the cover falls back
    /// to the desktop picture file. ScreenCaptureKit can wait indefinitely
    /// (while macOS asks about screen recording, for one), and hiding icons
    /// must never hold up the capture itself.
    static var screenCaptureDeadline: TimeInterval = 1

    /// Covers every screen and returns once they're on screen.
    static func show(on screens: [NSScreen] = NSScreen.screens) async -> DesktopIconsCover {
        let cover = DesktopIconsCover()
        var content: SCShareableContent?
        if #available(macOS 14.0, *) {
            // One window-list fetch serves every screen.
            if case .finished(let fetched) = await withDeadline(screenCaptureDeadline, {
                try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }) {
                content = fetched
            }
        }
        for screen in screens {
            var picture: Picture?
            if #available(macOS 14.0, *), let shareable = content {
                switch await withDeadline(screenCaptureDeadline, { await screenCaptureWallpaper(for: screen, content: shareable) }) {
                case .finished(let image?): picture = .captured(image)
                case .finished(nil):        break
                case .timedOut:             content = nil // it would stall on the other screens too
                }
            }
            let window = DesktopCoverWindow(screen: screen, picture: picture ?? wallpaperFallback(for: screen))
            window.orderFrontRegardless()
            cover.windows.append(window)
        }
        // One composited frame, so the very next capture already sees them.
        try? await Task.sleep(nanoseconds: 50_000_000)
        return cover
    }

    func remove() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: Wallpaper

    enum Picture {
        /// The wallpaper exactly as the window server draws it.
        case captured(CGImage)
        /// The desktop picture file, drawn the way "Fill Screen" draws it —
        /// when capturing the wallpaper isn't possible.
        case file(NSImage, fill: NSColor?)
        case color(NSColor)
    }

    /// Without ScreenCaptureKit's picture: the window list on macOS 13, then
    /// the desktop picture file, then its fill color.
    private static func wallpaperFallback(for screen: NSScreen) -> Picture {
        if #unavailable(macOS 14.0), let image = windowListWallpaper(for: screen) {
            return .captured(image)
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen)
        let fill = options?[.fillColor] as? NSColor
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            return .file(image, fill: fill)
        }
        return .color(fill ?? .black)
    }

    /// Only the wallpaper windows (below the icon layer) of this display.
    @available(macOS 14.0, *)
    private static func screenCaptureWallpaper(for screen: NSScreen, content: SCShareableContent) async -> CGImage? {
        do {
            guard let display = ScreenCoordinates.display(for: screen, in: content.displays) else { return nil }
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            let wallpaper = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(display.frame) }
            guard !wallpaper.isEmpty else { return nil }
            let filter = SCContentFilter(display: display, including: wallpaper)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(CGFloat(display.width) * scale))
            config.height = max(2, Int(CGFloat(display.height) * scale))
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("[Shotnix] Wallpaper capture failed: \(error)")
            return nil
        }
    }

    /// macOS 13: composite just the windows below the icon layer.
    private static func windowListWallpaper(for screen: NSScreen) -> CGImage? {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = windowList.compactMap { info -> CGWindowID? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < iconLevel,
                  let number = info[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(number)
        }
        guard !ids.isEmpty else { return nil }
        return CaptureEngine.windowListImage(rect: ScreenCoordinates.cgRect(fromAppKit: screen.frame), windowIDs: ids)
    }
}

private enum DeadlineResult<T> {
    case finished(T)
    case timedOut
}

/// `work`'s result, or `.timedOut` once `seconds` pass. The work isn't
/// cancelled — it finishes on its own and its result is dropped.
@MainActor
private func withDeadline<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> T) async -> DeadlineResult<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineResult<T>, Never>) in
        let once = ResumeOnce(continuation)
        Task { @MainActor in once.resume(.finished(await work())) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            once.resume(.timedOut)
        }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@MainActor
private final class DesktopCoverWindow: NSWindow {

    init(screen: NSScreen, picture: DesktopIconsCover.Picture) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = DesktopIconsCover.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsScale = screen.backingScaleFactor
        switch picture {
        case .captured(let image):
            backgroundColor = .black
            view.layer?.contents = image
            view.layer?.contentsGravity = .resize
        case .file(let image, let fill):
            backgroundColor = fill ?? .black
            view.layer?.backgroundColor = (fill ?? .black).cgColor
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
        case .color(let color):
            backgroundColor = color
            view.layer?.backgroundColor = color.cgColor
        }
        contentView = view
        setFrame(screen.frame, display: false)
        setAccessibilityElement(false)
    }
}
