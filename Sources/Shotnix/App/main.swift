import AppKit

// MainActor.assumeIsolated is valid at the top-level entry point —
// the OS always launches the main thread first.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
