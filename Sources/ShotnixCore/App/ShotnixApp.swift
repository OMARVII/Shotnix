import AppKit

public enum ShotnixApp {
    public static func run() {
        // MainActor.assumeIsolated is valid at the top-level entry point:
        // macOS launches the application on the main thread.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
