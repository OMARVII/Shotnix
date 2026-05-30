import AppKit

@MainActor
final class RecordingHUDWindow: NSWindow {

    var stopHandler: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let detailLabel = NSTextField(labelWithString: "Recording")
    private let microphoneLevelMeter = RecordingHUDLevelMeter()
    private let stopButton = RecordingHUDStopButton()
    private var startedAt = Date()
    private var timer: Timer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 312, height: 44),
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
        hidesOnDeactivate = false
        sharingType = .none

        let root = RecordingHUDContentView(frame: NSRect(origin: .zero, size: frame.size))
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

        let topGlow = NSView(frame: NSRect(x: 16, y: frame.height - 1, width: frame.width - 32, height: 1))
        topGlow.wantsLayer = true
        topGlow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.addSubview(topGlow)

        let grip = RecordingHUDLabel(labelWithString: "⋮⋮")
        grip.font = .systemFont(ofSize: 14, weight: .bold)
        grip.textColor = NSColor.white.withAlphaComponent(0.26)
        grip.frame = NSRect(x: 10, y: 13, width: 18, height: 18)
        root.addSubview(grip)

        let dotHalo = NSView(frame: NSRect(x: 30, y: 15, width: 14, height: 14))
        dotHalo.wantsLayer = true
        dotHalo.layer?.borderWidth = 1
        dotHalo.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.34).cgColor
        dotHalo.layer?.cornerRadius = 7
        root.addSubview(dotHalo)

        let dot = NSView(frame: NSRect(x: 34, y: 19, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        root.addSubview(dot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 52, y: 13, width: 58, height: 18)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        root.addSubview(timeLabel)

        detailLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.46)
        detailLabel.frame = NSRect(x: 114, y: 14, width: 112, height: 14)
        detailLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(detailLabel)

        microphoneLevelMeter.frame = NSRect(x: 234, y: 11, width: 25, height: 22)
        microphoneLevelMeter.isHidden = true
        root.addSubview(microphoneLevelMeter)

        stopButton.title = ""
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.toolTip = "Stop recording"
        stopButton.frame = NSRect(x: 272, y: 6, width: 32, height: 32)
        root.addSubview(stopButton)
    }

    override var canBecomeKey: Bool { false }

    func configure(systemAudio: Bool, microphone: Bool, fps: Int, quality: String) {
        let audio = if systemAudio && microphone {
            "sys+mic"
        } else if systemAudio {
            "system"
        } else if microphone {
            "mic"
        } else {
            "no audio"
        }
        detailLabel.stringValue = "\(audio) · \(fps) fps"
        detailLabel.toolTip = "\(quality.capitalized) quality · \(audio)"
        microphoneLevelMeter.isHidden = !microphone
    }

    func updateMicrophoneLevel(_ level: CGFloat) {
        microphoneLevelMeter.setLevel(level)
    }

    func show(on screen: NSScreen) {
        startedAt = Date()
        updateTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateTime() }
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(x: visibleFrame.midX - frame.width / 2, y: visibleFrame.maxY - frame.height - 18)
        setFrameOrigin(pixelAligned(origin, scale: screen.backingScaleFactor))
        orderFrontRegardless()
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    func closeHUD() {
        timer?.invalidate()
        timer = nil
        microphoneLevelMeter.setLevel(0)
        orderOut(nil)
    }

    private func updateTime() {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopTapped() {
        stopHandler?()
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
private final class RecordingHUDStopButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16).cgColor
        contentTintColor = .systemRed
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop recording")?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.24).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16).cgColor
    }
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
