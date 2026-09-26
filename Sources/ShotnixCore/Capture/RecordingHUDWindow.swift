import AppKit

/// The floating control strip while recording: timer, what's being
/// recorded, and pause / discard / stop. A non-activating panel, so
/// clicking or dragging it never pulls focus from the recorded app.
@MainActor
final class RecordingHUDWindow: NSPanel {

    enum State: Equatable {
        case recording
        case paused
        case confirmingDiscard
        case saving
    }

    static let size = NSSize(width: 400, height: 44)

    var stopHandler: (() -> Void)?
    var pauseHandler: (() -> Void)?
    var discardHandler: (() -> Void)?
    /// Recorded seconds (pauses excluded); the HUD asks twice a second.
    var elapsedProvider: (() -> TimeInterval)?

    private(set) var state: State = .recording
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let detailLabel = NSTextField(labelWithString: "Recording")
    private let confirmLabel = NSTextField(labelWithString: "Discard this recording?")
    private let dotHalo = NSView()
    private let dot = NSView()
    private let pauseGlyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let cameraIcon = NSImageView()
    private let keysIcon = NSImageView()
    private let warningIcon = NSImageView()
    private let microphoneLevelMeter = RecordingHUDLevelMeter()
    private let microphoneWarning = NSImageView()
    private let pauseButton = RecordingHUDIconButton(symbol: "pause.fill", label: "Pause recording", tint: .white)
    private let discardButton = RecordingHUDIconButton(symbol: "trash", label: "Discard recording", tint: .white)
    private let stopButton = RecordingHUDIconButton(symbol: "stop.fill", label: "Stop recording", tint: .systemRed, size: 15)
    private let confirmDiscardButton = RecordingHUDTextButton(title: "Discard", tint: .systemRed)
    private let keepButton = RecordingHUDTextButton(title: "Keep", tint: .white)
    private var detailText = "Recording"
    private var showsMicrophone = false
    private var showsCamera = false
    private var showsKeystrokes = false
    private var hasWarning = false
    private var microphoneSilent = false
    private var confirmResumeState: State = .recording
    private var warningRevertWorkItem: DispatchWorkItem?
    private var confirmTimeoutWorkItem: DispatchWorkItem?
    private var timer: Timer?
    private var escapeKeyMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var isPositioning = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        sharingType = .none
        setAccessibilityLabel("Recording controls")

        buildContent()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func buildContent() {
        let root = RecordingHUDContentView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 15
        root.layer?.cornerCurve = .continuous
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.018, alpha: 0.995).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.72
        root.layer?.shadowRadius = 30
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        let topGlow = NSView(frame: NSRect(x: 16, y: Self.size.height - 1, width: Self.size.width - 32, height: 1))
        topGlow.wantsLayer = true
        topGlow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.addSubview(topGlow)

        let grip = RecordingHUDLabel(labelWithString: "⋮⋮")
        grip.font = .systemFont(ofSize: 14, weight: .bold)
        grip.textColor = NSColor.white.withAlphaComponent(0.26)
        grip.frame = NSRect(x: 10, y: 13, width: 18, height: 18)
        root.addSubview(grip)

        dotHalo.frame = NSRect(x: 30, y: 15, width: 14, height: 14)
        dotHalo.wantsLayer = true
        dotHalo.layer?.borderWidth = 1
        dotHalo.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.34).cgColor
        dotHalo.layer?.cornerRadius = 7
        root.addSubview(dotHalo)

        dot.frame = NSRect(x: 34, y: 19, width: 6, height: 6)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        root.addSubview(dot)

        pauseGlyph.frame = NSRect(x: 30, y: 15, width: 14, height: 14)
        pauseGlyph.image = symbol("pause.circle.fill", size: 13)
        pauseGlyph.contentTintColor = .systemYellow
        pauseGlyph.isHidden = true
        root.addSubview(pauseGlyph)

        spinner.frame = NSRect(x: 30, y: 15, width: 14, height: 14)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        root.addSubview(spinner)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 50, y: 13, width: 56, height: 18)
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setAccessibilityLabel("Recording time")
        root.addSubview(timeLabel)

        detailLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.46)
        detailLabel.frame = NSRect(x: 106, y: 14, width: 110, height: 14)
        detailLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(detailLabel)

        confirmLabel.font = .systemFont(ofSize: 11, weight: .bold)
        confirmLabel.textColor = .white
        confirmLabel.frame = NSRect(x: 106, y: 14, width: 150, height: 15)
        confirmLabel.isHidden = true
        root.addSubview(confirmLabel)

        for (icon, name, tint, label) in [
            (cameraIcon, "video.fill", NSColor.systemBlue, "Recording the camera"),
            (keysIcon, "command", NSColor.white.withAlphaComponent(0.6), "Recording keyboard shortcuts"),
            (warningIcon, "exclamationmark.triangle.fill", NSColor.systemOrange, "Warning"),
        ] {
            icon.image = symbol(name, size: 10)
            icon.contentTintColor = tint
            icon.toolTip = label
            icon.setAccessibilityLabel(label)
            icon.isHidden = true
            root.addSubview(icon)
        }

        microphoneLevelMeter.frame = NSRect(x: 272, y: 11, width: 25, height: 22)
        microphoneLevelMeter.isHidden = true
        root.addSubview(microphoneLevelMeter)

        microphoneWarning.frame = NSRect(x: 274, y: 14, width: 18, height: 16)
        microphoneWarning.image = symbol("mic.slash.fill", size: 12)
        microphoneWarning.contentTintColor = .systemOrange
        microphoneWarning.toolTip = "No sound from the microphone"
        microphoneWarning.setAccessibilityLabel("No sound from the microphone")
        microphoneWarning.isHidden = true
        root.addSubview(microphoneWarning)

        pauseButton.frame = NSRect(x: 302, y: 8, width: 28, height: 28)
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        root.addSubview(pauseButton)

        discardButton.frame = NSRect(x: 332, y: 8, width: 28, height: 28)
        discardButton.target = self
        discardButton.action = #selector(discardTapped)
        root.addSubview(discardButton)

        stopButton.frame = NSRect(x: 362, y: 6, width: 32, height: 32)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        root.addSubview(stopButton)

        confirmDiscardButton.frame = NSRect(x: 262, y: 10, width: 66, height: 24)
        confirmDiscardButton.target = self
        confirmDiscardButton.action = #selector(confirmDiscardTapped)
        confirmDiscardButton.isHidden = true
        root.addSubview(confirmDiscardButton)

        keepButton.frame = NSRect(x: 334, y: 10, width: 58, height: 24)
        keepButton.target = self
        keepButton.action = #selector(keepTapped)
        keepButton.isHidden = true
        root.addSubview(keepButton)

        updateToolTips()
    }

    func configure(systemAudio: Bool, microphone: Bool, camera: Bool, keystrokes: Bool, fps: Int, quality: String) {
        let audio = if systemAudio && microphone {
            "sys+mic"
        } else if systemAudio {
            "system"
        } else if microphone {
            "mic"
        } else {
            "no audio"
        }
        detailText = "\(audio) · \(fps) fps"
        detailLabel.stringValue = detailText
        detailLabel.toolTip = "\(quality.capitalized) quality · \(audio)"
        showsMicrophone = microphone
        showsCamera = camera
        showsKeystrokes = keystrokes
        applyState()
    }

    func updateMicrophoneLevel(_ level: CGFloat) {
        microphoneLevelMeter.setLevel(level)
    }

    /// No audio arriving from the microphone (a meter at rest looks the same
    /// as a dead device, so say it).
    func setMicrophoneSilent(_ silent: Bool) {
        guard showsMicrophone, microphoneSilent != silent else { return }
        microphoneSilent = silent
        applyState()
    }

    /// A short note in the HUD (the toast carries the long version); the
    /// warning icon keeps it available as a tooltip afterwards.
    func showWarning(_ message: String) {
        warningIcon.toolTip = message
        warningIcon.setAccessibilityLabel(message)
        hasWarning = true
        applyState()
        guard state == .recording || state == .paused else { return }
        detailLabel.stringValue = message
        detailLabel.textColor = .systemOrange
        warningRevertWorkItem?.cancel()
        let revert = DispatchWorkItem { [weak self] in self?.restoreDetail() }
        warningRevertWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: revert)
    }

    func setPaused(_ paused: Bool) {
        if state == .confirmingDiscard {
            confirmResumeState = paused ? .paused : .recording
            return
        }
        guard state == .recording || state == .paused else { return }
        state = paused ? .paused : .recording
        applyState()
    }

    /// Between Stop and the file being ready.
    func showSaving() {
        cancelConfirmation()
        state = .saving
        applyState()
    }

    func show(on screen: NSScreen, avoiding recordedRect: CGRect? = nil) {
        updateTime()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let origin = Self.origin(size: frame.size, visibleFrame: screen.visibleFrame, savedOffset: Settings.recordingHUDOffset, avoiding: recordedRect)
        isPositioning = true
        setFrameOrigin(pixelAligned(origin, scale: screen.backingScaleFactor))
        isPositioning = false
        orderFrontRegardless()
        installEscapeMonitor()
    }

    func closeHUD() {
        removeEscapeMonitor()
        timer?.invalidate()
        timer = nil
        warningRevertWorkItem?.cancel()
        confirmTimeoutWorkItem?.cancel()
        spinner.stopAnimation(nil)
        microphoneLevelMeter.setLevel(0)
        orderOut(nil)
    }

    /// The saved spot on this screen (default: top center), kept on screen
    /// and — when there's room — outside the area being recorded, so the
    /// HUD doesn't sit on top of what the user is working in.
    static func origin(size: CGSize, visibleFrame: CGRect, savedOffset: CGPoint?, avoiding recordedRect: CGRect?) -> CGPoint {
        let offset = savedOffset ?? CGPoint(x: 0, y: 18)
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        func clamped(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
            return rect
        }
        var frame = clamped(CGRect(
            x: visibleFrame.midX + offset.x - size.width / 2,
            y: visibleFrame.maxY - offset.y - size.height,
            width: size.width,
            height: size.height
        ))
        if let recordedRect, frame.intersects(recordedRect) {
            let above = CGRect(x: frame.minX, y: recordedRect.maxY + 12, width: size.width, height: size.height)
            let below = CGRect(x: frame.minX, y: recordedRect.minY - 12 - size.height, width: size.width, height: size.height)
            if bounds.contains(above) {
                frame = above
            } else if bounds.contains(below) {
                frame = below
            }
            // A recording that fills the screen leaves no room; the HUD is
            // never in the video anyway.
        }
        return frame.origin
    }

    private func applyState() {
        let active = state == .recording || state == .paused
        let confirming = state == .confirmingDiscard
        let saving = state == .saving

        dot.isHidden = !(state == .recording || confirming)
        dotHalo.isHidden = dot.isHidden
        pauseGlyph.isHidden = state != .paused
        if saving { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        timeLabel.textColor = state == .paused ? NSColor.white.withAlphaComponent(0.6) : .white
        timeLabel.frame.size.width = saving ? 150 : 56
        detailLabel.isHidden = !active
        confirmLabel.isHidden = !confirming
        cameraIcon.isHidden = !(active && showsCamera)
        keysIcon.isHidden = !(active && showsKeystrokes)
        warningIcon.isHidden = !(active && hasWarning)
        layoutIndicators()
        microphoneLevelMeter.isHidden = !(active && showsMicrophone && !microphoneSilent)
        microphoneWarning.isHidden = !(active && showsMicrophone && microphoneSilent)
        pauseButton.isHidden = !active
        discardButton.isHidden = !active
        stopButton.isHidden = !active
        confirmDiscardButton.isHidden = !confirming
        keepButton.isHidden = !confirming

        pauseButton.setAccessibilityLabel(state == .paused ? "Resume recording" : "Pause recording")
        pauseButton.setSymbol(state == .paused ? "play.fill" : "pause.fill")
        updateToolTips()
        restoreDetail()
        updateTime()
    }

    private func restoreDetail() {
        guard state == .recording || state == .paused else { return }
        detailLabel.stringValue = state == .paused ? "Paused" : detailText
        detailLabel.textColor = state == .paused ? .systemYellow : NSColor.white.withAlphaComponent(0.46)
    }

    private func layoutIndicators() {
        var x: CGFloat = 220
        for icon in [cameraIcon, keysIcon, warningIcon] where !icon.isHidden {
            icon.frame = NSRect(x: x, y: 15, width: 14, height: 14)
            x += 17
        }
    }

    private func updateToolTips() {
        stopButton.toolTip = "Stop recording (\(RecordingStopHotkey.displayText))"
        let pauseShortcut = ShotnixShortcut.pauseRecording.assignedShortcutText.map { " (\($0))" } ?? ""
        pauseButton.toolTip = (state == .paused ? "Resume recording" : "Pause recording") + pauseShortcut
        discardButton.toolTip = "Discard recording"
    }

    private func updateTime() {
        switch state {
        case .saving:
            timeLabel.stringValue = "Saving…"
        default:
            let elapsed = max(0, Int(elapsedProvider?() ?? 0))
            timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func rememberPosition() {
        guard !isPositioning, isVisible, let screen = screen ?? NSScreen.screenContaining(rect: frame) else { return }
        let visible = screen.visibleFrame
        Settings.recordingHUDOffset = CGPoint(x: frame.midX - visible.midX, y: visible.maxY - frame.maxY)
    }

    // Escape stops the recording only while Shotnix itself is focused (the
    // HUD never takes focus). In other apps Esc belongs to them — and shows
    // up as a keycap; ⌃⌘Esc is the stop shortcut there.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }
            // Another Shotnix window is key (selection overlay, editor…) —
            // let it keep its own Escape handling.
            if let keyWindow = NSApp.keyWindow, keyWindow !== self { return event }
            if self.state == .confirmingDiscard {
                self.keepTapped()
            } else {
                self.stopHandler?()
            }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeKeyMonitor { NSEvent.removeMonitor(escapeKeyMonitor) }
        escapeKeyMonitor = nil
    }

    private func cancelConfirmation() {
        confirmTimeoutWorkItem?.cancel()
        confirmTimeoutWorkItem = nil
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    @objc private func stopTapped() {
        stopHandler?()
    }

    @objc private func pauseTapped() {
        pauseHandler?()
    }

    /// Discarding deletes the take, so it asks first — inline, without a
    /// dialog that would take focus from the recorded app.
    @objc private func discardTapped() {
        guard state == .recording || state == .paused else { return }
        confirmResumeState = state
        state = .confirmingDiscard
        applyState()
        cancelConfirmation()
        let timeout = DispatchWorkItem { [weak self] in self?.keepTapped() }
        confirmTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    @objc private func confirmDiscardTapped() {
        cancelConfirmation()
        discardHandler?()
    }

    @objc private func keepTapped() {
        cancelConfirmation()
        guard state == .confirmingDiscard else { return }
        state = confirmResumeState
        applyState()
    }
}

@MainActor
private final class RecordingHUDContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class RecordingHUDLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class RecordingHUDIconButton: NSButton {
    private let tint: NSColor
    private let pointSize: CGFloat

    init(symbol: String, label: String, tint: NSColor, size: CGFloat = 12) {
        self.tint = tint
        self.pointSize = size
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.withAlphaComponent(tint == .white ? 0.08 : 0.16).cgColor
        contentTintColor = tint == .white ? NSColor.white.withAlphaComponent(0.82) : tint
        setAccessibilityLabel(label)
        setSymbol(symbol)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSymbol(_ name: String) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel())?.withSymbolConfiguration(config)
    }

    override func mouseDown(with event: NSEvent) {
        let idle = layer?.backgroundColor
        layer?.backgroundColor = tint.withAlphaComponent(0.26).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = idle
    }
}

@MainActor
private final class RecordingHUDTextButton: NSButton {
    init(title: String, tint: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.withAlphaComponent(tint == .white ? 0.1 : 0.22).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: tint == .white ? NSColor.white.withAlphaComponent(0.88) : tint,
        ])
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class RecordingHUDLevelMeter: NSView {

    private let bars: [NSView]
    private var smoothedLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in NSView(frame: .zero) }
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.4
            bar.layer?.cornerCurve = .continuous
            addSubview(bar)
        }
        setAccessibilityLabel("Microphone level")
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.64 + clamped * 0.36
        let gap: CGFloat = 3
        let barWidth: CGFloat = 3
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.16
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.66))
            let height = baseHeight + response * (bounds.height - baseHeight)
            let x = CGFloat(index) * (barWidth + gap)
            bar.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.16).cgColor
        }
    }
}
