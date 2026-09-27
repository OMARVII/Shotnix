import AppKit

/// Restarts Shotnix: to switch languages (Settings → General), or so macOS
/// applies a new permission. It quits the normal way, so unsaved screenshot edits and running work ask first and can
/// cancel it. Only once quitting is certain (applicationWillTerminate) does a
/// new Shotnix start, and that one waits for this one to exit before it sets
/// anything up: two never run side by side (hotkeys, the menu bar icon,
/// History's files).
@MainActor
enum AppRelaunch {
    /// Tells the new Shotnix which process to wait for.
    static let previousInstanceArgument = "--relaunched-from"
    /// Tells the new Shotnix to open Settings → General again.
    static let reopenSettingsArgument = "--reopen-settings"

    /// Set while a restart's quit is under way.
    private(set) static var isRestarting = false
    private static var reopensSettingsAfterRestart = false

    /// Quits Shotnix, then starts it again. A cancelled quit changes nothing.
    static func restart(reopeningSettings: Bool = false) {
        // A run loop callout, not the caller's main-queue block: while such a
        // block runs, the main queue waits, and the quit waits on main-queue
        // work (an editor's save prompt answers there, running work too).
        RunLoop.main.perform {
            MainActor.assumeIsolated { quitThenRelaunch(reopeningSettings: reopeningSettings) }
        }
    }

    /// `terminate` returns only when the quit was cancelled, as
    /// `NSApplication.terminate(_:)` does.
    static func quitThenRelaunch(reopeningSettings: Bool = false, terminate: @MainActor () -> Void = { NSApp.terminate(nil) }) {
        isRestarting = true
        reopensSettingsAfterRestart = reopeningSettings
        terminate()
        // Still running: the quit was cancelled. A later quit stays a quit.
        isRestarting = false
        reopensSettingsAfterRestart = false
    }

    /// For applicationWillTerminate: starts the new Shotnix when quitting is
    /// part of a restart.
    static func launchNewInstanceIfRestarting(open: (NSWorkspace.OpenConfiguration) -> Void = launchNewInstance) {
        guard isRestarting else { return }
        open(newInstanceConfiguration(reopeningSettings: reopensSettingsAfterRestart))
    }

    /// A second Shotnix although this one still runs (LaunchServices would
    /// otherwise just bring this one forward), told to wait for this one.
    static func newInstanceConfiguration(replacing processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier, reopeningSettings: Bool = false) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [previousInstanceArgument, String(processIdentifier)] + (reopeningSettings ? [reopenSettingsArgument] : [])
        return configuration
    }

    nonisolated static func launchNewInstance(_ configuration: NSWorkspace.OpenConfiguration) {
        // The process exits as soon as this returns: hold on until
        // LaunchServices has started the new one (a moment; the completion
        // handler runs on a background queue), or give up after a while.
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                print("[Shotnix] Couldn't start Shotnix again: \(error.localizedDescription)")
            }
            launched.signal()
        }
        _ = launched.wait(timeout: .now() + 5)
    }

    // MARK: The new Shotnix

    /// The Shotnix this one replaces, when it was started by a restart.
    static func previousInstance(in arguments: [String] = CommandLine.arguments) -> pid_t? {
        guard let index = arguments.firstIndex(of: previousInstanceArgument),
              arguments.indices.contains(index + 1),
              let process = pid_t(arguments[index + 1]), process > 0 else { return nil }
        return process
    }

    /// Whether this Shotnix was restarted to switch languages, so Settings
    /// comes back where it was.
    static func reopensSettings(in arguments: [String] = CommandLine.arguments) -> Bool {
        previousInstance(in: arguments) != nil && arguments.contains(reopenSettingsArgument)
    }

    /// Returns once the Shotnix this one replaces has exited, or after
    /// `timeout`; right away on an ordinary launch.
    static func waitForPreviousInstance(in arguments: [String] = CommandLine.arguments, timeout: TimeInterval = 10) {
        guard let previous = previousInstance(in: arguments) else { return }
        let deadline = Date(timeIntervalSinceNow: timeout)
        // Signal 0 sends nothing: it only asks whether the process still exists.
        while kill(previous, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
