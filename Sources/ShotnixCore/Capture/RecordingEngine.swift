import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class RecordingEngine: NSObject {

    private let writerQueue = DispatchQueue(label: "com.shotnix.recording.writer", qos: .userInitiated)
    /// All per-buffer append state lives here, confined to writerQueue —
    /// see RecordingWriterCore. The engine keeps only lifecycle state.
    private let writerCore = RecordingWriterCore()
    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var microphoneDelegate: MicrophoneCaptureDelegate?
    private var outputURL: URL?
    /// Main-actor mirror of the core's first-frame anchor, set via the
    /// onFirstFrame hop — used for the HUD-facing duration in beginFinishing.
    private var firstFrameWallClockTime: CFTimeInterval = 0
    private var recordingStartedAt: CFTimeInterval = 0
    private var isRecording = false
    private var isFinishing = false
    private var finishSessionID = UUID()
    private var finishTimeoutWorkItem: DispatchWorkItem?
    private var hud: RecordingHUDWindow?
    private var configuration = RecordingConfiguration.current
    private var metadataRecorder: VideoDemoRecordingMetadataRecorder?
    private var pendingRecordingMetadata: VideoDemoRecordingMetadata?
    /// Host-clock seconds of the first screen frame (video t=0) — the camera
    /// movie is aligned against it.
    private var screenFirstFrameHostTime: Double?
    private var recordsCamera = false
    private var cameraFinishTask: Task<CameraPipeline.Result?, Never>?

    var recordingFinishedHandler: ((URL) -> Void)?
    /// Fired on every recording lifecycle transition (started, finishing,
    /// fully stopped) — drives the menu bar recording indicator.
    var stateChangedHandler: (() -> Void)?
    var active: Bool { isRecording || isFinishing }
    var elapsedSeconds: TimeInterval? {
        isRecording && recordingStartedAt > 0 ? CACurrentMediaTime() - recordingStartedAt : nil
    }

    func startRecording(rect: CGRect, on screen: NSScreen) async {
        await startRecording(source: .displayRect(rect: rect, screen: screen))
    }

    func startRecording(window: SCWindow, on screen: NSScreen) async {
        await startRecording(source: .window(window, screen: screen))
    }

    private func startRecording(source: RecordingSource) async {
        guard !active else {
            ToastWindow.show(message: "Recording already in progress")
            return
        }

        guard Self.destinationHasSufficientDiskSpace() else {
            ToastWindow.show(message: "Not enough free disk space to record.")
            return
        }

        var configuration = RecordingConfiguration.current
        if configuration.recordsMicrophone {
            let canUseMicrophone = await requestMicrophonePermissionIfNeeded()
            if !canUseMicrophone {
                configuration.recordsMicrophone = false
                ToastWindow.show(message: "Mic unavailable. Recording without it.")
            }
        }

        do {
            let hud = RecordingHUDWindow()
            hud.configure(
                systemAudio: configuration.recordsSystemAudio,
                microphone: configuration.recordsMicrophone,
                fps: configuration.fps,
                quality: configuration.quality.displayName
            )
            hud.stopHandler = { [weak self] in self?.stopRecording() }
            self.hud = hud
            hud.show(on: source.screen)

            if configuration.recordsCamera {
                let around: CGRect
                switch source {
                case .displayRect(let rect, _): around = rect
                case .window(let window, _): around = ScreenCoordinates.appKitRect(fromCG: window.frame)
                }
                if !(await CameraCapture.shared.start(deviceID: configuration.cameraDeviceID, around: around, on: source.screen)) {
                    configuration.recordsCamera = false
                    ToastWindow.show(message: "Camera unavailable. Recording without it.")
                }
            } else {
                CameraCapture.shared.stop()
            }

            // The HUD and the camera bubble are never part of the video.
            let excludedWindowNumbers = source.usesDisplayFilter
                ? ([CGWindowID(hud.windowNumber)] + [CameraCapture.shared.bubbleWindowNumber].compactMap { $0 }).filter { $0 > 0 }
                : []
            let prepared = try await prepareStream(
                source: source,
                configuration: configuration,
                excludingWindowNumbers: excludedWindowNumbers
            )
            stream = prepared.stream
            streamOutput = prepared.output
            assetWriter = prepared.writer
            videoInput = prepared.videoInput
            systemAudioInput = prepared.systemAudioInput
            microphoneInput = prepared.microphoneInput
            outputURL = prepared.url
            self.configuration = configuration
            let metadataRecorder = VideoDemoRecordingMetadataRecorder(
                videoURL: prepared.url,
                captureRect: prepared.captureRect,
                sourcePixelSize: CGSize(width: prepared.pixelWidth, height: prepared.pixelHeight),
                fps: configuration.fps,
                nativeCursorVisible: configuration.bakesCursorIntoVideo,
                renderCursor: configuration.showsCursor && !configuration.bakesCursorIntoVideo,
                recordsKeystrokes: Settings.recordingKeystrokes
            )
            self.metadataRecorder = metadataRecorder
            firstFrameWallClockTime = 0
            isFinishing = false
            isRecording = true
            recordingStartedAt = CACurrentMediaTime()
            metadataRecorder.start()
            stateChangedHandler?()

            // Arm the queue-confined writer core before any buffer can arrive
            // (the stream hasn't started yet; the serial queue preserves order).
            let core = writerCore
            let handles = WriterHandles(
                writer: prepared.writer,
                videoInput: prepared.videoInput,
                systemAudioInput: prepared.systemAudioInput,
                microphoneInput: prepared.microphoneInput
            )
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
            let onFirstFrame: (CFTimeInterval, Double) -> Void = { [weak self] wallClock, hostTime in
                Task { @MainActor in
                    guard let self else { return }
                    self.firstFrameWallClockTime = wallClock
                    self.screenFirstFrameHostTime = hostTime
                    // Re-anchor cursor/click metadata so its timestamps line
                    // up with the video timeline (t=0 = first appended frame).
                    self.metadataRecorder?.alignStart(to: wallClock)
                }
            }
            let onWriterFailure: () -> Void = { [weak self] in
                Task { @MainActor in
                    self?.handleWriterFailure()
                }
            }
            writerQueue.async {
                core.begin(
                    writer: handles.writer,
                    videoInput: handles.videoInput,
                    systemAudioInput: handles.systemAudioInput,
                    microphoneInput: handles.microphoneInput,
                    frameDuration: frameDuration,
                    onFirstFrame: onFirstFrame,
                    onWriterFailure: onWriterFailure
                )
            }

            if configuration.recordsMicrophone {
                try startMicrophoneCapture(deviceID: configuration.microphoneDeviceID)
            }
            screenFirstFrameHostTime = nil
            cameraFinishTask = nil
            recordsCamera = configuration.recordsCamera
            if recordsCamera {
                CameraCapture.shared.beginRecording(to: CameraCapture.movieURL(for: prepared.url))
            }
            try await prepared.stream.startCapture()
            ToastWindow.show(message: "Recording started")
        } catch {
            if let stream {
                try? await stream.stopCapture()
            }
            cleanup()
            ToastWindow.show(message: "Could not start recording. Check permissions.")
            print("[Shotnix] Recording start failed: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording, !isFinishing else { return }
        // The user just acted — the one moment macOS lets Shotnix take
        // focus. Keep it until the editor opens, or the editor would open
        // behind the app that was being recorded.
        if Settings.openVideoEditorAfterRecording {
            ShotnixEditorActivation.holdForeground()
        }
        beginFinishing()

        let streamToStop = stream
        let outputToRemove = streamOutput
        Task {
            do {
                try await streamToStop?.stopCapture()
            } catch {
                print("[Shotnix] Recording stop failed: \(error)")
            }
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            finishRecording(error: nil)
        }
    }

    fileprivate nonisolated func streamDidStopWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, !self.isFinishing else { return }
            self.beginFinishing()
            self.finishRecording(error: error)
        }
    }

    // These run on writerQueue (SCStream and the mic delegate deliver there)
    // and append directly via the queue-confined core — no per-buffer
    // main-actor hop. Only the tiny mic-level float crosses to the HUD.

    fileprivate nonisolated func processScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status],
              Self.frameStatus(from: rawStatus) == .complete else {
            return
        }
        writerCore.appendVideo(sampleBuffer)
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
            self?.hud?.updateMicrophoneLevel(level)
        }
    }

    private func prepareStream(
        source: RecordingSource,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> (
        stream: SCStream,
        output: RecordingStreamOutput,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?,
        url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        captureRect: CGRect
    ) {
        let preparedSource = try await prepareCaptureSource(source, configuration: configuration, excludingWindowNumbers: excludingWindowNumbers)

        let output = RecordingStreamOutput(recordingEngine: self)
        let stream = SCStream(filter: preparedSource.filter, configuration: preparedSource.streamConfig, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writerQueue)
        if configuration.recordsSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writerQueue)
        }

        let url = Self.makeOutputURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                width: preparedSource.pixelWidth,
                height: preparedSource.pixelHeight,
                fps: configuration.fps,
                quality: configuration.quality
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotAddWriterInput }
        writer.add(videoInput)

        var microphoneInput: AVAssetWriterInput?
        if configuration.recordsMicrophone {
            let input = Self.audioInput(channels: 1, bitrate: 128_000)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            microphoneInput = input
        }

        var systemAudioInput: AVAssetWriterInput?
        if configuration.recordsSystemAudio {
            let input = Self.audioInput(channels: 2, bitrate: 192_000)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            systemAudioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStartWriter }

        return (
            stream,
            output,
            writer,
            videoInput,
            systemAudioInput,
            microphoneInput,
            url,
            preparedSource.pixelWidth,
            preparedSource.pixelHeight,
            preparedSource.captureRect
        )
    }

    private func prepareCaptureSource(
        _ source: RecordingSource,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        switch source {
        case .displayRect(let rect, let screen):
            return try await prepareDisplaySource(
                rect: rect,
                on: screen,
                configuration: configuration,
                excludingWindowNumbers: excludingWindowNumbers
            )
        case .window(let window, let screen):
            return try await prepareWindowDisplaySource(
                window: window,
                on: screen,
                configuration: configuration
            )
        }
    }

    private func prepareWindowDisplaySource(
        window: SCWindow,
        on screen: NSScreen,
        configuration: RecordingConfiguration
    ) async throws -> PreparedCaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let selectedWindow = content.windows.first { $0.windowID == window.windowID } ?? window
        // SCWindow.frame and SCDisplay.frame are both CG-space (top-left
        // origin), so pick the display showing the largest share of the window.
        guard let display = Self.display(mostOverlapping: selectedWindow.frame, in: content.displays)
                ?? ScreenCoordinates.display(for: screen, in: content.displays) else {
            throw RecordingError.noDisplay
        }
        // The sourceRect math in prepareDisplaySource is relative to the
        // NSScreen, so it must be the screen backing the display we filter on.
        let targetScreen = NSScreen.screens.first { $0.displayID == display.displayID } ?? screen
        let appKitRect = ScreenCoordinates.appKitRect(fromCG: selectedWindow.frame)

        let filter = SCContentFilter(display: display, including: [selectedWindow])
        return prepareDisplaySource(
            rect: appKitRect,
            on: targetScreen,
            configuration: configuration,
            filter: filter
        )
    }

    private static func display(mostOverlapping cgRect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays
            .map { (display: $0, overlap: $0.frame.intersection(cgRect)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .display
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // `rect` is AppKit-space while SCDisplay frames are CG-space —
        // match the display by ID, never by cross-space geometry.
        guard let display = ScreenCoordinates.display(for: screen, in: content.displays) else {
            throw RecordingError.noDisplay
        }
        let excludedWindows = excludingWindowNumbers.compactMap { windowNumber in
            content.windows.first { CGWindowID($0.windowID) == windowNumber }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        return prepareDisplaySource(
            rect: rect,
            on: screen,
            configuration: configuration,
            filter: filter
        )
    }

    private func prepareDisplaySource(
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
            captureRect: geometry.capturedRect
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

    private static func streamConfiguration(width: Int, height: Int, configuration: RecordingConfiguration) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.queueDepth = 8
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

    /// The writer entered .failed mid-recording (disk full is the classic cause).
    /// Stop immediately so the user gets feedback instead of a dead HUD timer.
    private func handleWriterFailure() {
        guard isRecording, !isFinishing else { return }
        beginFinishing()

        let streamToStop = stream
        let outputToRemove = streamOutput
        let writerError = assetWriter?.error
        Task {
            do {
                try await streamToStop?.stopCapture()
            } catch {
                print("[Shotnix] Recording stop failed: \(error)")
            }
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            finishRecording(error: writerError)
        }
    }

    private func finishRecording(error: Error?) {
        guard isFinishing else { return }
        stopMicrophoneCapture()
        let sessionID = UUID()
        finishSessionID = sessionID

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Freeze-frame + hard stop for the delegate append paths. The
            // sync hop guarantees every already-queued buffer has landed and
            // nothing appends after markAsFinished below.
            let core = self.writerCore
            self.writerQueue.sync {
                core.appendFinalStaticFrame()
                core.deactivate()
            }

            guard let writer = self.assetWriter,
                  let videoInput = self.videoInput,
                  let url = self.outputURL else {
                self.cleanup()
                ToastWindow.show(message: "Recording failed before saving.")
                return
            }

            guard writer.status == .writing else {
                // Writer already failed (e.g. disk full) — finishWriting would throw.
                let writerError = writer.error
                self.cleanup()
                ToastWindow.show(message: "Could not save recording.")
                if let writerError { print("[Shotnix] Recording finish failed: \(writerError)") }
                return
            }

            videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.microphoneInput?.markAsFinished()

            let writerBox = AssetWriterBox(writer)
            self.scheduleFinishTimeout(sessionID: sessionID, url: url)
            writer.finishWriting { [weak self] in
                let writerStatus = writerBox.writer.status
                let writerError = writerBox.writer.error
                DispatchQueue.main.async {
                    guard let self, self.finishSessionID == sessionID else { return }
                    self.cancelFinishTimeout()
                    var recordingMetadata = self.pendingRecordingMetadata
                    let cameraTask = self.cameraFinishTask
                    let screenStart = self.screenFirstFrameHostTime
                    // The camera movie is finishing on its own — cleanup must not abandon it.
                    self.cameraFinishTask = nil
                    self.recordsCamera = false
                    self.cleanup()
                    Task { @MainActor in
                        let camera = await cameraTask?.value
                        CameraCapture.shared.stop()
                        if writerStatus == .completed, writerError == nil, Self.fileHasContent(at: url) {
                            if let camera, let screenStart {
                                recordingMetadata?.webcam = VideoWebcamRecording(
                                    path: camera.url.path,
                                    offset: camera.firstFrameTime - screenStart,
                                    width: Double(camera.size.width),
                                    height: Double(camera.size.height)
                                )
                            } else if let camera {
                                try? FileManager.default.removeItem(at: camera.url)
                            }
                            if let recordingMetadata {
                                VideoDemoSidecarStore.save(recordingMetadata, for: url)
                            }
                            if let error {
                                // Stream died (display disconnect, sleep, revoked permission)
                                // but the writer finalized a playable file — salvage it.
                                ToastWindow.show(message: "Recording stopped early — saved what was captured.", duration: 3.0)
                                print("[Shotnix] Recording stream error: \(error)")
                            } else {
                                ToastWindow.show(message: Self.savedRecordingMessage(for: url), duration: 3.0)
                            }
                            self.recordingFinishedHandler?(url)
                        } else {
                            ShotnixEditorActivation.releaseForeground()
                            if let camera { try? FileManager.default.removeItem(at: camera.url) }
                            if let error {
                                ToastWindow.show(message: "Recording stopped unexpectedly.")
                                print("[Shotnix] Recording stream error: \(error)")
                            } else {
                                ToastWindow.show(message: "Could not save recording.")
                                if let writerError { print("[Shotnix] Recording finish failed: \(writerError)") }
                            }
                        }
                    }
                }
            }
        }
    }

    private func beginFinishing() {
        // Duration is anchored to the first appended frame (video t=0), falling
        // back to stream start if no frame ever arrived.
        let anchor = firstFrameWallClockTime > 0 ? firstFrameWallClockTime : recordingStartedAt
        let elapsed = anchor > 0 ? CACurrentMediaTime() - anchor : 0
        pendingRecordingMetadata = metadataRecorder?.finish(duration: elapsed)
        // Writer inputs are added microphone first, then system audio.
        var audioKinds: [VideoAudioKind] = []
        if microphoneInput != nil { audioKinds.append(.microphone) }
        if systemAudioInput != nil { audioKinds.append(.system) }
        pendingRecordingMetadata?.audioTracks = audioKinds.isEmpty ? nil : audioKinds
        metadataRecorder = nil
        if recordsCamera {
            cameraFinishTask = Task { await CameraCapture.shared.finishRecording() }
        }
        isRecording = false
        isFinishing = true
        hud?.closeHUD()
        hud = nil
        // Matches the old `!isFinishing` append guard: buffers arriving after
        // the user hits stop are dropped (queued ones still land first).
        let core = writerCore
        writerQueue.async { core.deactivate() }
        stateChangedHandler?()
    }

    private func scheduleFinishTimeout(sessionID: UUID, url: URL) {
        cancelFinishTimeout()

        let timeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.finishSessionID == sessionID else { return }
                self.assetWriter?.cancelWriting()
                self.cleanup()
                ToastWindow.show(message: "Could not save recording.")
                print("[Shotnix] Recording finish timed out for \(url.path)")
            }
        }
        finishTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func cancelFinishTimeout() {
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
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

    private func startMicrophoneCapture(deviceID: String) throws {
        guard let device = Self.microphoneDevice(for: deviceID) else { throw RecordingError.noMicrophone }
        let session = AVCaptureSession()
        session.beginConfiguration()

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw RecordingError.cannotAddMicrophoneInput }
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        let delegate = MicrophoneCaptureDelegate(recordingEngine: self)
        audioOutput.setSampleBufferDelegate(delegate, queue: writerQueue)
        guard session.canAddOutput(audioOutput) else { throw RecordingError.cannotAddMicrophoneInput }
        session.addOutput(audioOutput)
        session.commitConfiguration()
        session.startRunning()

        microphoneSession = session
        microphoneOutput = audioOutput
        microphoneDelegate = delegate
    }

    private func stopMicrophoneCapture() {
        microphoneSession?.stopRunning()
        microphoneSession = nil
        microphoneOutput = nil
        microphoneDelegate = nil
    }

    private func cleanup() {
        cancelFinishTimeout()
        stopMicrophoneCapture()
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
        screenFirstFrameHostTime = nil
        stream = nil
        streamOutput = nil
        assetWriter = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        outputURL = nil
        if let metadataRecorder {
            _ = metadataRecorder.finish(duration: 0)
        }
        metadataRecorder = nil
        pendingRecordingMetadata = nil
        firstFrameWallClockTime = 0
        let core = writerCore
        writerQueue.async { core.reset() }
        recordingStartedAt = 0
        isRecording = false
        isFinishing = false
        hud?.closeHUD()
        hud = nil
        finishSessionID = UUID()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        stateChangedHandler?()
    }

    static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: width, height: height, fps: fps, quality: quality),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoQualityKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            // Without explicit colors the encoder guessed and shifted them
            // (pure red came back as 234,0,2); tagged HD colors round-trip.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        ]
    }

    private static func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func bitrate(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> Int {
        let pixels = Double(max(width, 1) * max(height, 1))
        let raw = pixels * Double(max(fps, 1)) * quality.bitsPerPixelPerFrame
        return min(max(Int(raw.rounded()), quality.minimumBitrate), quality.maximumBitrate)
    }

    nonisolated private static func frameStatus(from rawValue: Any) -> SCFrameStatus? {
        if let status = rawValue as? SCFrameStatus { return status }
        if let raw = rawValue as? Int { return SCFrameStatus(rawValue: raw) }
        if let raw = rawValue as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) }
        return nil
    }

    private static func microphoneDevice(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
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

    /// Refuse to start below this so the writer doesn't fail mid-recording on a full disk.
    private static let minimumFreeDiskSpace: Int64 = 500 * 1_024 * 1_024

    private static func destinationHasSufficientDiskSpace() -> Bool {
        let directory = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        guard let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else {
            // If the capacity query fails, let the writer surface the real error.
            return true
        }
        return capacity >= minimumFreeDiskSpace
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

    private enum RecordingSource {
        case displayRect(rect: CGRect, screen: NSScreen)
        case window(SCWindow, screen: NSScreen)

        var screen: NSScreen {
            switch self {
            case .displayRect(_, let screen), .window(_, let screen): screen
            }
        }

        var usesDisplayFilter: Bool {
            switch self {
            case .displayRect, .window: true
            }
        }
    }

    private struct PreparedCaptureSource {
        let filter: SCContentFilter
        let streamConfig: SCStreamConfiguration
        let pixelWidth: Int
        let pixelHeight: Int
        let captureRect: CGRect
    }

    private enum RecordingError: Error {
        case noDisplay
        case noMicrophone
        case cannotAddWriterInput
        case cannotStartWriter
        case cannotAddMicrophoneInput
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

    var minimumBitrate: Int {
        switch self {
        case .balanced: 6_000_000
        case .high: 12_000_000
        case .max: 20_000_000
        }
    }

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

private enum RecordingAudioTarget {
    case system
    case microphone
}

/// Carries the writer + inputs across the writerQueue boundary once, at
/// recording start. AVAssetWriter/-Input aren't Sendable, but after this
/// hand-off they're only ever touched on the writer queue (appends) plus the
/// engine's finish flow, which synchronizes via `writerQueue.sync` first.
private struct WriterHandles: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let systemAudioInput: AVAssetWriterInput?
    let microphoneInput: AVAssetWriterInput?
}

/// Per-buffer writer state, confined to the recording writer queue — the same
/// serial queue SCStream and the microphone delegate already deliver on, so
/// appends run right where the samples arrive. The previous design hopped
/// every buffer (up to 60fps of full-resolution frames) to the main actor,
/// which backed frames up and starved SCK's buffer pool whenever the main
/// thread was busy (opening the menu to stop, hovering UI).
///
/// `@unchecked Sendable`: every member is documented queue-confined — the
/// main actor talks to it only via `writerQueue.async`/`sync`.
private final class RecordingWriterCore: @unchecked Sendable {

    /// ~3 seconds of audio buffers (≈47 buffers/sec at 48 kHz / 1024 frames)
    /// kept per track while waiting for the first video frame.
    private static let maximumPendingAudioSamples = 150

    // All state below is touched ONLY on the writer queue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var frameDuration = CMTime(value: 1, timescale: 30)
    private var firstPresentationTime: CMTime?
    private var firstFrameWallClockTime: CFTimeInterval = 0
    private var lastPresentationTime: CMTime?
    private var lastCompleteSampleBuffer: CMSampleBuffer?
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    private var droppedPendingAudioSampleCount = 0
    private var isActive = false
    private var onFirstFrame: ((CFTimeInterval, Double) -> Void)?
    private var onWriterFailure: (() -> Void)?

    func begin(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?,
        frameDuration: CMTime,
        onFirstFrame: @escaping (CFTimeInterval, Double) -> Void,
        onWriterFailure: @escaping () -> Void
    ) {
        reset()
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        self.frameDuration = frameDuration
        self.onFirstFrame = onFirstFrame
        self.onWriterFailure = onWriterFailure
        isActive = true
    }

    /// Stops accepting delegate-path buffers. Serial-queue ordering guarantees
    /// nothing appends after a caller has seen this take effect via `sync`.
    func deactivate() {
        isActive = false
    }

    func reset() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        firstPresentationTime = nil
        firstFrameWallClockTime = 0
        lastPresentationTime = nil
        lastCompleteSampleBuffer = nil
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.removeAll()
        droppedPendingAudioSampleCount = 0
        isActive = false
        onFirstFrame = nil
        onWriterFailure = nil
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isActive, let writer, let input = videoInput else { return }

        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        if firstPresentationTime == nil {
            firstPresentationTime = sourcePresentationTime
            firstFrameWallClockTime = CACurrentMediaTime()
            // Video t=0 is this frame, not stream start — the engine re-anchors
            // cursor/click metadata to this wall-clock time on the main actor.
            writer.startSession(atSourceTime: .zero)
            onFirstFrame?(firstFrameWallClockTime, sourcePresentationTime.seconds)
            flushPendingAudioSamples()
        }

        guard let firstPresentationTime else { return }
        let relativePresentationTime = CMTimeSubtract(sourcePresentationTime, firstPresentationTime)
        guard relativePresentationTime >= .zero else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let retimed = Self.copy(sampleBuffer: sampleBuffer, presentationTime: relativePresentationTime, duration: frameDuration) else { return }

        if input.append(retimed) {
            lastPresentationTime = relativePresentationTime
            lastCompleteSampleBuffer = sampleBuffer
        } else if let error = writer.error {
            print("[Shotnix] Asset writer append failed: \(error)")
            if writer.status == .failed {
                onWriterFailure?()
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, to target: RecordingAudioTarget) {
        guard isActive else { return }
        guard firstPresentationTime != nil else {
            switch target {
            case .system:
                pendingSystemAudioSamples.append(sampleBuffer)
                if pendingSystemAudioSamples.count > Self.maximumPendingAudioSamples {
                    pendingSystemAudioSamples.removeFirst()
                    droppedPendingAudioSampleCount += 1
                }
            case .microphone:
                pendingMicrophoneSamples.append(sampleBuffer)
                if pendingMicrophoneSamples.count > Self.maximumPendingAudioSamples {
                    pendingMicrophoneSamples.removeFirst()
                    droppedPendingAudioSampleCount += 1
                }
            }
            return
        }
        appendReadyAudioSample(sampleBuffer, to: target)
    }

    /// The freeze-frame appended at stop so the video runs to the moment the
    /// user hit stop. Explicit call from the finish flow — works after
    /// `deactivate()`, which only gates the delegate paths.
    func appendFinalStaticFrame() {
        guard let input = videoInput,
              input.isReadyForMoreMediaData,
              firstFrameWallClockTime > 0,
              let lastSampleBuffer = lastCompleteSampleBuffer else { return }
        // Video t=0 is the first appended frame, so the final PTS must be
        // measured from the same anchor — not from stream start.
        let elapsed = CACurrentMediaTime() - firstFrameWallClockTime
        let finalPresentationTime = CMTime(seconds: max(elapsed, 0), preferredTimescale: 600)
        let last = lastPresentationTime ?? .zero
        guard finalPresentationTime > CMTimeAdd(last, frameDuration) else { return }
        guard let retimed = Self.copy(sampleBuffer: lastSampleBuffer, presentationTime: finalPresentationTime, duration: frameDuration) else { return }
        _ = input.append(retimed)
    }

    private func flushPendingAudioSamples() {
        if droppedPendingAudioSampleCount > 0 {
            print("[Shotnix] Dropped \(droppedPendingAudioSampleCount) audio sample buffers while waiting for the first video frame")
            droppedPendingAudioSampleCount = 0
        }
        pendingSystemAudioSamples.forEach { appendReadyAudioSample($0, to: .system) }
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.forEach { appendReadyAudioSample($0, to: .microphone) }
        pendingMicrophoneSamples.removeAll()
    }

    private func appendReadyAudioSample(_ sampleBuffer: CMSampleBuffer, to target: RecordingAudioTarget) {
        let input: AVAssetWriterInput? = switch target {
        case .system: systemAudioInput
        case .microphone: microphoneInput
        }
        guard let input, input.isReadyForMoreMediaData,
              let firstPresentationTime else { return }
        let relative = CMTimeSubtract(sampleBuffer.presentationTimeStamp, firstPresentationTime)
        let presentationTime = relative >= .zero ? relative : .zero
        guard let retimed = Self.copy(sampleBuffer: sampleBuffer, presentationTime: presentationTime, duration: sampleBuffer.duration) else { return }
        _ = input.append(retimed)
    }

    private static func copy(sampleBuffer: CMSampleBuffer, presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration.isValid ? duration : .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        )
        guard status == noErr else { return nil }
        return copied
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
