import AppKit
import AVFoundation

/// The camera while recording: a live bubble on screen (kept out of the
/// screen capture) and a separate movie file that the editor places over
/// the recording — so its size, shape, and position stay editable.
@MainActor
final class CameraCapture {
    static let shared = CameraCapture()

    enum StartResult: Equatable {
        case started
        case denied
        case noCamera
        case failed

        /// What to tell the user when the camera can't be used.
        var message: String? {
            switch self {
            case .started: nil
            case .denied: "Camera access is off — allow Shotnix in System Settings → Privacy & Security → Camera."
            case .noCamera: "No camera found."
            case .failed: "The camera couldn't start."
            }
        }
    }

    enum Interruption: Equatable {
        case disconnected
        case failed
    }

    private var session: AVCaptureSession?
    private var pipeline: CameraPipeline?
    private var bubble: CameraBubbleWindow?
    private var isRecording = false
    private var observers: [NSObjectProtocol] = []
    /// Told when the camera drops out mid-session (unplugged, taken by
    /// another app, a capture error).
    var interruptionHandler: ((Interruption) -> Void)?

    var isActive: Bool { session != nil }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static var devices: [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func device(for id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let device = AVCaptureDevice(uniqueID: id), device.isConnected { return device }
        return AVCaptureDevice.default(for: .video) ?? devices.first
    }

    /// Where camera movies live (next to the other editor data, not in the
    /// user's recordings folder).
    static func movieURL(for screenRecording: URL) -> URL {
        VideoStorageLocation.root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoCameras", isDirectory: true)
            .appendingPathComponent("\(screenRecording.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).mov")
    }

    /// Starts the camera and shows the bubble at the bottom-right of `rect`
    /// (screen coordinates).
    @discardableResult
    func start(deviceID: String, around rect: CGRect, on screen: NSScreen) async -> StartResult {
        if session != nil {
            // A spot the user dragged the bubble to stays put.
            if let bubble, !bubble.wasMovedByUser { bubble.place(around: rect, on: screen) }
            return .started
        }
        guard await Self.requestAccess() else { return .denied }
        guard session == nil else { return .started }
        guard let device = Self.device(for: deviceID) else { return .noCamera }

        let pipeline = CameraPipeline()
        let session = AVCaptureSession()
        do {
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else {
                session.sessionPreset = .high
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraCaptureError.unavailable }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(pipeline, queue: pipeline.queue)
            guard session.canAddOutput(output) else { throw CameraCaptureError.unavailable }
            session.addOutput(output)
            session.commitConfiguration()
        } catch {
            print("[Shotnix] Camera setup failed: \(error)")
            return .failed
        }

        self.session = session
        self.pipeline = pipeline
        let bubble = CameraBubbleWindow(session: session)
        bubble.place(around: rect, on: screen)
        bubble.orderFrontRegardless()
        self.bubble = bubble
        observe(session: session, device: device)

        nonisolated(unsafe) let running = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                running.startRunning()
                continuation.resume()
            }
        }
        return .started
    }

    /// Hides the bubble and releases the camera (no-op while recording).
    func stop() {
        guard !isRecording else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        bubble?.orderOut(nil)
        bubble = nil
        pipeline = nil
        guard let session else { return }
        self.session = nil
        nonisolated(unsafe) let stopping = session
        DispatchQueue.global(qos: .userInitiated).async { stopping.stopRunning() }
    }

    /// `onFirstFrame` gets the first written frame's host time.
    func beginRecording(to url: URL, onFirstFrame: @escaping @Sendable (Double) -> Void = { _ in }) {
        guard let pipeline else { return }
        isRecording = true
        pipeline.begin(url: url, onFirstFrame: onFirstFrame)
    }

    /// Same host clock as the screen recording's pause, so both stay aligned.
    func pauseRecording(at host: Double) {
        guard isRecording else { return }
        pipeline?.pause(at: host)
    }

    func resumeRecording(at host: Double) {
        guard isRecording else { return }
        pipeline?.resume(at: host)
    }

    /// Finishes the camera movie. `firstFrameTime` is host-clock seconds —
    /// the same clock as the screen frames — so the editor can line them up.
    func finishRecording() async -> CameraPipeline.Result? {
        guard isRecording, let pipeline else {
            isRecording = false
            return nil
        }
        let result = await pipeline.finish()
        isRecording = false
        return result
    }

    /// Recording failed or was abandoned: drop the camera file.
    func cancelRecording() {
        guard isRecording, let pipeline else { return }
        isRecording = false
        pipeline.cancel()
    }

    private func observe(session: AVCaptureSession, device: AVCaptureDevice) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                MainActor.assumeIsolated {
                    print("[Shotnix] Camera session error: \(error.map { "\($0)" } ?? "unknown")")
                    self?.interruptionHandler?(.failed)
                }
            },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptionHandler?(.disconnected) }
            },
        ]
    }
}

enum CameraCaptureError: Error {
    case unavailable
}

/// Receives camera frames and writes them to a movie while armed.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let url: URL
        /// Host-clock seconds of the first written frame.
        let firstFrameTime: Double
        let size: CGSize
    }

    let queue = DispatchQueue(label: "com.shotnix.camera", qos: .userInitiated)

    // Touched only on `queue`.
    private var armed = false
    private var url: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var timeline = RecordingTimeline()
    private var lastTime: Double?
    private var size: CGSize = .zero
    private var onFirstFrame: (@Sendable (Double) -> Void)?

    func begin(url: URL, onFirstFrame: @escaping @Sendable (Double) -> Void = { _ in }) {
        queue.async {
            self.url = url
            self.writer = nil
            self.input = nil
            self.timeline = RecordingTimeline()
            self.lastTime = nil
            self.onFirstFrame = onFirstFrame
            self.armed = true
        }
    }

    func pause(at host: Double) {
        queue.async { self.timeline.pause(at: host) }
    }

    func resume(at host: Double) {
        queue.async { self.timeline.resume(at: host) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer)
    }

    /// Writes one camera frame (call on `queue`).
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard armed, let url else { return }
        let host = sampleBuffer.presentationTimeStamp.seconds
        if writer == nil {
            guard !timeline.isPaused,
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width > 0, dimensions.height > 0 else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                // Fragments keep the camera movie readable after a crash,
                // like the screen recording beside it.
                writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                let pixels = Double(dimensions.width) * Double(dimensions.height)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(dimensions.width),
                    AVVideoHeightKey: Int(dimensions.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(pixels * 30 * 0.12),
                        AVVideoMaxKeyFrameIntervalKey: 60,
                    ],
                    // Tag (and color-match into) HD video colors, so every
                    // decoder reads skin tones the same way.
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw CameraCaptureError.unavailable }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? CameraCaptureError.unavailable }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.input = input
                timeline.start(at: host)
                size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                onFirstFrame?(host)
            } catch {
                print("[Shotnix] Camera writer failed: \(error)")
                armed = false
                return
            }
        }
        // Paused stretches are cut out, exactly as in the screen recording.
        guard let input, input.isReadyForMoreMediaData,
              let time = timeline.time(at: host), time >= 0,
              lastTime.map({ time > $0 }) ?? true,
              let retimed = RecordingWriterCore.copy(sampleBuffer: sampleBuffer, presentationTime: CMTime(seconds: time, preferredTimescale: 60_000), duration: .invalid)
        else { return }
        if input.append(retimed) { lastTime = time }
    }

    func finish() async -> Result? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.armed = false
                guard let writer = self.writer,
                      let input = self.input,
                      let first = self.timeline.origin,
                      let url = self.url,
                      writer.status == .writing else {
                    self.writer = nil
                    self.input = nil
                    continuation.resume(returning: nil)
                    return
                }
                let size = self.size
                self.writer = nil
                self.input = nil
                input.markAsFinished()
                nonisolated(unsafe) let finishing = writer
                writer.finishWriting {
                    let ok = finishing.status == .completed
                    continuation.resume(returning: ok ? Result(url: url, firstFrameTime: first, size: size) : nil)
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.armed = false
            self.writer?.cancelWriting()
            if let url = self.url { try? FileManager.default.removeItem(at: url) }
            self.writer = nil
            self.input = nil
        }
    }
}

/// The round, draggable camera preview shown while recording. Invisible to
/// screen capture — the editor draws the camera from its own file.
final class CameraBubbleWindow: NSPanel {
    private static let diameter: CGFloat = 168

    /// Set once the user drags the bubble: later placements leave it there.
    private(set) var wasMovedByUser = false
    private var placedOrigin: CGPoint?
    private var moveObserver: NSObjectProtocol?

    init(session: AVCaptureSession) {
        let size = Self.diameter
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        sharingType = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)

        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 3
        view.layer?.addSublayer(ring)

        contentView = view
        setAccessibilityLabel("Camera preview")
        // Compared against where `place` put it: programmatic moves may
        // report after the fact.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let placedOrigin = self.placedOrigin else { return }
                if abs(self.frame.minX - placedOrigin.x) > 0.5 || abs(self.frame.minY - placedOrigin.y) > 0.5 {
                    self.wasMovedByUser = true
                }
            }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    override var canBecomeKey: Bool { false }

    /// Bottom-right corner of `rect`, inset, kept on screen.
    func place(around rect: CGRect, on screen: NSScreen) {
        let size = Self.diameter
        let margin: CGFloat = 28
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.maxX - size - margin, y: rect.minY + margin)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size - 8)
        placedOrigin = origin
        setFrameOrigin(origin)
    }
}
