import AppKit
import ScreenCaptureKit
import os.log

/// One request that every caller waits on instead of each making its own,
/// and its answer kept until `invalidate()`.
@MainActor
final class SharedFetch<Value> {
    enum Source: Equatable {
        /// The kept answer.
        case cache
        /// Waited for a request already under way.
        case joined
        /// Made the request.
        case fetched
    }

    private let fetch: @MainActor () async throws -> Value
    private(set) var cached: Value?
    private var inFlight: Task<Value, Error>?
    private var generation = 0

    init(_ fetch: @escaping @MainActor () async throws -> Value) {
        self.fetch = fetch
    }

    /// The kept answer, the request under way, or a new one. `fresh` always
    /// makes a new request (for something that changed since the kept one
    /// was made), and callers after it wait on that one.
    func value(fresh: Bool = false) async throws -> (value: Value, source: Source) {
        if !fresh {
            if let cached { return (cached, .cache) }
            if let inFlight { return (try await inFlight.value, .joined) }
        }
        let generation = self.generation
        let fetch = self.fetch
        // Kept inside the task, so whoever resumes first finds it in place.
        let task = Task { @MainActor in
            let value = try await fetch()
            if generation == self.generation { self.cached = value }
            return value
        }
        inFlight = task
        defer {
            if inFlight == task { inFlight = nil }
        }
        return (try await task.value, .fetched)
    }

    /// Forgets the kept answer. A request already under way still answers
    /// whoever waits on it, but its answer isn't kept, and new callers
    /// make a new one.
    func invalidate() {
        generation &+= 1
        cached = nil
        inFlight = nil
    }
}

/// ScreenCaptureKit's lists of displays, apps and windows, for screenshots
/// and recordings.
///
/// Always the windows on screen, unless a caller needs the hidden ones too.
/// ScreenCaptureKit answers its calls one at a time, screenshots included,
/// and a list of every window walks every window the Mac has, at a cost
/// that grows faster than the count: a Mac up for weeks can hold thousands
/// of hidden windows (one had ~9,700, nearly all leaked by a system
/// service), and there each such list took ~3.5–5 s, with the first shot
/// after a display change waiting behind several. The on-screen list takes
/// a few dozen milliseconds whatever the count.
@MainActor
enum ShareableContentStore {
    private static let onScreen = SharedFetch<SCShareableContent> {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    /// Shotnix's own entry in ScreenCaptureKit's application list. A filter
    /// that leaves the app out sends only its process ID, so the entry from
    /// any list serves for the life of the process.
    private static var ownApp: SCRunningApplication?
    private static var observerInstalled = false

    /// Forgets the list when the displays change (one plugged in,
    /// unplugged, rearranged or rescaled): the next caller fetches it.
    static func installDisplayChangeObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { invalidate() }
        }
    }

    static func invalidate() {
        onScreen.invalidate()
    }

    /// Displays, apps and on-screen windows: the kept list, the request
    /// under way, or a new one. `fresh` for a window opened since the kept
    /// list was made. `purpose` labels the timing log.
    static func content(fresh: Bool = false, purpose: String) async throws -> SCShareableContent {
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let (content, source) = try await onScreen.value(fresh: fresh)
            remember(content)
            switch source {
            case .cache:
                break
            case .joined:
                CapturePerformance.mark("\(purpose): waited for the window list under way", since: started)
            case .fetched:
                CapturePerformance.mark("\(purpose): window list (\(content.windows.count) windows on screen, \(content.displays.count) displays)", since: started)
            }
            return content
        } catch {
            CapturePerformance.mark("\(purpose): window list failed (\(error.localizedDescription))", since: started)
            throw error
        }
    }

    /// Every window, hidden ones included. Slow on a Mac holding many
    /// windows, so only for what a hidden window changes (a window
    /// recording hides its app's other windows, minimized ones too); never
    /// kept or shared.
    static func everyWindow(purpose: String) async throws -> SCShareableContent {
        let started = CFAbsoluteTimeGetCurrent()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        remember(content)
        CapturePerformance.mark("\(purpose): every window (\(content.windows.count))", since: started)
        return content
    }

    /// Shotnix's own application entry, to leave its overlays, previews and
    /// pins out of captures. An on-screen list names Shotnix only when one
    /// of its windows is on screen, and can miss one shown a moment ago (a
    /// selection overlay), so it comes from the current process's own
    /// list: ~20 ms, whatever else is open.
    static func ownApplication() async -> SCRunningApplication? {
        if let ownApp { return ownApp }
        if #available(macOS 14.4, *) {
            let started = CFAbsoluteTimeGetCurrent()
            if let content = try? await SCShareableContent.currentProcess {
                remember(content)
            }
            CapturePerformance.mark("own app entry: \(ownApp == nil ? "not listed yet" : "found")", since: started)
        }
        return ownApp
    }

    private static func remember(_ content: SCShareableContent) {
        guard ownApp == nil else { return }
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        ownApp = content.applications.first { $0.processID == processID }
    }
}

/// Timing breadcrumbs, at debug level:
///   log stream --level debug --predicate 'subsystem == "com.shotnix.app" AND category == "CapturePerformance"'
/// A step that takes a second or more logs at default level instead, which
/// the unified log keeps, so a slow shot can be read back afterwards.
enum CapturePerformance {
    private static let log = OSLog(subsystem: "com.shotnix.app", category: "CapturePerformance")

    static func mark(_ label: String, since start: CFAbsoluteTime) {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        os_log("%{public}@ took %.1f ms", log: log, type: elapsed >= 1 ? .default : .debug, label, elapsed * 1000)
    }
}
