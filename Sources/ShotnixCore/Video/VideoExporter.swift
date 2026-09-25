import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct VideoDemoMetadata: Equatable {
    let duration: Double
    let sourceSize: CGSize
    let fps: Double
}

/// Renders the edited video: reads the cut/retimed recording frame by
/// frame, composes every frame with the SAME renderer the preview uses,
/// and encodes with the hardware encoder (H.264/HEVC) — or writes a GIF.
enum VideoDemoExporter {
    static let endCardDuration = 2.0

    static func metadata(for sourceURL: URL) async throws -> VideoDemoMetadata {
        let source = try await VideoSourceTracks.load(url: sourceURL)
        return VideoDemoMetadata(duration: source.duration, sourceSize: source.size, fps: source.frameRate)
    }

    /// Returns non-fatal warnings.
    @discardableResult
    static func export(
        project inputProject: VideoDemoProject,
        recording: VideoDemoRecordingMetadata? = nil,
        destinationURL: URL,
        settings: VideoExportSettings = VideoExportSettings(),
        progress: @escaping @Sendable (Double) async -> Void = { _ in },
        shouldCancel: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> [String] {
        let source = try await VideoSourceTracks.load(url: inputProject.sourceURL)
        var project = inputProject
        project.sourceWidth = Double(source.size.width)
        project.sourceHeight = Double(source.size.height)
        let segments = project.timelineSegments(totalDuration: source.duration)
        guard !segments.isEmpty else { throw VideoDemoExportError.invalidTrim }

        var camera: VideoCameraSource?
        if let webcam = recording?.webcam, project.webcam.visible {
            camera = await VideoCameraSource.load(webcam)
        }
        let kinds = VideoAudioKind.resolve(recorded: recording?.audioTracks, channelCounts: source.audioChannelCounts)
        let audioSources = await VideoAudioSource.resolved(from: source, kinds: kinds, enhanceVoice: project.audio.enhanceVoice)
        let edit = try VideoCompositionBuilder.build(
            source: source,
            segments: segments,
            audio: project.audio,
            camera: camera,
            audioSources: audioSources,
            // A fully muted export has no sound track at all.
            includeAudio: !project.audio.isSilent(kinds: kinds)
        )
        let plan = makePlan(project: project, sourceDuration: source.duration, recording: recording, hasWebcam: edit.cameraTrack != nil)
        let canvas = plan.outputCanvasSize
        let outputSize = settings.outputSize(canvas: canvas)
        let timelineDuration = edit.duration.seconds

        let cancel = CancellationFlag()
        let watcher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if await shouldCancel() {
                    cancel.set()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { watcher.cancel() }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotnix-export-\(UUID().uuidString)")
            .appendingPathExtension(settings.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let warnings: [String]
        if settings.format == .gif {
            try await writeGIF(
                edit: edit,
                plan: plan,
                outputSize: outputSize,
                fps: Double(settings.gifFPS),
                duration: timelineDuration,
                to: temporaryURL,
                cancel: cancel,
                progress: progress
            )
            warnings = []
        } else {
            warnings = try await writeMovie(
                edit: edit,
                plan: plan,
                project: project,
                settings: settings,
                outputSize: outputSize,
                duration: timelineDuration,
                to: temporaryURL,
                cancel: cancel,
                progress: progress
            )
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        await progress(1)
        return warnings
    }

    static func makePlan(project: VideoDemoProject, sourceDuration: Double, recording: VideoDemoRecordingMetadata?, hasWebcam: Bool = false) -> VideoRenderPlan {
        let artwork = VideoCursorArtwork(metadata: recording)
        let cursorTrack = VideoCursorTrack.build(
            samples: project.cursorSamples,
            clicks: project.clickEvents,
            smoothing: project.cursor.smoothing,
            hideWhenIdle: project.cursor.hideWhenIdle,
            tidyEnding: project.cursor.tidyEnding,
            crop: project.crop.normalized,
            duration: sourceDuration
        )
        let layoutProject = project.reframeActive ? project.reframeScene() : project
        let canvas = layoutProject.canvasSize()
        let stage = layoutProject.stageRect(in: canvas)
        let normalizedStage = CGRect(
            x: stage.minX / canvas.width,
            y: stage.minY / canvas.height,
            width: stage.width / canvas.width,
            height: stage.height / canvas.height
        )
        let segments = project.timelineSegments(totalDuration: sourceDuration)
        let camera = VideoCameraTrack.build(
            regions: project.zoomRegions,
            segments: segments,
            timelineDuration: segments.last?.timelineEnd ?? 0,
            speed: project.zoomSpeed,
            stage: normalizedStage,
            crop: project.crop.normalized,
            cursor: cursorTrack.map { track in { track.visiblePosition(at: $0) } }
        )
        let outputCanvas = project.canvasSize()
        var reframe: VideoReframe?
        if project.reframeActive,
           let fraction = VideoReframe.windowFraction(outputAspect: outputCanvas.width / max(outputCanvas.height, 1), sceneAspect: canvas.width / max(canvas.height, 1)) {
            reframe = VideoReframe.build(
                windowFraction: fraction,
                camera: camera,
                cursorTrack: cursorTrack,
                segments: segments,
                canvas: canvas,
                stage: stage,
                crop: project.crop.normalized,
                duration: segments.last?.timelineEnd ?? 0
            )
        }
        return VideoRenderPlan(
            project: layoutProject,
            sourceDuration: sourceDuration,
            artwork: artwork,
            pointPixelScale: recording?.pointPixelScale,
            cursorTrack: cursorTrack,
            camera: camera,
            hasWebcam: hasWebcam,
            outputCanvasSize: outputCanvas,
            reframe: reframe
        )
    }

    /// Reader output for the edit: the screen alone, or screen + camera
    /// through the pass-through compositor (camera frames land in `store`).
    fileprivate static func videoOutput(for edit: VideoEditComposition, frameRate: Double, store: VideoCameraFrameStore, settings: [String: Any]) -> AVAssetReaderVideoCompositionOutput {
        if let cameraTrack = edit.cameraTrack,
           let composition = VideoCameraComposition.videoComposition(for: edit, frameRate: frameRate, store: store) {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [edit.videoTrack, cameraTrack], videoSettings: settings)
            output.videoComposition = composition
            return output
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [edit.videoTrack], videoSettings: settings)
        output.videoComposition = VideoCompositionBuilder.readerVideoComposition(for: edit, frameRate: frameRate)
        return output
    }

    // MARK: MP4

    private static func writeMovie(
        edit: VideoEditComposition,
        plan: VideoRenderPlan,
        project: VideoDemoProject,
        settings: VideoExportSettings,
        outputSize: CGSize,
        duration: Double,
        to url: URL,
        cancel: CancellationFlag,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> [String] {
        let fps = Double(settings.fps)
        let reader = try AVAssetReader(asset: edit.composition)
        let cameraStore = VideoCameraFrameStore(capacity: 48)
        cameraStore.setFindsPerson(plan.webcam?.needsPersonMask ?? false)
        let videoOutput = videoOutput(for: edit, frameRate: fps, store: cameraStore, settings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoDemoExportError.exportFailed("Could not read the recording.") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !edit.audioTracks.isEmpty {
            // Float, so a mix that adds up past full scale (voice over the
            // computer's sound) isn't clipped before the loudness gain.
            let output = AVAssetReaderAudioMixOutput(audioTracks: edit.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = edit.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // Even loudness: measure the final mix once, then apply one gain.
        var audioGain = 1.0
        if audioOutput != nil, project.audio.normalizeLoudness {
            audioGain = try await measureLoudnessGain(edit: edit, cancel: cancel)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate(for: outputSize),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(videoInput) else { throw VideoDemoExportError.exportFailed("Could not configure the video encoder.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Could not read the recording.")
        }
        guard writer.startWriting() else {
            throw VideoDemoExportError.exportFailed(writer.error?.localizedDescription ?? "Could not write the video.")
        }
        writer.startSession(atSourceTime: .zero)

        let job = MovieJob(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            adaptor: adaptor,
            audioOutput: audioOutput,
            audioInput: audioInput,
            audioGain: audioGain,
            plan: plan,
            cameraStore: edit.cameraTrack == nil ? nil : cameraStore,
            outputSize: outputSize,
            fps: fps,
            duration: duration,
            endCard: settings.endCard ? EndCard(background: project.background) : nil,
            cancel: cancel,
            progress: progress
        )
        try await job.run()
        return job.warnings
    }

    private struct EndCard {
        let background: VideoBackground
    }

    /// Reads the edit's final mix once to find the gain that lands it at
    /// −16 LUFS without letting peaks pass −1 dBFS.
    private static func measureLoudnessGain(edit: VideoEditComposition, cancel: CancellationFlag) async throws -> Double {
        guard !edit.audioTracks.isEmpty else { return 1 }
        let reader = try AVAssetReader(asset: edit.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: edit.audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = edit.audioMix
        output.audioTimePitchAlgorithm = .spectral
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return 1 }
        reader.add(output)
        guard reader.startReading() else { return 1 }
        let meter = VideoLoudnessMeter(channels: 2, sampleRate: 48_000)
        while let sample = output.copyNextSampleBuffer() {
            if cancel.isSet {
                reader.cancelReading()
                throw VideoDemoExportError.cancelled
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                meter.add(interleaved: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        return meter.gain()
    }

    /// Owns the reader→render→writer loop. Video and audio are pumped on
    /// their own queues, the way AVAssetWriter wants to be fed.
    private final class MovieJob: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoOutput: AVAssetReaderVideoCompositionOutput
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioOutput: AVAssetReaderAudioMixOutput?
        let audioInput: AVAssetWriterInput?
        let audioGain: Double
        let plan: VideoRenderPlan
        let cameraStore: VideoCameraFrameStore?
        let outputSize: CGSize
        let fps: Double
        let duration: Double
        let endCard: EndCard?
        let cancel: CancellationFlag
        let progress: @Sendable (Double) async -> Void
        private(set) var warnings: [String] = []

        private let renderer = VideoFrameRenderer()
        private let context = VideoRenderContext.makeContext()
        /// Frames are rendered in sRGB — exactly what the preview shows —
        /// and tagged so; the encoder converts them to HD video colors.
        /// (Rendering straight into Rec.709 used the camera curve, which
        /// players don't undo: mid-tones came out ~7% lighter.)
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private let videoQueue = DispatchQueue(label: "com.shotnix.export.video", qos: .userInitiated)
        private let audioQueue = DispatchQueue(label: "com.shotnix.export.audio", qos: .userInitiated)
        private var lastFrame: CIImage?
        private var cardBase: CIImage?
        private var lastTime: CMTime = .zero
        private var endCardFrame = 0
        private var videoDone = false
        private var lastReported = -1.0

        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            videoOutput: AVAssetReaderVideoCompositionOutput,
            videoInput: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            audioOutput: AVAssetReaderAudioMixOutput?,
            audioInput: AVAssetWriterInput?,
            audioGain: Double,
            plan: VideoRenderPlan,
            cameraStore: VideoCameraFrameStore?,
            outputSize: CGSize,
            fps: Double,
            duration: Double,
            endCard: EndCard?,
            cancel: CancellationFlag,
            progress: @escaping @Sendable (Double) async -> Void
        ) {
            self.reader = reader
            self.writer = writer
            self.videoOutput = videoOutput
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.audioOutput = audioOutput
            self.audioInput = audioInput
            self.audioGain = audioGain
            self.plan = plan
            self.cameraStore = cameraStore
            self.outputSize = outputSize
            self.fps = fps
            self.duration = duration
            self.endCard = endCard
            self.cancel = cancel
            self.progress = progress
        }

        func run() async throws {
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                while videoInput.isReadyForMoreMediaData {
                    if cancel.isSet {
                        finishVideo(group)
                        return
                    }
                    if !videoDone {
                        if !appendNextFrame() {
                            videoDone = true
                            if endCard == nil {
                                finishVideo(group)
                                return
                            }
                        }
                    } else if let card = endCard, appendEndCardFrame(card) {
                        continue
                    } else {
                        finishVideo(group)
                        return
                    }
                }
            }

            if let audioOutput, let audioInput {
                group.enter()
                var finished = false
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    guard !finished else { return }
                    while audioInput.isReadyForMoreMediaData {
                        if self.cancel.isSet {
                            finished = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        guard let raw = audioOutput.copyNextSampleBuffer() else {
                            finished = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        let sample = VideoAudioGain.apply(self.audioGain, to: raw) ?? raw
                        if !audioInput.append(sample) {
                            finished = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume()
                }
            }

            if cancel.isSet {
                reader.cancelReading()
                writer.cancelWriting()
                throw VideoDemoExportError.cancelled
            }
            if reader.status == .failed {
                writer.cancelWriting()
                throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Reading the recording failed.")
            }
            await writer.finishWriting()
            if writer.status != .completed {
                throw VideoDemoExportError.exportFailed(writer.error?.localizedDescription ?? "Writing the video failed.")
            }
        }

        private var videoFinished = false

        private func finishVideo(_ group: DispatchGroup) {
            guard !videoFinished else { return }
            videoFinished = true
            videoInput.markAsFinished()
            group.leave()
        }

        /// Output frames run on their OWN clock (n / fps): the latest
        /// source frame is held while the camera, cursor, and effects keep
        /// moving — a 30fps recording exports genuinely smooth 60fps motion.
        private var outputIndex = 0
        private var currentSample: CMSampleBuffer?
        private var pendingSample: CMSampleBuffer?
        private var lastCameraFrame: VideoCameraFrame?
        private var sourceFinished = false

        /// Returns false when the timeline is exhausted.
        private func appendNextFrame() -> Bool {
            let timescale = CMTimeScale(max(Int(fps.rounded()), 1))
            let time = CMTime(value: CMTimeValue(outputIndex), timescale: timescale)
            let seconds = time.seconds
            guard seconds < duration - 0.0005 else { return false }

            while true {
                if pendingSample == nil, !sourceFinished {
                    pendingSample = videoOutput.copyNextSampleBuffer()
                    if pendingSample == nil { sourceFinished = true }
                }
                guard let next = pendingSample,
                      CMSampleBufferGetPresentationTimeStamp(next).seconds <= seconds + 0.0005 else { break }
                currentSample = next
                pendingSample = nil
            }
            if currentSample == nil, let first = pendingSample {
                // Before the first source frame: show it early rather than black.
                currentSample = first
            }

            let source = currentSample.flatMap { CMSampleBufferGetImageBuffer($0) }.map { CIImage(cvPixelBuffer: $0) }
            var options = VideoFrameRenderer.Options(frameRate: fps)
            if let cameraStore, let sample = currentSample {
                if let frame = cameraStore.camera(at: CMSampleBufferGetPresentationTimeStamp(sample).seconds, tolerance: 0.02) {
                    lastCameraFrame = frame
                }
                options.webcamFrame = lastCameraFrame?.image
                options.webcamMask = lastCameraFrame?.mask
            }
            let image = renderer.render(
                source: source,
                timelineTime: seconds,
                plan: plan,
                outputSize: outputSize,
                options: options
            )
            if append(image, at: time) {
                lastFrame = image
                lastTime = time
            }
            outputIndex += 1
            report(seconds / max(duration + (endCard == nil ? 0 : VideoDemoExporter.endCardDuration), 0.001))
            return true
        }

        /// Returns false when the card is complete.
        private func appendEndCardFrame(_ card: EndCard) -> Bool {
            let total = Int((VideoDemoExporter.endCardDuration * fps).rounded())
            guard endCardFrame < total else { return false }
            endCardFrame += 1
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(Int(fps.rounded()), 1)))
            let time = lastTime + CMTimeMultiply(frameDuration, multiplier: Int32(endCardFrame))
            let progressInCard = Double(endCardFrame) / Double(max(total, 1))
            let fade = min(Double(endCardFrame) / (0.4 * fps), 1)
            if cardBase == nil {
                cardBase = VideoEndCard.base(size: outputSize, background: card.background, context: context)
            }
            let cardImage = VideoEndCard.image(base: cardBase!, size: outputSize, appear: progressInCard)
            var frame = cardImage
            if let last = lastFrame, fade < 1 {
                frame = cardImage.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: cardImage,
                    kCIInputImageKey: last,
                    kCIInputTimeKey: VideoCameraEasing.glide(fade),
                ])
            }
            _ = append(frame, at: time)
            report((duration + progressInCard * VideoDemoExporter.endCardDuration) / (duration + VideoDemoExporter.endCardDuration))
            return true
        }

        private func append(_ image: CIImage, at time: CMTime) -> Bool {
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: colorSpace)
            return adaptor.append(buffer, withPresentationTime: time)
        }

        private func report(_ value: Double) {
            let clamped = min(max(value, 0), 0.995)
            guard clamped - lastReported >= 0.004 else { return }
            lastReported = clamped
            let progress = self.progress
            Task { await progress(clamped) }
        }
    }

    // MARK: GIF

    private static func writeGIF(
        edit: VideoEditComposition,
        plan: VideoRenderPlan,
        outputSize: CGSize,
        fps: Double,
        duration: Double,
        to url: URL,
        cancel: CancellationFlag,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: edit.composition)
        let cameraStore = VideoCameraFrameStore(capacity: 48)
        cameraStore.setFindsPerson(plan.webcam?.needsPersonMask ?? false)
        let output = videoOutput(for: edit, frameRate: fps, store: cameraStore, settings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        var lastCameraFrame: VideoCameraFrame?
        guard reader.canAdd(output) else { throw VideoDemoExportError.exportFailed("Could not read frames for the GIF.") }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Could not read frames for the GIF.")
        }

        // The reader delivers a frame for every started 1/fps (a partial last
        // one included). A GIF refuses to finish with more frames than it
        // declared, so declare the upper bound (fewer is fine).
        let estimated = max(Int((duration * fps).rounded(.up)) + 1, 1)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, estimated, nil) else {
            throw VideoDemoExportError.exportFailed("Could not create the GIF file.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / fps
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay,
                kCGImagePropertyGIFDelayTime: delay,
            ],
        ] as CFDictionary

        let renderer = VideoFrameRenderer()
        let context = VideoRenderContext.makeContext()
        let rect = CGRect(origin: .zero, size: outputSize)
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            if cancel.isSet {
                reader.cancelReading()
                throw VideoDemoExportError.cancelled
            }
            guard written < estimated, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var options = VideoFrameRenderer.Options(frameRate: fps)
            if edit.cameraTrack != nil {
                if let frame = cameraStore.camera(at: time, tolerance: 0.02) { lastCameraFrame = frame }
                options.webcamFrame = lastCameraFrame?.image
                options.webcamMask = lastCameraFrame?.mask
            }
            let image = renderer.render(
                source: CIImage(cvPixelBuffer: pixelBuffer),
                timelineTime: time,
                plan: plan,
                outputSize: outputSize,
                options: options
            )
            guard let cgImage = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { continue }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
            written += 1
            if written.isMultiple(of: 4) {
                await progress(min(Double(written) / Double(estimated), 0.99))
            }
        }
        if reader.status == .failed {
            throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Could not read frames for the GIF.")
        }
        guard written > 0, CGImageDestinationFinalize(destination) else {
            throw VideoDemoExportError.exportFailed("Could not write the GIF.")
        }
    }
}

/// Thread-safe one-way flag.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// "Made with Shotnix" outro, drawn on the project's own background.
enum VideoEndCard {
    /// The blurred, dimmed backdrop — rasterized once per export.
    static func base(size: CGSize, background: VideoBackground, context: CIContext) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let blurred = VideoBackgroundRenderer.image(for: background, blur: 0.6, size: size)
        let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: rect)
        let image = dim.composited(over: blurred).cropped(to: rect)
        if let cgImage = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            return CIImage(cgImage: cgImage)
        }
        return image
    }

    static func image(base: CIImage, size: CGSize, appear: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var image = base
        if let overlay = overlay(size: size, appear: appear) {
            image = overlay.composited(over: image)
        }
        return image.cropped(to: rect)
    }

    private static func overlay(size: CGSize, appear: Double) -> CIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let unit = min(size.width, size.height) / 1080
        let rise = CGFloat(1 - VideoCameraEasing.spring(min(appear * 2.4, 1))) * 24 * unit
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let iconSide = 132 * unit
        if let icon = NSImage(named: NSImage.applicationIconName) {
            let iconRect = CGRect(x: size.width / 2 - iconSide / 2, y: size.height / 2 + 6 * unit - rise, width: iconSide, height: iconSide)
            icon.draw(in: iconRect)
        }
        let title = NSAttributedString(string: "Made with Shotnix", attributes: [
            .font: NSFont.systemFont(ofSize: 54 * unit, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let titleSize = title.size()
        title.draw(at: CGPoint(x: size.width / 2 - titleSize.width / 2, y: size.height / 2 - 70 * unit - rise))
        let link = NSAttributedString(string: "shotnix.com — free & open source", attributes: [
            .font: NSFont.systemFont(ofSize: 26 * unit, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ])
        let linkSize = link.size()
        link.draw(at: CGPoint(x: size.width / 2 - linkSize.width / 2, y: size.height / 2 - 118 * unit - rise))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
