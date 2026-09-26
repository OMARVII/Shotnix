import AppKit

/// Countdown shown before a timed capture fires: a dark circle with a
/// depleting accent ring, a big centered number that ticks with a soft pop,
/// and a cancel hint below the circle. Escape or clicking cancels. Shotnix's
/// own windows are excluded from SCK captures, and the window is ordered out
/// before the shot regardless, so it never appears in the screenshot.
@MainActor
final class CountdownWindow: NSWindow {

    private let completion: (Bool) -> Void
    private let totalSeconds: Int
    private var remaining: Int
    private var timer: Timer?
    private var keyMonitor: Any?
    private var didFinish = false

    private let circleSize: CGFloat = 150
    private var circleView = NSView()
    private let numberField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "Click or press Esc to cancel")
    private let progressRing = CAShapeLayer()

    /// - Parameter completion: called exactly once — `true` when the countdown
    ///   ran to zero, `false` when the user cancelled.
    init(seconds: Int, on screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.totalSeconds = max(1, seconds)
        self.remaining = max(1, seconds)
        self.completion = completion

        let size = NSSize(width: 220, height: 196)
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
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)
        updateNumber(animated: false)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)

        // Entrance: fade the window while the circle springs up to size.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        if let layer = circleView.layer {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.86
            spring.toValue = 1.0
            spring.stiffness = 320
            spring.damping = 20
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "entrance")
        }

        // One smooth ring depletion across the whole countdown.
        let deplete = CABasicAnimation(keyPath: "strokeEnd")
        deplete.fromValue = 1.0
        deplete.toValue = 0.0
        deplete.duration = Double(totalSeconds)
        deplete.timingFunction = CAMediaTimingFunction(name: .linear)
        deplete.fillMode = .forwards
        deplete.isRemovedOnCompletion = false
        progressRing.add(deplete, forKey: "deplete")

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
        root.layer?.masksToBounds = false
        contentView = root

        // The circle sits at the top; the hint lives BELOW it so text never
        // fights the circle's curvature.
        let circleFrame = NSRect(
            x: (size.width - circleSize) / 2,
            y: size.height - circleSize - 4,
            width: circleSize,
            height: circleSize
        )
        circleView = NSView(frame: circleFrame)
        circleView.wantsLayer = true
        guard let circleLayer = circleView.layer else { return }
        circleLayer.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.94).cgColor
        circleLayer.cornerRadius = circleSize / 2
        circleLayer.borderWidth = 1
        circleLayer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        circleLayer.shadowColor = NSColor.black.cgColor
        circleLayer.shadowOpacity = 0.45
        circleLayer.shadowRadius = 16
        circleLayer.shadowOffset = CGSize(width: 0, height: -4)
        root.addSubview(circleView)

        // Ring track + depleting accent ring, starting at 12 o'clock.
        let ringInset: CGFloat = 5
        let ringRect = circleView.bounds.insetBy(dx: ringInset, dy: ringInset)
        let ringPath = CGMutablePath()
        ringPath.addArc(
            center: CGPoint(x: circleSize / 2, y: circleSize / 2),
            radius: ringRect.width / 2,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi,
            clockwise: true
        )

        let track = CAShapeLayer()
        track.path = ringPath
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        track.lineWidth = 4
        circleLayer.addSublayer(track)

        progressRing.path = ringPath
        progressRing.fillColor = nil
        progressRing.strokeColor = NSColor.controlAccentColor.cgColor
        progressRing.lineWidth = 4
        progressRing.lineCap = .round
        circleLayer.addSublayer(progressRing)

        numberField.font = .monospacedDigitSystemFont(ofSize: 62, weight: .bold)
        numberField.textColor = .white
        numberField.alignment = .center
        numberField.wantsLayer = true
        circleView.addSubview(numberField)

        // Dark capsule behind the hint so it reads on any wallpaper — bare
        // text below the circle disappears over light content.
        hintField.font = .systemFont(ofSize: 11, weight: .semibold)
        hintField.textColor = NSColor.white.withAlphaComponent(0.78)
        hintField.alignment = .center
        hintField.sizeToFit()
        let hintPadding = NSSize(width: 22, height: 10)
        let hintCapsule = NSView(frame: NSRect(
            x: (size.width - hintField.frame.width - hintPadding.width) / 2,
            y: 6,
            width: hintField.frame.width + hintPadding.width,
            height: hintField.frame.height + hintPadding.height
        ))
        hintCapsule.wantsLayer = true
        hintCapsule.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.88).cgColor
        hintCapsule.layer?.cornerRadius = hintCapsule.frame.height / 2
        hintCapsule.layer?.borderWidth = 1
        hintCapsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hintField.setFrameOrigin(NSPoint(x: hintPadding.width / 2, y: hintPadding.height / 2))
        hintCapsule.addSubview(hintField)
        root.addSubview(hintCapsule)
    }

    /// Sizes the label to its content and centers it optically in the circle
    /// (digits carry no descender, so pure frame-centering sits visibly low).
    private func updateNumber(animated: Bool) {
        numberField.stringValue = "\(remaining)"
        numberField.sizeToFit()
        let bounds = circleView.bounds
        numberField.setFrameOrigin(NSPoint(
            x: bounds.midX - numberField.frame.width / 2,
            y: bounds.midY - numberField.frame.height / 2 + 2
        ))

        guard animated, let layer = numberField.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.18
        pop.toValue = 1.0
        pop.stiffness = 380
        pop.damping = 22
        pop.duration = pop.settlingDuration
        // Scale around the glyph center, not the layer origin.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: numberField.frame.midX, y: numberField.frame.midY)
        layer.add(pop, forKey: "tick")
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(captured: true)
        } else {
            updateNumber(animated: true)
            if Settings.playSounds {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        finish(captured: false)
    }

    /// Same as Esc: stops the countdown and reports it cancelled.
    func cancel() {
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
