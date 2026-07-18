import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class RecordingEngine: NSObject {

    private let writerQueue = DispatchQueue(label: "com.shotnix.recording.writer", qos: .userInitiated)
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
    private var firstPresentationTime: CMTime?
    private var firstFrameWallClockTime: CFTimeInterval = 0
    private var lastPresentationTime: CMTime?
    private var lastCompleteSampleBuffer: CMSampleBuffer?
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    private var droppedPendingAudioSampleCount = 0
    private var recordingStartedAt: CFTimeInterval = 0
    private var isRecording = false
    private var isFinishing = false
    private var finishSessionID = UUID()
    private var finishTimeoutWorkItem: DispatchWorkItem?
    private var hud: RecordingHUDWindow?
    private var configuration = RecordingConfiguration.current
    private var metadataRecorder: VideoDemoRecordingMetadataRecorder?
    private var pendingRecordingMetadata: VideoDemoRecordingMetadata?

    var recordingFinishedHandler: ((URL) -> Void)?
    var active: Bool { isRecording || isFinishing }

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

            let excludedWindowNumbers = source.usesDisplayFilter ? [CGWindowID(hud.windowNumber)].filter { $0 > 0 } : []
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
                nativeCursorVisible: configuration.showsCursor
            )
            self.metadataRecorder = metadataRecorder
            resetTimingState()
            isFinishing = false
            isRecording = true
            recordingStartedAt = CACurrentMediaTime()
            metadataRecorder.start()

            if configuration.recordsMicrophone {
                try startMicrophoneCapture(deviceID: configuration.microphoneDeviceID)
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

    fileprivate nonisolated func processScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status],
              Self.frameStatus(from: rawStatus) == .complete else {
            return
        }

        Task { @MainActor [weak self] in
            self?.appendCompleteFrame(sampleBuffer)
        }
    }

    fileprivate nonisolated func processSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.appendAudioSample(sampleBuffer, to: .system)
        }
    }

    fileprivate nonisolated func processMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let level = Self.microphoneLevel(from: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.hud?.updateMicrophoneLevel(level)
            self?.appendAudioSample(sampleBuffer, to: .microphone)
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
        let appKitRect = Self.appKitRect(fromScreenCaptureKitWindowFrame: selectedWindow.frame, on: screen)
        guard let display = content.displays.first(where: { $0.frame.intersects(selectedWindow.frame) }) ?? content.displays.first else {
            throw RecordingError.noDisplay
        }

        let filter = SCContentFilter(display: display, including: [selectedWindow])
        return prepareDisplaySource(
            rect: appKitRect,
            on: screen,
            configuration: configuration,
            filter: filter
        )
    }

    private static func appKitRect(fromScreenCaptureKitWindowFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: frame.minX,
            y: screen.frame.origin.y + screen.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first else {
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
        let originX = floor((rect.origin.x - screen.frame.origin.x) * scale) / scale
        let originY = floor((rect.origin.y - screen.frame.origin.y) * scale) / scale
        let width = ceil(rect.width * scale) / scale
        let height = ceil(rect.height * scale) / scale
        let sourceRect = CGRect(
            x: originX,
            y: screen.frame.height - originY - height,
            width: width,
            height: height
        )

        let pixelWidth = max(2, Self.evenCeil(Int(ceil(width * scale))))
        let pixelHeight = max(2, Self.evenCeil(Int(ceil(height * scale))))
        let streamConfig = Self.streamConfiguration(width: pixelWidth, height: pixelHeight, configuration: configuration)
        streamConfig.sourceRect = sourceRect

        return PreparedCaptureSource(
            filter: filter,
            streamConfig: streamConfig,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            captureRect: rect
        )
    }

    private static func streamConfiguration(width: Int, height: Int, configuration: RecordingConfiguration) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.queueDepth = 8
        streamConfig.showsCursor = configuration.showsCursor
        streamConfig.scalesToFit = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
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

    private func appendCompleteFrame(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, let writer = assetWriter, let input = videoInput else { return }

        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        if firstPresentationTime == nil {
            firstPresentationTime = sourcePresentationTime
            firstFrameWallClockTime = CACurrentMediaTime()
            // Video t=0 is this frame, not stream start — re-anchor cursor/click
            // metadata so its timestamps line up with the video timeline.
            metadataRecorder?.alignStart(to: firstFrameWallClockTime)
            writer.startSession(atSourceTime: .zero)
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
                handleWriterFailure()
            }
        }
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

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer, to target: AudioTarget) {
        guard !isFinishing else { return }
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

    private func appendReadyAudioSample(_ sampleBuffer: CMSampleBuffer, to target: AudioTarget) {
        let input: AVAssetWriterInput? = switch target {
        case .system: systemAudioInput
        case .microphone: microphoneInput
        }
        guard let input, input.isReadyForMoreMediaData,
              let presentationTime = relativeAudioPresentationTime(for: sampleBuffer),
              let retimed = Self.copy(sampleBuffer: sampleBuffer, presentationTime: presentationTime, duration: sampleBuffer.duration) else { return }
        _ = input.append(retimed)
    }

    private func relativeAudioPresentationTime(for sampleBuffer: CMSampleBuffer) -> CMTime? {
        guard let firstPresentationTime else { return nil }
        let relative = CMTimeSubtract(sampleBuffer.presentationTimeStamp, firstPresentationTime)
        return relative >= .zero ? relative : .zero
    }

    private func finishRecording(error: Error?) {
        guard isFinishing else { return }
        stopMicrophoneCapture()
        let sessionID = UUID()
        finishSessionID = sessionID

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendFinalStaticFrameIfNeeded()

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
                    let recordingMetadata = self.pendingRecordingMetadata
                    self.cleanup()
                    if writerStatus == .completed, writerError == nil, Self.fileHasContent(at: url) {
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
                    } else if let error {
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

    private func beginFinishing() {
        // Duration is anchored to the first appended frame (video t=0), falling
        // back to stream start if no frame ever arrived.
        let anchor = firstFrameWallClockTime > 0 ? firstFrameWallClockTime : recordingStartedAt
        let elapsed = anchor > 0 ? CACurrentMediaTime() - anchor : 0
        pendingRecordingMetadata = metadataRecorder?.finish(duration: elapsed)
        metadataRecorder = nil
        isRecording = false
        isFinishing = true
        hud?.closeHUD()
        hud = nil
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

    private func appendFinalStaticFrameIfNeeded() {
        guard let input = videoInput,
              input.isReadyForMoreMediaData,
              firstFrameWallClockTime > 0,
              let lastSampleBuffer = lastCompleteSampleBuffer else { return }
        // Video t=0 is the first appended frame, so the final PTS must be
        // measured from the same anchor — not from stream start.
        let elapsed = CACurrentMediaTime() - firstFrameWallClockTime
        let finalPresentationTime = CMTime(seconds: max(elapsed, 0), preferredTimescale: 600)
        let minimumStep = frameDuration
        let last = lastPresentationTime ?? .zero
        guard finalPresentationTime > CMTimeAdd(last, minimumStep) else { return }
        guard let retimed = Self.copy(sampleBuffer: lastSampleBuffer, presentationTime: finalPresentationTime, duration: frameDuration) else { return }
        _ = input.append(retimed)
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
        resetTimingState()
        recordingStartedAt = 0
        isRecording = false
        isFinishing = false
        hud?.closeHUD()
        hud = nil
        finishSessionID = UUID()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    private func resetTimingState() {
        firstPresentationTime = nil
        firstFrameWallClockTime = 0
        lastPresentationTime = nil
        lastCompleteSampleBuffer = nil
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.removeAll()
        droppedPendingAudioSampleCount = 0
    }

    private var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
    }

    private static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> [String: Any] {
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

    private static func evenCeil(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    /// ~3 seconds of audio buffers (≈47 buffers/sec at 48 kHz / 1024 frames)
    /// kept per track while waiting for the first video frame.
    private static let maximumPendingAudioSamples = 150

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

    private enum AudioTarget {
        case system
        case microphone
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
    var recordsSystemAudio: Bool
    var recordsMicrophone: Bool
    var microphoneDeviceID: String

    static var current: RecordingConfiguration {
        RecordingConfiguration(
            fps: Settings.recordingFPS,
            quality: RecordingQuality(rawValue: Settings.recordingQuality) ?? .high,
            showsCursor: Settings.recordingShowsCursor,
            recordsSystemAudio: Settings.recordingSystemAudio,
            recordsMicrophone: Settings.recordingMicrophone,
            microphoneDeviceID: Settings.recordingMicrophoneDeviceID
        )
    }
}

private enum RecordingQuality: String {
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
