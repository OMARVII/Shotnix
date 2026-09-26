import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

@MainActor
final class RecordingEngine: NSObject {

    private let writerQueue = DispatchQueue(label: "com.shotnix.recording.writer", qos: .userInitiated)
    /// All per-buffer append state lives here, confined to writerQueue —
    /// see RecordingWriterCore. The engine keeps only lifecycle state.
    private let writerCore = RecordingWriterCore()
    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var streamConfiguration: SCStreamConfiguration?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var microphone: RecordingMicrophone?
    private var outputURL: URL?
    private var source: RecordingSource?
    private var recordingScreen: NSScreen?
    private var displays: [SCDisplay] = []
    /// The main actor's copy of the writer core's timeline: pauses are
    /// decided here, and the first frame's time arrives via onFirstFrame.
    private var timeline = RecordingTimeline()
    private var recordingStartedAt: CFTimeInterval = 0
    private var stopHostTime: CFTimeInterval?
    private var isStarting = false
    private var isRecording = false
    private var isFinishing = false
    /// Which recording the running start flow belongs to: a stop (or a new
    /// recording) during one of its awaits changes it.
    private var recordingSessionID = UUID()
    private var finishSessionID = UUID()
    private var slowSaveWorkItems: [DispatchWorkItem] = []
    private var hud: RecordingHUDWindow?
    private var outline: RecordingAreaOutlineWindow?
    private var configuration = RecordingConfiguration.current
    private var metadataRecorder: VideoDemoRecordingMetadataRecorder?
    private var pendingRecordingMetadata: VideoDemoRecordingMetadata?
    private var recordsCamera = false
    private var cameraFinishTask: Task<CameraPipeline.Result?, Never>?
    private var cameraFirstFrameHostTime: Double?
    private var recoveryNote: RecordingRecoveryNote?
    private var terminationToken: AppTermination.Token?
    private var terminationCallbacks: [@MainActor () -> Void] = []
    private var endsForTermination = false
    private var displaySleepActivity: NSObjectProtocol?
    private var monitorTimer: Timer?
    private var followTimer: Timer?
    private var bytesPerSecond: Int64 = 0
    private var didWarnLowDiskSpace = false
    private var didWarnWindowClosed = false
    private var lastMicrophoneSampleAt: CFTimeInterval = 0
    private var followedWindow: SCWindow?
    /// The followed window's app's other windows, left out of the video.
    private var followedWindowHidden: [SCWindow] = []
    private var followedWindowFrame: CGRect?
    private var outputPixelSize: CGSize = .zero
    private var excludesOwnApp = true
    private var ownWindowObservers: [NSObjectProtocol] = []
    private var ownWindowsSignature: [CGWindowID] = []
    private var filterUpdateWorkItem: DispatchWorkItem?
    /// Stop took the foreground for the editor; whatever doesn't open it
    /// must give it back, or Shotnix keeps a Dock icon.
    private var holdsForegroundForEditor = false
    private var startIsWaitingForSave = false

    /// A saved take: the app opens it or announces it.
    var recordingFinishedHandler: ((FinishedRecording) -> Void)?
    /// Whether the next take is being set up (area selection, the recording
    /// bar, a countdown): a finished take's editor would open over it.
    var nextTakeInProgress: (() -> Bool)?
    /// Tests: sends the next finished take down the salvage path, as if the
    /// writer had failed, and runs this where it checks what still plays.
    var salvagesNextSaveForTesting: (() -> Void)?
    /// Fired on every recording lifecycle transition (started, paused,
    /// saving, fully stopped) — drives the menu bar recording indicator.
    var stateChangedHandler: (() -> Void)?
    var active: Bool { isStarting || isRecording || isFinishing }
    /// Between Stop and the file being ready.
    var isSaving: Bool { isFinishing }
    var isPaused: Bool { isRecording && timeline.isPaused }
    /// Recorded time so far, pauses excluded; nil when not recording.
    var elapsedSeconds: TimeInterval? {
        isRecording ? recordedSeconds : nil
    }

    override init() {
        super.init()
        RecordingFocus.startTracking()
    }

    private var recordedSeconds: TimeInterval {
        let now = CACurrentMediaTime()
        if timeline.hasStarted { return timeline.duration(at: now) }
        // No frame yet: count from the start, still frozen while paused.
        guard recordingStartedAt > 0 else { return 0 }
        let end = timeline.pauseStart.map { min($0, now) } ?? now
        return max(0, end - recordingStartedAt)
    }

    /// Whether the screen has delivered a frame yet (for tests and diagnostics).
    var hasCapturedFrames: Bool { timeline.hasStarted }

    /// Record was pressed; the start itself runs a moment later. A take
    /// finishing in between already counts the new one as queued.
    func startWillFollow() {
        if isFinishing, !isRecording { startIsWaitingForSave = true }
    }

    func startRecording(rect: CGRect, on screen: NSScreen) async {
        await startRecording(source: .displayRect(rect: rect, screen: screen))
    }

    func startRecording(window: SCWindow, on screen: NSScreen) async {
        await startRecording(source: .window(window, screen: screen))
    }

    private func startRecording(source: RecordingSource) async {
        let screen = source.screen
        if isFinishing, !isRecording {
            // The next recording can be set up while the last one saves;
            // it starts as soon as that file is ready (without the last
            // one's editor opening over it).
            ToastWindow.show(message: "Saving the last recording…", on: screen)
            startIsWaitingForSave = true
            await waitUntilSaved(timeout: 30)
        }
        startIsWaitingForSave = false
        guard !active else {
            // The recording bar left the camera preview running for us.
            CameraCapture.shared.stop()
            ToastWindow.show(message: isFinishing ? "Still saving the last recording — try again in a moment." : "Recording already in progress", on: screen)
            return
        }
        isStarting = true
        defer { isStarting = false }
        let session = UUID()
        recordingSessionID = session

        let saveFolder = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        if let available = RecordingDiskSpace.availableCapacity(at: saveFolder), available < RecordingDiskSpace.minimumToStart {
            CameraCapture.shared.stop()
            ToastWindow.show(message: "Not enough free disk space to record.", on: screen)
            return
        }

        var configuration = RecordingConfiguration.current
        var notices: [String] = []
        var microphone: RecordingMicrophone?
        if configuration.recordsMicrophone {
            if !(await requestMicrophonePermissionIfNeeded()) {
                configuration.recordsMicrophone = false
                notices.append("Microphone access is off, so this recording has no mic.")
            } else if let device = RecordingMicrophone.device(for: configuration.microphoneDeviceID) {
                // Opened before the file exists: a microphone that won't
                // start can't leave a broken recording behind.
                let candidate = RecordingMicrophone(delegate: MicrophoneCaptureDelegate(recordingEngine: self), sampleQueue: writerQueue)
                do {
                    try candidate.prepare(device: device)
                    microphone = candidate
                } catch {
                    configuration.recordsMicrophone = false
                    notices.append("The microphone couldn't start, so this recording has no mic.")
                    print("[Shotnix] Microphone setup failed: \(error)")
                }
            } else {
                configuration.recordsMicrophone = false
                notices.append("No microphone is connected, so this recording has no mic.")
            }
        }

        var createdURL: URL?
        var createdWriter: AVAssetWriter?
        do {
            if configuration.recordsCamera {
                let result = await CameraCapture.shared.start(deviceID: configuration.cameraDeviceID, around: source.initialRect, on: screen)
                if let message = result.message {
                    configuration.recordsCamera = false
                    notices.append("\(message) Recording without the camera.")
                }
            } else {
                CameraCapture.shared.stop()
            }

            let content = try await Self.withTimeout(10) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            let prepared = try prepareCaptureSource(source, configuration: configuration, content: content)
            let format = RecordingVideoFormat.plan(width: prepared.pixelWidth, height: prepared.pixelHeight, fps: configuration.fps)
            if format.width != prepared.pixelWidth || format.height != prepared.pixelHeight {
                // No encoder here takes the full size: scale the capture to fit.
                prepared.streamConfig.width = format.width
                prepared.streamConfig.height = format.height
                prepared.streamConfig.scalesToFit = true
            }
            prepared.streamConfig.queueDepth = RecordingVideoFormat.queueDepth(width: format.width, height: format.height)

            let url = Self.makeOutputURL()
            let handles = try Self.makeWriter(
                url: url,
                format: format,
                fps: configuration.fps,
                quality: configuration.quality,
                microphone: configuration.recordsMicrophone,
                systemAudio: configuration.recordsSystemAudio
            )
            createdURL = url
            createdWriter = handles.writer

            let output = RecordingStreamOutput(recordingEngine: self)
            let stream = SCStream(filter: prepared.filter, configuration: prepared.streamConfig, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writerQueue)
            if configuration.recordsSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writerQueue)
            }
            self.stream = stream
            streamOutput = output
            streamConfiguration = prepared.streamConfig
            assetWriter = handles.writer
            videoInput = handles.videoInput
            systemAudioInput = handles.systemAudioInput
            microphoneInput = handles.microphoneInput
            outputURL = url
            self.source = source
            self.microphone = microphone
            self.configuration = configuration
            displays = content.displays
            recordingScreen = prepared.screen
            excludesOwnApp = prepared.excludesOwnApp
            followedWindow = prepared.window
            followedWindowHidden = prepared.hiddenWindows
            followedWindowFrame = prepared.window?.frame
            outputPixelSize = CGSize(width: format.width, height: format.height)
            let videoBitrate = configuration.quality.bitrate(width: format.width, height: format.height, fps: configuration.fps, codec: format.codec)
            bytesPerSecond = RecordingSizeEstimate.bytesPerMinute(
                videoBitrate: videoBitrate,
                systemAudio: configuration.recordsSystemAudio,
                microphone: configuration.recordsMicrophone
            ) / 60 + (configuration.recordsCamera ? 420_000 : 0)
            didWarnLowDiskSpace = false
            didWarnWindowClosed = false

            let metadataRecorder = VideoDemoRecordingMetadataRecorder(
                videoURL: url,
                captureRect: prepared.captureRect,
                sourcePixelSize: CGSize(width: format.width, height: format.height),
                fps: configuration.fps,
                nativeCursorVisible: configuration.bakesCursorIntoVideo,
                renderCursor: configuration.showsCursor && !configuration.bakesCursorIntoVideo,
                recordsKeystrokes: Settings.recordingKeystrokes
            )
            self.metadataRecorder = metadataRecorder
            timeline = RecordingTimeline()
            stopHostTime = nil
            endsForTermination = false
            isFinishing = false
            isRecording = true
            recordingStartedAt = CACurrentMediaTime()
            metadataRecorder.start()
            stateChangedHandler?()

            // Arm the queue-confined writer core before any buffer can arrive
            // (the stream hasn't started yet; the serial queue preserves order).
            let core = writerCore
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
            let onFirstFrame: (Double) -> Void = { [weak self] hostTime in
                Task { @MainActor in self?.firstFrameArrived(at: hostTime) }
            }
            let onWriterFailure: () -> Void = { [weak self] in
                Task { @MainActor in self?.requestStop(.writerFailed) }
            }
            let onFramesDropping: () -> Void = { [weak self] in
                Task { @MainActor in
                    self?.warn(hud: "Skipping frames", toast: "Your Mac can't keep up with this recording and is skipping frames. Balanced quality or 30 fps will help.")
                }
            }
            writerQueue.async {
                core.begin(
                    handles: handles,
                    frameDuration: frameDuration,
                    onFirstFrame: onFirstFrame,
                    onWriterFailure: onWriterFailure,
                    onFramesDropping: onFramesDropping
                )
            }

            // The microphone runs before the stream: what it hears before the
            // first frame is trimmed off, so voice lines up with the picture.
            await microphone?.start()
            // Stopped while the microphone started: the finish flow already
            // cleaned up this recording.
            guard recordingSessionID == session, isRecording else { return }
            cameraFinishTask = nil
            cameraFirstFrameHostTime = nil
            recordsCamera = configuration.recordsCamera
            let cameraURL = recordsCamera ? CameraCapture.movieURL(for: url) : nil
            if let cameraURL {
                CameraCapture.shared.beginRecording(to: cameraURL) { [weak self] hostTime in
                    Task { @MainActor in self?.cameraFirstFrameArrived(at: hostTime) }
                }
            }
            let note = RecordingRecoveryNote(
                videoPath: url.path,
                cameraPath: cameraURL?.path,
                cameraOffset: nil,
                fps: configuration.fps,
                nativeCursorVisible: configuration.bakesCursorIntoVideo,
                audioTracks: audioKinds.isEmpty ? nil : audioKinds,
                startedAt: Date()
            )
            recoveryNote = note
            RecordingRecovery.save(note)
            try await Self.startCapture(StreamBox(stream), within: 15)
            guard recordingSessionID == session, isRecording else {
                // Stopped while the stream was starting: the finish flow is
                // done with this recording, and the stream it couldn't stop
                // (not started yet) mustn't keep capturing on its own.
                try? await stream.stopCapture()
                return
            }
            didStartRecording(notices: notices, captureRect: prepared.captureRect)
        } catch {
            guard recordingSessionID == session else {
                // A stop already finished this recording (and deleted its file).
                print("[Shotnix] Recording start failed after stop: \(error)")
                return
            }
            await failStart(error, url: createdURL, writer: createdWriter, microphone: microphone, screen: screen)
        }
    }

    /// Everything that only makes sense once frames flow.
    private func didStartRecording(notices: [String], captureRect: CGRect) {
        registerForTermination()
        RecordingStopHotkey.register { [weak self] in self?.stopRecording() }
        // Idle display sleep would end up in the video (and stop the
        // stream on some Macs).
        displaySleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Recording the screen"
        )
        startMonitoring()
        observeOwnWindows()
        CameraCapture.shared.interruptionHandler = { [weak self] interruption in
            self?.cameraInterrupted(interruption)
        }
        microphone?.eventHandler = { [weak self] event in
            self?.microphoneChanged(event)
        }

        let screen = recordingScreen ?? source?.screen ?? NSScreen.main
        let hud = RecordingHUDWindow()
        hud.configure(
            systemAudio: configuration.recordsSystemAudio,
            microphone: configuration.recordsMicrophone,
            camera: configuration.recordsCamera,
            keystrokes: Settings.recordingKeystrokes && VideoKeystrokeFormatter.isAllowed,
            fps: configuration.fps,
            quality: configuration.quality.displayName
        )
        hud.stopHandler = { [weak self] in self?.stopRecording() }
        hud.pauseHandler = { [weak self] in self?.togglePause() }
        hud.discardHandler = { [weak self] in self?.discardRecording() }
        hud.elapsedProvider = { [weak self] in self?.recordedSeconds ?? 0 }
        self.hud = hud

        var avoiding: CGRect?
        if case .displayRect(let rect, let areaScreen) = source, !Self.coversScreen(rect, areaScreen) {
            avoiding = captureRect
            let outline = RecordingAreaOutlineWindow(around: captureRect)
            outline.show()
            self.outline = outline
        } else if case .window = source {
            avoiding = captureRect
        }
        if let screen { hud.show(on: screen, avoiding: avoiding) }
        // Paused (menu or shortcut) while the stream was starting.
        hud.setPaused(timeline.isPaused)
        outline?.setPaused(timeline.isPaused)

        if !notices.isEmpty {
            ToastWindow.show(message: notices.joined(separator: " "), duration: 4, on: screen)
        }
    }

    func stopRecording() {
        requestStop(.user)
    }

    func togglePause() {
        guard isRecording, !isFinishing else { return }
        let now = CACurrentMediaTime()
        let core = writerCore
        if timeline.isPaused {
            timeline.resume(at: now)
            writerQueue.async { core.resume(at: now) }
            metadataRecorder?.resume(at: now)
            CameraCapture.shared.resumeRecording(at: now)
        } else {
            timeline.pause(at: now)
            writerQueue.async { core.pause(at: now) }
            metadataRecorder?.pause(at: now)
            CameraCapture.shared.pauseRecording(at: now)
        }
        hud?.setPaused(timeline.isPaused)
        outline?.setPaused(timeline.isPaused)
        stateChangedHandler?()
    }

    /// Throws the take away: files deleted, nothing opens.
    func discardRecording() {
        requestStop(.discard)
    }

    private func requestStop(_ reason: StopReason) {
        guard isRecording, !isFinishing else { return }
        if case .user = reason, Settings.openVideoEditorAfterRecording, !isNextTakeQueued {
            // The user just acted — the one moment macOS lets Shotnix take
            // focus. Keep it until the editor opens, or the editor would open
            // behind the app that was being recorded.
            ShotnixEditorActivation.holdForeground()
            holdsForegroundForEditor = true
        }
        beginFinishing(reason)

        let streamToStop = stream
        let outputToRemove = streamOutput
        Task {
            if let streamToStop {
                // A stalled stop still ends with the file saved.
                let stopping = StreamBox(streamToStop)
                do {
                    try await Self.withTimeout(5) { try await stopping.stream.stopCapture() }
                } catch {
                    print("[Shotnix] Recording stop failed: \(error)")
                }
            }
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            if case .discard = reason {
                finishDiscard()
            } else {
                finishRecording(reason: reason)
            }
        }
    }

    fileprivate nonisolated func streamDidStopWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, !self.isFinishing else { return }
            // Stopping sharing from the system's menu bar indicator is a
            // normal stop, not a failure.
            let reason: StopReason = (error as NSError).code == SCStreamError.userStopped.rawValue ? .systemStopped : .streamError(error)
            self.beginFinishing(reason)
            self.finishRecording(reason: reason)
        }
    }

    // These run on writerQueue (SCStream and the mic delegate deliver there)
    // and append directly via the queue-confined core — no per-buffer
    // main-actor hop. Only the tiny mic-level float crosses to the HUD.

    fileprivate nonisolated func processScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[SCStreamFrameInfo.status],
              Self.frameStatus(from: rawStatus) == .complete else {
            return
        }
        let dirtyRects = (info[SCStreamFrameInfo.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let scale = (info[SCStreamFrameInfo.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        let contentScale = (info[SCStreamFrameInfo.contentScale] as? NSNumber)?.doubleValue ?? 1
        writerCore.appendVideo(sampleBuffer, dirtyRects: dirtyRects, pixelsPerPoint: CGFloat(scale * contentScale))
    }

    fileprivate nonisolated func processSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        writerCore.appendAudio(sampleBuffer, to: .system)
    }

    fileprivate nonisolated func processMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let level = Self.microphoneLevel(from: sampleBuffer)
        writerCore.appendAudio(sampleBuffer, to: .microphone)
        Task { @MainActor [weak self] in
            self?.lastMicrophoneSampleAt = CACurrentMediaTime()
            self?.hud?.updateMicrophoneLevel(level)
        }
    }

    private func prepareCaptureSource(
        _ source: RecordingSource,
        configuration: RecordingConfiguration,
        content: SCShareableContent
    ) throws -> PreparedCaptureSource {
        switch source {
        case .displayRect(let rect, let screen):
            // `rect` is AppKit-space while SCDisplay frames are CG-space —
            // match the display by ID, never by cross-space geometry.
            guard let display = ScreenCoordinates.display(for: screen, in: content.displays) else {
                throw RecordingError.noDisplay
            }
            let filter = RecordingCaptureFilter.displayFilter(display: display, content: content)
            var prepared = prepareGeometry(rect: rect, on: screen, configuration: configuration, filter: filter)
            prepared.excludesOwnApp = content.applications.contains { $0.processID == pid_t(ProcessInfo.processInfo.processIdentifier) }
            return prepared

        case .window(let window, let screen):
            guard let selectedWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw RecordingError.windowGone
            }
            // SCWindow.frame and SCDisplay.frame are both CG-space (top-left
            // origin), so pick the display showing the largest share of the window.
            guard let display = Self.display(mostOverlapping: selectedWindow.frame, in: content.displays)
                    ?? ScreenCoordinates.display(for: screen, in: content.displays) else {
                throw RecordingError.noDisplay
            }
            // The sourceRect math is relative to the NSScreen, so it must be
            // the screen backing the display we filter on.
            let targetScreen = NSScreen.screens.first { $0.displayID == display.displayID } ?? screen
            let appKitRect = ScreenCoordinates.appKitRect(fromCG: selectedWindow.frame)
            // The app's other windows would cover the chosen one where they
            // overlap it; its menus, popovers and sheets still come through.
            let hidden = RecordingCaptureFilter.windowsToHide(recording: selectedWindow, in: content)
            var prepared = prepareGeometry(
                rect: appKitRect,
                on: targetScreen,
                configuration: configuration,
                filter: RecordingCaptureFilter.windowFilter(for: selectedWindow, hiding: hidden, on: display)
            )
            // Resizing mid-recording scales the window into the fixed-size
            // video instead of cropping it.
            prepared.streamConfig.scalesToFit = true
            if #available(macOS 14.0, *) {
                prepared.streamConfig.preservesAspectRatio = true
            }
            prepared.window = selectedWindow
            prepared.hiddenWindows = hidden
            return prepared
        }
    }

    private static func display(mostOverlapping cgRect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays
            .map { (display: $0, overlap: $0.frame.intersection(cgRect)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .display
    }

    private func prepareGeometry(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        filter: SCContentFilter
    ) -> PreparedCaptureSource {
        let scale = Self.pixelScale(for: filter, fallbackScreen: screen)
        let geometry = Self.captureGeometry(rect: rect, screenFrame: screen.frame, scale: scale)
        let streamConfig = Self.streamConfiguration(width: geometry.pixelWidth, height: geometry.pixelHeight, configuration: configuration)
        streamConfig.sourceRect = geometry.sourceRect

        return PreparedCaptureSource(
            filter: filter,
            streamConfig: streamConfig,
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            captureRect: geometry.capturedRect,
            screen: screen
        )
    }

    struct CaptureGeometry: Equatable {
        /// Display-local, top-left origin, in points.
        let sourceRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        /// The region actually recorded, AppKit space.
        let capturedRect: CGRect
    }

    /// Whole physical pixels, even-sized (the encoder needs even
    /// dimensions), and a captured region exactly that size — so nothing
    /// is resampled and no edge is left unfilled. The pointer data is
    /// normalized to `capturedRect`, so it matches the pixels exactly.
    static func captureGeometry(rect: CGRect, screenFrame: CGRect, scale: CGFloat) -> CaptureGeometry {
        let pixelWidth = max(2, evenCeil(Int(ceil(rect.width * scale - 0.0001))))
        let pixelHeight = max(2, evenCeil(Int(ceil(rect.height * scale - 0.0001))))
        let width = CGFloat(pixelWidth) / scale
        let height = CGFloat(pixelHeight) / scale
        var originX = floor((rect.origin.x - screenFrame.origin.x) * scale + 0.0001) / scale
        var originY = floor((rect.origin.y - screenFrame.origin.y) * scale + 0.0001) / scale
        // Rounding up to even can reach past the screen edge: step back in.
        originX = max(min(originX, screenFrame.width - width), 0)
        originY = max(min(originY, screenFrame.height - height), 0)
        return CaptureGeometry(
            sourceRect: CGRect(x: originX, y: screenFrame.height - originY - height, width: width, height: height),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            capturedRect: CGRect(x: screenFrame.origin.x + originX, y: screenFrame.origin.y + originY, width: width, height: height)
        )
    }

    /// Where a followed window's pixels land in the fixed-size video once
    /// its size changes: scaled to fit and centered (normalized, y down).
    nonisolated static func fittedVideoRect(sourceSize: CGSize, outputSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, outputSize.width > 0, outputSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let scale = min(outputSize.width / sourceSize.width, outputSize.height / sourceSize.height)
        let width = sourceSize.width * scale / outputSize.width
        let height = sourceSize.height * scale / outputSize.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private static func coversScreen(_ rect: CGRect, _ screen: NSScreen) -> Bool {
        rect.width >= screen.frame.width - 1 && rect.height >= screen.frame.height - 1
    }

    private static func streamConfiguration(width: Int, height: Int, configuration: RecordingConfiguration) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.queueDepth = RecordingVideoFormat.queueDepth(width: width, height: height)
        // Editable-cursor recordings keep the pointer OUT of the pixels; the
        // editor redraws it from the recorded path — smoothed, resizable,
        // and crisp at any zoom.
        streamConfig.showsCursor = configuration.bakesCursorIntoVideo
        streamConfig.scalesToFit = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        // Frames arrive tagged sRGB; the encoder is set to HD colors to
        // match, so reds, greens, and brand colors come out exact.
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) {
            streamConfig.captureResolution = .best
        }
        if configuration.recordsSystemAudio {
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }
        return streamConfig
    }

    // MARK: – While recording

    private func firstFrameArrived(at hostTime: Double) {
        guard isRecording || isFinishing else { return }
        timeline.start(at: hostTime)
        // Re-anchor cursor/click metadata so its timestamps line up with the
        // video timeline (t=0 = first frame).
        metadataRecorder?.alignStart(to: hostTime)
        updateRecoveryNoteCameraOffset()
    }

    private func cameraFirstFrameArrived(at hostTime: Double) {
        cameraFirstFrameHostTime = hostTime
        updateRecoveryNoteCameraOffset()
    }

    /// Once both first frames are known, a crash can still reattach the camera.
    private func updateRecoveryNoteCameraOffset() {
        guard var note = recoveryNote, note.cameraOffset == nil,
              let cameraStart = cameraFirstFrameHostTime, let screenStart = timeline.origin else { return }
        note.cameraOffset = cameraStart - screenStart
        recoveryNote = note
        RecordingRecovery.save(note)
    }

    private func startMonitoring() {
        lastMicrophoneSampleAt = CACurrentMediaTime()
        let monitor = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitorTick() }
        }
        RunLoop.main.add(monitor, forMode: .common)
        monitorTimer = monitor
        if followedWindow != nil {
            let follow = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followWindow() }
            }
            RunLoop.main.add(follow, forMode: .common)
            followTimer = follow
        }
    }

    private func stopMonitoring() {
        RecordingStopHotkey.unregister()
        monitorTimer?.invalidate()
        monitorTimer = nil
        followTimer?.invalidate()
        followTimer = nil
        ownWindowObservers.forEach(NotificationCenter.default.removeObserver)
        ownWindowObservers.removeAll()
        filterUpdateWorkItem?.cancel()
        filterUpdateWorkItem = nil
        CameraCapture.shared.interruptionHandler = nil
        microphone?.eventHandler = nil
        if let displaySleepActivity {
            ProcessInfo.processInfo.endActivity(displaySleepActivity)
        }
        displaySleepActivity = nil
    }

    /// Whether the recording currently keeps the display awake (for tests).
    var isPreventingDisplaySleep: Bool { displaySleepActivity != nil }

    private func monitorTick() {
        guard isRecording else { return }
        checkDiskSpace()
        checkMicrophone()
    }

    private func checkDiskSpace() {
        guard let url = outputURL,
              let available = RecordingDiskSpace.availableCapacity(at: url.deletingLastPathComponent()) else { return }
        if available < RecordingDiskSpace.stopThreshold(bytesPerSecond: bytesPerSecond) {
            requestStop(.diskFull)
        } else if !didWarnLowDiskSpace, available < RecordingDiskSpace.warningThreshold(bytesPerSecond: bytesPerSecond) {
            didWarnLowDiskSpace = true
            warn(hud: "Disk almost full", toast: "Your disk is almost full. In about a minute the recording stops and saves itself.")
        }
    }

    /// A connected microphone delivers buffers even in silence; none for
    /// two seconds means it's gone.
    private func checkMicrophone() {
        guard configuration.recordsMicrophone, microphoneInput != nil else { return }
        let silent = microphone?.device == nil || CACurrentMediaTime() - lastMicrophoneSampleAt > 2
        hud?.setMicrophoneSilent(silent)
    }

    private func microphoneChanged(_ event: RecordingMicrophone.Event) {
        guard isRecording else { return }
        switch event {
        case .switched(let name):
            warn(hud: "Mic switched", toast: "Microphone disconnected. Now recording from \(name).")
        case .lost:
            warn(hud: "Mic disconnected", toast: "Microphone disconnected. The recording continues without it.")
        case .failed:
            warn(hud: "Mic stopped", toast: "The microphone stopped working. The recording continues without it.")
        }
    }

    private func cameraInterrupted(_ interruption: CameraCapture.Interruption) {
        guard isRecording, recordsCamera else { return }
        switch interruption {
        case .disconnected:
            warn(hud: "Camera disconnected", toast: "Camera disconnected. The recording continues without it.")
        case .failed:
            warn(hud: "Camera stopped", toast: "The camera stopped. The recording continues without it.")
        }
    }

    /// A short note in the HUD and the full story in a toast — both kept
    /// out of the video.
    private func warn(hud text: String, toast message: String) {
        guard isRecording else { return }
        hud?.showWarning(text)
        ToastWindow.show(message: message, duration: 4, on: recordingScreen)
    }

    /// Keeps Shotnix's windows out of a display recording as they come and
    /// go: the filter excludes the whole app (new windows included), and is
    /// rebuilt when one of its real windows — an editor — opens or closes.
    private func observeOwnWindows() {
        guard case .displayRect = source else { return }
        ownWindowsSignature = currentOwnWindowsSignature()
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        ownWindowObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFilterUpdate() }
            }
        }
        // A menu opened from one of Shotnix's own windows has to join the
        // video while it's still open: look right away, and again once its
        // window (and any submenu) is up.
        ownWindowObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleFilterUpdate(after: 0.05)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { self?.scheduleFilterUpdate(after: 0) }
                }
            }
        })
        ownWindowObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFilterUpdate() }
        })
    }

    private func currentOwnWindowsSignature() -> [CGWindowID] {
        // With the whole app excluded only the kept windows matter; without
        // it (no app entry to exclude), every window does.
        excludesOwnApp
            ? RecordingCaptureFilter.recordableOwnWindowIDs().sorted()
            : RecordingCaptureFilter.ownWindowsSignature()
    }

    private func scheduleFilterUpdate(after delay: TimeInterval = 0.15) {
        guard isRecording, filterUpdateWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.filterUpdateWorkItem = nil
                self?.updateFilterIfNeeded()
            }
        }
        filterUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateFilterIfNeeded() {
        guard isRecording, case .displayRect(_, let screen) = source, let stream else { return }
        let signature = currentOwnWindowsSignature()
        guard signature != ownWindowsSignature else { return }
        ownWindowsSignature = signature
        Task { @MainActor in
            guard let content = try? await Self.withTimeout(5, { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }),
                  self.isRecording,
                  let display = ScreenCoordinates.display(for: screen, in: content.displays) else { return }
            do {
                try await stream.updateContentFilter(RecordingCaptureFilter.displayFilter(display: display, content: content))
            } catch {
                print("[Shotnix] Recording filter update failed: \(error)")
            }
        }
    }

    /// A window recording follows its window: moved, the crop moves with
    /// it; resized, the window scales into the video; dragged to another
    /// display, the capture switches display. Pointer data follows too.
    private func followWindow() {
        guard isRecording, let window = followedWindow, let stream, let streamConfiguration else { return }
        guard let frame = Self.onScreenFrame(of: window.windowID) else {
            if !didWarnWindowClosed, !Self.windowExists(window.windowID) {
                didWarnWindowClosed = true
                warn(hud: "Window closed", toast: "The window you're recording closed. Stop when you're ready — the recording keeps going.")
            }
            return
        }
        guard frame != followedWindowFrame, frame.width >= 2, frame.height >= 2 else { return }
        followedWindowFrame = frame
        let appKitFrame = ScreenCoordinates.appKitRect(fromCG: frame)
        guard let screen = NSScreen.screenContaining(rect: appKitFrame) ?? recordingScreen,
              let display = ScreenCoordinates.display(for: screen, in: displays) else { return }
        if screen != recordingScreen {
            recordingScreen = screen
            stream.updateContentFilter(RecordingCaptureFilter.windowFilter(for: window, hiding: followedWindowHidden, on: display)) { error in
                if let error { print("[Shotnix] Recording display switch failed: \(error)") }
            }
        }
        let geometry = Self.captureGeometry(rect: appKitFrame, screenFrame: screen.frame, scale: screen.backingScaleFactor)
        streamConfiguration.sourceRect = geometry.sourceRect
        stream.updateConfiguration(streamConfiguration) { error in
            if let error { print("[Shotnix] Recording crop update failed: \(error)") }
        }
        let videoRect = Self.fittedVideoRect(
            sourceSize: CGSize(width: geometry.pixelWidth, height: geometry.pixelHeight),
            outputSize: outputPixelSize
        )
        metadataRecorder?.updateCapture(screenRect: geometry.capturedRect, videoRect: videoRect)
    }

    nonisolated static func windowExists(_ windowID: CGWindowID) -> Bool {
        !((CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]) ?? []).isEmpty
    }

    /// The window's current frame (CG space); nil while it's minimized,
    /// hidden or closed — the crop then stays where it was.
    nonisolated static func onScreenFrame(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    // MARK: – Finishing

    private func beginFinishing(_ reason: StopReason) {
        let now = CACurrentMediaTime()
        stopHostTime = now
        let discarding = reason.isDiscard
        // Duration is anchored to the first frame (video t=0), pauses cut
        // out, falling back to stream start if no frame ever arrived.
        let duration = timeline.hasStarted ? timeline.duration(at: now) : max(0, now - recordingStartedAt)
        let metadata = metadataRecorder?.finish(duration: duration)
        pendingRecordingMetadata = discarding ? nil : metadata
        pendingRecordingMetadata?.audioTracks = audioKinds.isEmpty ? nil : audioKinds
        metadataRecorder = nil
        if recordsCamera, !discarding {
            cameraFinishTask = Task { await CameraCapture.shared.finishRecording() }
        }
        isRecording = false
        isFinishing = true
        stopMonitoring()
        outline?.close()
        outline = nil
        if discarding {
            hud?.closeHUD()
            hud = nil
        } else {
            hud?.showSaving()
        }
        // Matches the old `!isFinishing` append guard: buffers arriving after
        // the user hits stop are dropped (queued ones still land first).
        let core = writerCore
        writerQueue.async { core.deactivate() }
        stateChangedHandler?()
    }

    private func finishRecording(reason: StopReason) {
        guard isFinishing else { return }
        microphone?.stop()
        microphone = nil
        let sessionID = UUID()
        finishSessionID = sessionID
        let stopHost = stopHostTime ?? CACurrentMediaTime()
        let screen = recordingScreen

        // Freeze-frame + hard stop for the delegate append paths. The sync
        // hop guarantees every already-queued buffer has landed and nothing
        // appends after markAsFinished below.
        let core = writerCore
        var activity: [Double] = []
        var droppedFrames = 0
        writerQueue.sync {
            let end = core.appendFinalStaticFrame(at: stopHost)
            core.padAudio(to: end)
            core.deactivate()
            activity = core.screenActivity
            droppedFrames = core.droppedFrameCount
        }
        if droppedFrames > 0 {
            print("[Shotnix] The encoder skipped \(droppedFrames) frames")
        }
        pendingRecordingMetadata?.screenActivity = activity

        guard let writer = assetWriter,
              let videoInput,
              let url = outputURL else {
            if let outputURL { RecordingRecovery.clear(ifFor: outputURL) }
            cleanup(releasingForeground: true)
            ToastWindow.show(message: "Recording failed before saving.", on: screen)
            finishCompleted()
            return
        }

        guard timeline.hasStarted else {
            // Not a single frame arrived (the display went dark, the capture
            // service stalled): there's nothing to save or salvage.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            RecordingRecovery.clear(ifFor: url)
            cleanup(releasingForeground: true)
            ToastWindow.show(message: "Nothing was recorded — the screen didn't send any picture. Try again.", duration: 4, on: screen)
            finishCompleted()
            return
        }

        guard writer.status == .writing else {
            salvage(url: url, writerError: writer.error)
            return
        }

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        let writerBox = AssetWriterBox(writer)
        scheduleSlowSaveNotices(sessionID: sessionID)
        writer.finishWriting { [weak self] in
            let writerStatus = writerBox.writer.status
            let writerError = writerBox.writer.error
            DispatchQueue.main.async {
                guard let self, self.finishSessionID == sessionID else { return }
                self.cancelSlowSaveNotices()
                let salvageCheck = self.salvagesNextSaveForTesting
                self.salvagesNextSaveForTesting = nil
                if writerStatus == .completed, writerError == nil, Self.fileHasContent(at: url), salvageCheck == nil {
                    self.completeSave(url: url, reason: reason)
                } else {
                    self.salvage(url: url, writerError: writerError, whileChecking: salvageCheck)
                }
            }
        }
    }

    private func completeSave(url: URL, reason: StopReason) {
        let cameraTask = takeCameraFinishTask()
        Task { @MainActor in
            let camera = await cameraTask?.value
            self.finalize(url: url, camera: camera, playable: nil, message: Self.finishedMessage(for: url, reason: reason))
        }
    }

    /// The writer failed before the file was finished — a full disk is the
    /// classic cause. The movie is written in fragments, so what reached
    /// the disk usually still plays: keep it rather than lose the take.
    private func salvage(url: URL, writerError: Error?, whileChecking: (() -> Void)? = nil) {
        if let writerError { print("[Shotnix] Recording finish failed: \(writerError)") }
        let cameraTask = takeCameraFinishTask()
        Task { @MainActor in
            let camera = await cameraTask?.value
            whileChecking?()
            let playable = await RecordingRecovery.playableDuration(of: url)
            guard let playable, playable > 0.2 else {
                self.discardUnplayableTake(url: url, camera: camera, writerError: writerError)
                return
            }
            let reason = Self.isDiskFull(writerError) ? "Your disk filled up" : "The recording couldn't be finished"
            self.finalize(url: url, camera: camera, playable: playable, message: "\(reason) — saved the first \(Self.durationText(playable)).")
        }
    }

    /// The camera movie finishes on its own; this take waits for it while
    /// still counting as saving, so a new take can't share the camera.
    private func takeCameraFinishTask() -> Task<CameraPipeline.Result?, Never>? {
        let task = cameraFinishTask
        cameraFinishTask = nil
        recordsCamera = false
        return task
    }

    /// Everything after the waiting, in one synchronous go: the editor data
    /// and the recovery note are settled before the engine goes idle, so a
    /// quit meanwhile waits for them and a queued take can't start early.
    private func finalize(url: URL, camera: CameraPipeline.Result?, playable: Double?, message: String) {
        var recordingMetadata = pendingRecordingMetadata
        if let playable, let recorded = recordingMetadata?.duration {
            recordingMetadata?.duration = min(recorded, playable)
        }
        Self.attach(camera: camera, screenStart: timeline.origin, to: &recordingMetadata)
        if let recordingMetadata {
            VideoDemoSidecarStore.save(recordingMetadata, for: url)
        }
        RecordingRecovery.clear(ifFor: url)
        let screen = recordingScreen
        let forTermination = endsForTermination
        // Decided once, here: the next take already on its way (its editor
        // would open over it) or the setting turned off during the save both
        // mean no editor — and then the hold Stop took goes back.
        let opensEditor = !forTermination && Settings.openVideoEditorAfterRecording && !isNextTakeQueued
        if opensEditor {
            // The editor ends the hold once it's in front.
            holdsForegroundForEditor = false
        } else {
            releaseEditorHold()
        }
        cleanup(releasingForeground: false)
        if forTermination {
            Settings.lastRecordingPath = url.path
        } else {
            ToastWindow.show(message: message, duration: playable == nil ? 3 : 4, on: screen)
            recordingFinishedHandler?(FinishedRecording(url: url, screen: screen, opensEditor: opensEditor))
        }
        finishCompleted()
    }

    private func discardUnplayableTake(url: URL, camera: CameraPipeline.Result?, writerError: Error?) {
        try? FileManager.default.removeItem(at: url)
        if let camera { try? FileManager.default.removeItem(at: camera.url) }
        RecordingRecovery.clear(ifFor: url)
        let screen = recordingScreen
        cleanup(releasingForeground: true)
        ToastWindow.show(message: Self.saveFailureMessage(for: writerError), duration: 4, on: screen)
        finishCompleted()
    }

    /// A take is on its way: its setup is open, or a start waits for this save.
    private var isNextTakeQueued: Bool {
        startIsWaitingForSave || (nextTakeInProgress?() ?? false)
    }

    private func releaseEditorHold() {
        guard holdsForegroundForEditor else { return }
        holdsForegroundForEditor = false
        ShotnixEditorActivation.releaseForeground()
    }

    private func finishDiscard() {
        guard isFinishing else { return }
        microphone?.stop()
        microphone = nil
        let core = writerCore
        writerQueue.sync { core.deactivate() }
        let screen = recordingScreen
        // cancelWriting deletes the file; the explicit remove covers a writer
        // that had already failed.
        if let writer = assetWriter, writer.status == .writing { writer.cancelWriting() }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            RecordingRecovery.clear(ifFor: url)
        }
        cleanup(releasingForeground: true)
        ToastWindow.show(message: "Recording discarded", on: screen)
        finishCompleted()
    }

    private func failStart(_ error: Error, url: URL?, writer: AVAssetWriter?, microphone: RecordingMicrophone?, screen: NSScreen) async {
        // A stop already under way cleans up (and deletes an empty file) itself.
        guard isRecording || !isFinishing else {
            print("[Shotnix] Recording start failed after stop: \(error)")
            return
        }
        // From here nothing else may start finishing this recording (a late
        // stream error, a stop shortcut) while the stream is torn down.
        isRecording = false
        isFinishing = true
        stopMonitoring()
        if let stream {
            let stopping = StreamBox(stream)
            try? await Self.withTimeout(5) { try await stopping.stream.stopCapture() }
        }
        microphone?.stop()
        // A recording that never started leaves nothing behind.
        if let writer, writer.status == .writing { writer.cancelWriting() }
        if let url {
            try? FileManager.default.removeItem(at: url)
            RecordingRecovery.clear(ifFor: url)
        }
        cleanup(releasingForeground: true)
        finishCompleted()
        ToastWindow.show(message: Self.startFailureMessage(for: error), duration: 4.5, on: screen)
        print("[Shotnix] Recording start failed: \(error)")
    }

    private static func attach(camera: CameraPipeline.Result?, screenStart: Double?, to metadata: inout VideoDemoRecordingMetadata?) {
        guard let camera else { return }
        guard let screenStart, metadata != nil else {
            try? FileManager.default.removeItem(at: camera.url)
            return
        }
        metadata?.webcam = VideoWebcamRecording(
            path: camera.url.path,
            offset: camera.firstFrameTime - screenStart,
            width: Double(camera.size.width),
            height: Double(camera.size.height)
        )
    }

    /// Quitting, logging out, or an update relaunch stops the recording and
    /// saves it first.
    private func registerForTermination() {
        AppTermination.end(terminationToken)
        terminationToken = AppTermination.begin("Saving the screen recording") { [weak self] done in
            guard let self else { return done() }
            self.terminationCallbacks.append(done)
            self.endsForTermination = true
            if self.isRecording {
                self.requestStop(.quit)
            } else if !self.isFinishing {
                self.finishCompleted()
            }
            // Already saving: `done` runs once the file is ready.
        }
    }

    private func finishCompleted() {
        AppTermination.end(terminationToken)
        terminationToken = nil
        endsForTermination = false
        let callbacks = terminationCallbacks
        terminationCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    /// A slow disk gets patience, never a cancel: cancelling deleted the file.
    private func scheduleSlowSaveNotices(sessionID: UUID) {
        cancelSlowSaveNotices()
        let screen = recordingScreen
        let notice = DispatchWorkItem { [weak self] in
            guard let self, self.finishSessionID == sessionID else { return }
            ToastWindow.show(message: "Still saving the recording…", duration: 3, on: screen)
        }
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.finishSessionID == sessionID else { return }
            // Quitting stops waiting after a while — the fragments already
            // on disk play — but the save itself keeps going.
            print("[Shotnix] Recording still saving after two minutes; quitting no longer waits")
            self.finishCompleted()
        }
        slowSaveWorkItems = [notice, release]
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: notice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: release)
    }

    private func cancelSlowSaveNotices() {
        slowSaveWorkItems.forEach { $0.cancel() }
        slowSaveWorkItems.removeAll()
    }

    /// ScreenCaptureKit calls can stall (a display going to sleep mid-call,
    /// a busy window server): give up after `seconds` rather than leave a
    /// recording that never starts or never saves.
    nonisolated private static func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T, onTimeout: @escaping @Sendable () -> Void = {}) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                do { once.resume(with: .success(try await operation())) } catch { once.resume(with: .failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                once.resume(with: .failure(RecordingError.timedOut))
            }
        }
    }

    /// Starts the stream, giving up after `seconds`. A start that finishes
    /// after that is stopped right away, so no stream keeps capturing the
    /// screen for a recording that was already abandoned.
    nonisolated private static func startCapture(_ box: StreamBox, within seconds: Double) async throws {
        let race = StartRace()
        try await withTimeout(seconds) {
            try await box.stream.startCapture()
            if race.finish() == .lost {
                try? await box.stream.stopCapture()
            }
        } onTimeout: {
            race.timeOut()
        }
    }

    private func waitUntilSaved(timeout: TimeInterval) async {
        let deadline = CACurrentMediaTime() + timeout
        while isFinishing, !isRecording, CACurrentMediaTime() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Writer inputs are added microphone first, then system audio.
    private var audioKinds: [VideoAudioKind] {
        var kinds: [VideoAudioKind] = []
        if microphoneInput != nil { kinds.append(.microphone) }
        if systemAudioInput != nil { kinds.append(.system) }
        return kinds
    }

    private func cleanup(releasingForeground: Bool) {
        cancelSlowSaveNotices()
        stopMonitoring()
        microphone?.stop()
        microphone = nil
        if let cameraFinishTask {
            // Failed after stop: the camera movie has no screen recording.
            self.cameraFinishTask = nil
            Task { @MainActor in
                if let camera = await cameraFinishTask.value { try? FileManager.default.removeItem(at: camera.url) }
                CameraCapture.shared.stop()
            }
        } else {
            if recordsCamera { CameraCapture.shared.cancelRecording() }
            // No-op while a camera movie is still finishing.
            CameraCapture.shared.stop()
        }
        recordsCamera = false
        cameraFirstFrameHostTime = nil
        recoveryNote = nil
        recordingSessionID = UUID()
        stream = nil
        streamOutput = nil
        streamConfiguration = nil
        assetWriter = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        outputURL = nil
        source = nil
        recordingScreen = nil
        displays = []
        followedWindow = nil
        followedWindowHidden = []
        followedWindowFrame = nil
        if let metadataRecorder {
            _ = metadataRecorder.finish(duration: 0)
        }
        metadataRecorder = nil
        pendingRecordingMetadata = nil
        timeline = RecordingTimeline()
        stopHostTime = nil
        let core = writerCore
        writerQueue.async { core.reset() }
        recordingStartedAt = 0
        isRecording = false
        isFinishing = false
        hud?.closeHUD()
        hud = nil
        outline?.close()
        outline = nil
        finishSessionID = UUID()
        if releasingForeground {
            // No editor is coming: don't leave a Dock icon behind.
            releaseEditorHold()
        }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        stateChangedHandler?()
    }

    // MARK: – Writer

    /// Fragments every 2 s: a crash, force quit or power loss leaves a movie
    /// that plays up to the last fragment instead of an unreadable file.
    /// Finishing still produces a regular MP4.
    nonisolated static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    nonisolated static func makeWriter(url: URL, format: RecordingVideoFormat, fps: Int, quality: RecordingQuality, microphone: Bool, systemAudio: Bool) throws -> WriterHandles {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = fragmentInterval
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(format: format, fps: fps, quality: quality))
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotAddWriterInput }
        writer.add(videoInput)

        var microphoneInput: AVAssetWriterInput?
        if microphone {
            let input = audioInput(channels: 1, bitrate: RecordingSizeEstimate.microphoneBitrate)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            microphoneInput = input
        }

        var systemAudioInput: AVAssetWriterInput?
        if systemAudio {
            let input = audioInput(channels: 2, bitrate: RecordingSizeEstimate.systemAudioBitrate)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            systemAudioInput = input
        }

        guard writer.startWriting() else {
            let error = writer.error
            try? FileManager.default.removeItem(at: url)
            throw error ?? RecordingError.cannotStartWriter
        }
        return WriterHandles(writer: writer, videoInput: videoInput, systemAudioInput: systemAudioInput, microphoneInput: microphoneInput)
    }

    nonisolated static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> [String: Any] {
        videoSettings(format: RecordingVideoFormat.plan(width: width, height: height, fps: fps), fps: fps, quality: quality)
    }

    nonisolated static func videoSettings(format: RecordingVideoFormat, fps: Int, quality: RecordingQuality) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality.bitrate(width: format.width, height: format.height, fps: fps, codec: format.codec),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoQualityKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,
        ]
        switch format.codec {
        case .h264:
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: format.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            AVVideoCompressionPropertiesKey: compression,
            // Without explicit colors the encoder guessed and shifted them
            // (pure red came back as 234,0,2); tagged HD colors round-trip.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        ]
    }

    nonisolated private static func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: – Messages

    /// Says what actually went wrong instead of blaming permissions.
    static func startFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if let recordingError = error as? RecordingError {
            switch recordingError {
            case .noDisplay: return "That display isn't available anymore."
            case .windowGone: return "That window closed before recording could start."
            case .cannotAddWriterInput, .cannotStartWriter: return "Couldn't create the video file."
            case .timedOut: return "Screen recording didn't start in time. Try again."
            }
        }
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case SCStreamError.userDeclined.rawValue:
                return "Shotnix isn't allowed to record the screen. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording."
            case SCStreamError.noDisplayList.rawValue, SCStreamError.noWindowList.rawValue, SCStreamError.noCaptureSource.rawValue:
                return "That display or window isn't available anymore."
            case SCStreamError.failedToStartAudioCapture.rawValue:
                return "System audio couldn't be recorded. Try again without system audio."
            default:
                break
            }
        }
        if isDiskFull(error) {
            return "Not enough disk space to record."
        }
        if isWriteDenied(error) {
            return "Shotnix can't write to the save folder. Choose another one in Settings → Screenshots."
        }
        return "Could not start recording (\(nsError.localizedDescription))."
    }

    static func saveFailureMessage(for error: Error?) -> String {
        if isDiskFull(error) { return "Your disk is full, so the recording couldn't be saved." }
        if let error { return "Could not save the recording (\((error as NSError).localizedDescription))." }
        return "Could not save the recording."
    }

    static func finishedMessage(for url: URL, reason: StopReason) -> String {
        switch reason {
        case .streamError:
            // Stream died (display disconnect, sleep, revoked permission) but
            // the writer finalized a playable file.
            return "Recording stopped early — saved what was captured."
        case .diskFull:
            return "Your disk is almost full, so the recording stopped. It's saved."
        default:
            return savedRecordingMessage(for: url)
        }
    }

    static func isDiskFull(_ error: Error?) -> Bool {
        var current = error.map { $0 as NSError }
        while let nsError = current {
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
                 (NSPOSIXErrorDomain, Int(ENOSPC)):
                return true
            default:
                current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return false
    }

    private static func isWriteDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                 (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError),
                 (NSPOSIXErrorDomain, Int(EACCES)),
                 (NSPOSIXErrorDomain, Int(EROFS)):
                return true
            default:
                current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return false
    }

    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total) s" : String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated private static func frameStatus(from rawValue: Any) -> SCFrameStatus? {
        if let status = rawValue as? SCFrameStatus { return status }
        if let raw = rawValue as? Int { return SCFrameStatus(rawValue: raw) }
        if let raw = rawValue as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) }
        return nil
    }

    nonisolated private static func microphoneLevel(from sampleBuffer: CMSampleBuffer) -> CGFloat {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData,
              bufferList.mBuffers.mDataByteSize > 0 else {
            return 0
        }

        let sampleCount: Int
        let sumSquares: Double
        if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let value = Double(sample)
                return partial + value * value
            }
        } else if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 64 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Double>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: sampleCount)
            sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        } else if streamDescription.mBitsPerChannel == 16 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + normalized * normalized
            }
        } else if streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int32.max)
                return partial + normalized * normalized
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(max(rms, 0.000_001))
        return CGFloat(max(0, min(1, (decibels + 55) / 45)))
    }

    private static func pixelScale(for filter: SCContentFilter, fallbackScreen screen: NSScreen) -> CGFloat {
        let fallbackScale = max(screen.backingScaleFactor, 1)
        if #available(macOS 14.0, *) {
            return max(CGFloat(filter.pointPixelScale), fallbackScale)
        }
        return fallbackScale
    }

    static func evenCeil(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    private static func fileHasContent(at url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private static func makeOutputURL() -> URL {
        let directory = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        let baseName = ImageExporter.timestampedName
        var url = directory.appendingPathComponent("\(baseName).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName) \(suffix).mp4")
            suffix += 1
        }
        return url
    }

    private static func savedRecordingMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        return "Saved to \(destination): \(url.lastPathComponent)"
    }

    enum StopReason {
        /// Stop button, menu bar, or a shortcut.
        case user
        /// Quit, logout, or an update relaunch.
        case quit
        /// The system's own "stop sharing" control.
        case systemStopped
        case diskFull
        case writerFailed
        case streamError(Error)
        case discard

        var isDiscard: Bool {
            if case .discard = self { return true }
            return false
        }
    }

    private enum RecordingSource {
        case displayRect(rect: CGRect, screen: NSScreen)
        case window(SCWindow, screen: NSScreen)

        var screen: NSScreen {
            switch self {
            case .displayRect(_, let screen), .window(_, let screen): screen
            }
        }

        /// AppKit-space area at start (the camera bubble sits in its corner).
        @MainActor
        var initialRect: CGRect {
            switch self {
            case .displayRect(let rect, _): rect
            case .window(let window, _): ScreenCoordinates.appKitRect(fromCG: window.frame)
            }
        }
    }

    private struct PreparedCaptureSource {
        let filter: SCContentFilter
        let streamConfig: SCStreamConfiguration
        let pixelWidth: Int
        let pixelHeight: Int
        let captureRect: CGRect
        let screen: NSScreen
        var window: SCWindow?
        var hiddenWindows: [SCWindow] = []
        var excludesOwnApp = true
    }

    enum RecordingError: Error {
        case noDisplay
        case windowGone
        case cannotAddWriterInput
        case cannotStartWriter
        case timedOut
    }
}

/// A saved take, handed to the app to open or announce.
struct FinishedRecording {
    let url: URL
    /// Where it was recorded: the panel shows up there.
    let screen: NSScreen?
    /// Open it in the editor now. False when the setting is off — or when
    /// the next take is already being set up, which the editor would cover.
    let opensEditor: Bool
}

/// SCStream crosses into the timeout helper's tasks; it's only used there
/// for the one start or stop call.
private struct StreamBox: @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
}

/// Who got there first: a stream's start or its deadline.
private final class StartRace: @unchecked Sendable {
    enum Outcome { case won, lost }
    private let lock = NSLock()
    private var timedOut = false
    private var finished = false

    func timeOut() {
        lock.lock()
        if !finished { timedOut = true }
        lock.unlock()
    }

    func finish() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return timedOut ? .lost : .won
    }
}

/// Resumes a continuation once, whichever of two racing tasks gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private struct RecordingConfiguration {
    var fps: Int
    var quality: RecordingQuality
    var showsCursor: Bool
    var editableCursor: Bool
    var recordsSystemAudio: Bool
    var recordsMicrophone: Bool
    var microphoneDeviceID: String
    var recordsCamera: Bool
    var cameraDeviceID: String

    /// The pointer goes into the video pixels only when the user wants it
    /// shown AND opted out of the editable cursor.
    var bakesCursorIntoVideo: Bool { showsCursor && !editableCursor }

    static var current: RecordingConfiguration {
        RecordingConfiguration(
            fps: Settings.recordingFPS,
            quality: RecordingQuality(rawValue: Settings.recordingQuality) ?? .high,
            showsCursor: Settings.recordingShowsCursor,
            editableCursor: Settings.recordingEditableCursor,
            recordsSystemAudio: Settings.recordingSystemAudio,
            recordsMicrophone: Settings.recordingMicrophone,
            microphoneDeviceID: Settings.recordingMicrophoneDeviceID,
            recordsCamera: Settings.recordingCamera,
            cameraDeviceID: Settings.recordingCameraDeviceID
        )
    }
}

enum RecordingQuality: String {
    case balanced
    case high
    case max

    var displayName: String {
        switch self {
        case .balanced: "Balanced"
        case .high: "High"
        case .max: "Max"
        }
    }

    var bitsPerPixelPerFrame: Double {
        switch self {
        case .balanced: 0.12
        case .high: 0.22
        case .max: 0.32
        }
    }

    /// At 30 fps; `bitrate(width:height:fps:codec:)` scales for frame rate.
    var minimumBitrate: Int {
        switch self {
        case .balanced: 6_000_000
        case .high: 12_000_000
        case .max: 20_000_000
        }
    }

    /// At 30 fps; `bitrate(width:height:fps:codec:)` scales for frame rate.
    var maximumBitrate: Int {
        switch self {
        case .balanced: 40_000_000
        case .high: 80_000_000
        case .max: 120_000_000
        }
    }
}

private final class AssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    private weak var recordingEngine: RecordingEngine?

    init(recordingEngine: RecordingEngine) {
        self.recordingEngine = recordingEngine
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            recordingEngine?.processScreenSampleBuffer(sampleBuffer)
        case .audio:
            recordingEngine?.processSystemAudioSampleBuffer(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordingEngine?.streamDidStopWithError(error)
    }
}

private final class MicrophoneCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private weak var recordingEngine: RecordingEngine?

    init(recordingEngine: RecordingEngine) {
        self.recordingEngine = recordingEngine
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordingEngine?.processMicrophoneSampleBuffer(sampleBuffer)
    }
}
