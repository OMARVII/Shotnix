import AppKit

/// Work that has to finish before Shotnix quits or relaunches for an update —
/// a recording being written, an export, a transcription. Each piece of work
/// registers while it runs: quitting waits for it (asking first when the work
/// says so), and an update holds its relaunch until everything has ended.
@MainActor
enum AppTermination {
    /// Keep it for as long as the work runs; pass it to `end` when done.
    final class Token {
        fileprivate let id = UUID()
        fileprivate init() {}
    }

    private struct Work {
        let description: String
        let asksBeforeQuit: Bool
        let finish: (@escaping @MainActor () -> Void) -> Void
    }

    private static var work: [UUID: Work] = [:]
    private static var waiters: [@MainActor () -> Void] = []

    static var isBusy: Bool { !work.isEmpty }

    /// Human-readable lines for the quit prompt ("Exporting “Demo.mp4”").
    static var descriptions: [String] { work.values.map(\.description).sorted() }

    /// Whether quitting should ask first (an export or transcription would be
    /// lost) rather than finish silently (a recording just stops and saves).
    static var asksBeforeQuit: Bool { work.values.contains { $0.asksBeforeQuit } }

    /// Registers running work. `finish` is called when the app wants to quit:
    /// wrap up (stop and save, or cancel) and call its `done` argument.
    static func begin(_ description: String, asksBeforeQuit: Bool = false, finish: @escaping (_ done: @escaping @MainActor () -> Void) -> Void) -> Token {
        let token = Token()
        work[token.id] = Work(description: description, asksBeforeQuit: asksBeforeQuit, finish: finish)
        return token
    }

    static func end(_ token: Token?) {
        guard let token else { return }
        remove(token.id)
    }

    /// Asks every piece of work to finish, then calls `completion` once all have ended.
    static func finishAll(completion: @escaping @MainActor () -> Void) {
        guard isBusy else { return completion() }
        waiters.append(completion)
        for (id, item) in work {
            item.finish { remove(id) }
        }
    }

    /// Calls `completion` once nothing is running, without asking anything to stop.
    static func whenIdle(_ completion: @escaping @MainActor () -> Void) {
        guard isBusy else { return completion() }
        waiters.append(completion)
    }

    private static func remove(_ id: UUID) {
        guard work.removeValue(forKey: id) != nil, work.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0() }
    }

    /// For `applicationShouldTerminate`: quit now, or finish the running work first.
    static func terminateReply(for app: NSApplication) -> NSApplication.TerminateReply {
        guard confirmQuit() else { return .terminateCancel }
        return finishThenQuit(app)
    }

    /// Asks first when quitting would cut work short; true to go ahead.
    static func confirmQuit() -> Bool {
        guard isBusy, asksBeforeQuit else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Shotnix?"
        alert.informativeText = (descriptions + ["Shotnix will wrap these up before it quits."]).joined(separator: "\n")
        alert.addButton(withTitle: "Finish and Quit")
        alert.addButton(withTitle: "Keep Working")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quits now, or once the running work has wrapped up.
    static func finishThenQuit(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard isBusy else { return .terminateNow }
        finishAll { app.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
