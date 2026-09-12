import AppKit

/// Full-opacity countdown pill shown before a timed capture fires.
/// Escape or clicking the pill cancels. Shotnix's own windows are excluded
/// from SCK captures, and the pill is ordered out before the shot regardless,
/// so it never appears in the screenshot.
@MainActor
final class CountdownWindow: NSWindow {

    private let completion: (Bool) -> Void
    private var remaining: Int
    private var timer: Timer?
    private var keyMonitor: Any?
    private var didFinish = false

    private let numberField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "Click or press Esc to cancel")

    /// - Parameter completion: called exactly once — `true` when the countdown
    ///   ran to zero, `false` when the user cancelled.
    init(seconds: Int, on screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.remaining = max(1, seconds)
        self.completion = completion

        let size = NSSize(width: 148, height: 148)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false

        buildContent(size: size)
    }

    override var canBecomeKey: Bool { true }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        updateNumber()
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finish(captured: false)
                return nil
            }
            return event
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildContent(size: NSSize) {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.92).cgColor
        root.layer?.cornerRadius = size.width / 2
        root.layer?.borderWidth = 1.5
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        contentView = root

        numberField.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        numberField.textColor = .white
        numberField.alignment = .center
        numberField.frame = NSRect(x: 0, y: size.height / 2 - 34, width: size.width, height: 72)
        root.addSubview(numberField)

        hintField.font = .systemFont(ofSize: 9.5, weight: .semibold)
        hintField.textColor = NSColor.white.withAlphaComponent(0.55)
        hintField.alignment = .center
        hintField.frame = NSRect(x: 0, y: 26, width: size.width, height: 13)
        root.addSubview(hintField)
    }

    private func updateNumber() {
        numberField.stringValue = "\(remaining)"
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(captured: true)
        } else {
            updateNumber()
            if Settings.playSounds {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        finish(captured: false)
    }

    private func finish(captured: Bool) {
        guard !didFinish else { return }
        didFinish = true
        timer?.invalidate()
        timer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        // A short beat so the window is gone from the compositor before the
        // fallback (CGWindowList) capture path could pick it up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [completion] in
            completion(captured)
        }
    }
}
