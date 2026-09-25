import AppKit
import AVFoundation
import SwiftUI

struct VideoTimelineThumbnail: Identifiable {
    let id = UUID()
    /// Source seconds.
    let time: Double
    let image: NSImage
}

/// Peak envelope of the recording's audio (all tracks mixed), in SOURCE time.
struct VideoWaveform {
    static let bucketsPerSecond = 50.0
    let peaks: [Float]

    func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty, end > start else { return 0 }
        let a = max(Int(start * Self.bucketsPerSecond), 0)
        let b = min(Int(end * Self.bucketsPerSecond) + 1, peaks.count)
        guard a < b else { return 0 }
        var value: Float = 0
        for index in a..<b { value = max(value, peaks[index]) }
        return value
    }
}

struct VideoDemoTimelineRange: Equatable, Identifiable {
    var id: String { "\(start)-\(end)" }
    var start: Double
    var end: Double

    var normalized: VideoDemoTimelineRange {
        VideoDemoTimelineRange(start: min(start, end), end: max(start, end))
    }

    var duration: Double { max(end - start, 0) }
}

/// Changes only when something DRAWN on the timeline changes (clips,
/// zooms, annotations, clicks, captions, shortcuts, selection, zoom level)
/// — style edits like padding or backgrounds never re-render its lanes.
@MainActor
final class VideoTimelineState: ObservableObject {
    @Published private(set) var revision = 0

    func bump() { revision &+= 1 }
}

struct VideoEditorNotice: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let symbol: String
}

@MainActor
final class VideoEditorModel: ObservableObject {
    enum Selection: Equatable {
        case none
        case zoom(UUID)
        case clip(UUID)
        case overlay(UUID)
        case click(UUID)
        case caption(UUID)
        case keystroke(UUID)
        case cameraLayout(UUID)
        case range(VideoDemoTimelineRange)
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case background
        case cursor
        case zoom
        case camera
        case captions
        case audio

        var id: String { rawValue }
        var title: String {
            switch self {
            case .background: return "Style"
            case .cursor: return "Cursor"
            case .zoom: return "Zoom"
            case .camera: return "Camera"
            case .captions: return "Script"
            case .audio: return "Audio"
            }
        }
        var help: String {
            switch self {
            case .background: return "Background, padding, corners, shadow"
            case .cursor: return "Cursor, clicks, and keyboard shortcuts"
            case .zoom: return "Zoom moves"
            case .camera: return "Camera bubble"
            case .captions: return "Edit the video by editing its words, and add captions"
            case .audio: return "Sound"
            }
        }
        var symbol: String {
            switch self {
            case .background: return "photo.on.rectangle.angled"
            case .cursor: return "cursorarrow.motionlines"
            case .zoom: return "plus.magnifyingglass"
            case .camera: return "person.crop.circle"
            case .captions: return "text.quote"
            case .audio: return "speaker.wave.2.fill"
            }
        }
    }

    enum ExportPhase: Equatable {
        case idle
        case running(progress: Double, started: Date, destination: URL, toClipboard: Bool)
        case finished(url: URL, bytes: Int64, copied: Bool)
        case failed(String)
    }

    // MARK: State

    @Published var project: VideoDemoProject {
        didSet { projectDidChange(from: oldValue) }
    }
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceFrameRate: Double = 60
    @Published private(set) var hasAudio = false
    /// The recording came with camera footage that's still on disk.
    @Published private(set) var hasWebcamFootage = false
    /// What each of the recording's audio tracks carries.
    @Published private(set) var audioKinds: [VideoAudioKind] = []
    /// Voice enhancement progress, 0…1 (nil when idle).
    @Published var voiceJob: Double?
    @Published var voiceError: String?
    var voiceTask: Task<Bool, Never>?
    @Published private(set) var isReady = false
    @Published var loadError: String?
    @Published var selection: Selection = .none {
        didSet {
            guard selection != oldValue else { return }
            previewRenderer.invalidate()
            refreshTimeline()
        }
    }
    @Published var inspectorTab: InspectorTab = .background
    @Published private(set) var isPlaying = false
    @Published var timelineZoom: Double = 1 {
        didSet { refreshTimeline() }
    }
    @Published var isCommandPalettePresented = false
    @Published var isExportPresented = false
    @Published var isShortcutsPresented = false
    @Published var exportSettings = VideoExportSettings.fromSettings
    @Published var exportPhase: ExportPhase = .idle
    @Published private(set) var thumbnails: [VideoTimelineThumbnail] = [] {
        didSet { refreshTimeline() }
    }
    @Published private(set) var waveform: VideoWaveform? {
        didSet { refreshTimeline() }
    }
    @Published var notice: VideoEditorNotice?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var restoredDraft = false
    /// While a clip edge is dragged the preview shows this SOURCE moment.
    @Published private(set) var trimPeekSourceTime: Double?
    /// While trimming, the timeline keeps its scale so the edge stays under
    /// the pointer instead of the whole strip re-fitting mid-drag.
    @Published private(set) var layoutDurationLock: Double? {
        didSet { refreshTimeline() }
    }
    /// Crop mode: the preview shows the whole recording with a crop frame.
    @Published var isCropping = false
    var cropBeforeEditing: VideoCropRect?
    var projectBeforeCrop: VideoDemoProject?
    var undoDepthBeforeCrop = 0
    /// Bumped to put the cursor in the selected text annotation's field
    /// (double-click the text on the preview).
    @Published var textEditRequest = 0
    @Published var cropAspect: VideoCropAspect = .free
    /// Caption generation in progress or failed (nil when idle).
    @Published var captionJob: VideoCaptionJob?
    @Published var captionLanguage: String = Settings.videoCaptionLanguage {
        didSet { Settings.videoCaptionLanguage = captionLanguage }
    }
    @Published var captionLanguages: [VideoCaptionTranscriber.Language] = []
    var captionTask: Task<Void, Never>?
    var captionToken: UUID?

    let clock = VideoDemoPlaybackClock()
    let timelineState = VideoTimelineState()
    private var timelineSignature: TimelineSignature?
    let playback = VideoPlaybackController()
    lazy var previewRenderer = VideoPreviewRenderer(model: self)
    let recording: VideoDemoRecordingMetadata?
    let artwork: VideoCursorArtwork
    private(set) var plan: VideoRenderPlan
    private(set) var segments: [VideoDemoTimelineSegment] = []

    private var undoStack: [VideoDemoProject] = []
    private var redoStack: [VideoDemoProject] = []
    private var lastCoalesceKey: String?
    private var lastMutation = Date.distantPast
    private var autosaveWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var cursorTrackCache: (key: CursorTrackKey, track: VideoCursorTrack?)?
    private var cameraTrackCache: (key: CameraTrackKey, track: VideoCameraTrack)?
    private var reframeCache: (key: CameraTrackKey, fraction: CGFloat, reframe: VideoReframe)?
    private var transcriptCache: (captions: [VideoCaptionLine], language: String?, words: [VideoTranscriptWord])?
    private var activityCache: (key: [Int], times: [Double])?

    /// When something happens on screen (pointer moves, clicks, shortcuts).
    var activityTimes: [Double] {
        let key = [project.cursorSamples.count, project.clickEvents.count, project.keystrokes.count, Int((project.cursorSamples.last?.time ?? 0) * 100)]
        if let cache = activityCache, cache.key == key { return cache.times }
        let times = VideoTranscript.activityTimes(cursor: project.cursorSamples, clicks: project.clickEvents, keystrokes: project.keystrokes)
        activityCache = (key, times)
        return times
    }

    /// Every spoken word (from the captions), in time order.
    var transcriptWords: [VideoTranscriptWord] {
        // Transcripts from before the language was saved: the language
        // chosen for captions, else the Mac's own.
        let language = project.transcriptLanguage ?? (captionLanguage.isEmpty ? Locale.current.identifier(.bcp47) : captionLanguage)
        if let cache = transcriptCache, cache.captions == project.captions, cache.language == language { return cache.words }
        let words = VideoTranscript.words(from: project.captions, language: language)
        transcriptCache = (project.captions, language, words)
        return words
    }
    private var shuttleRate: Float = 1
    private var exportCancelled = false
    private var didLoad = false

    /// Everything the camera path depends on — captions, shortcuts,
    /// annotations, and most style changes leave it alone.
    private struct CameraTrackKey: Equatable {
        let regions: [VideoZoomRegion]
        let timings: [VideoPlaybackController.EditStructure.Timing]
        let speed: VideoZoomSpeed
        let stage: CGRect
        let crop: VideoCropRect
        let cursorTrack: ObjectIdentifier?
    }

    private struct TimelineSignature: Equatable {
        let segments: [VideoDemoTimelineSegment]
        let zooms: [VideoZoomRegion]
        let overlays: [VideoDemoOverlayEffect]
        let clicks: [VideoDemoClickEvent]
        let captions: [VideoCaptionLine]
        let keystrokes: [VideoKeystrokeEvent]
        let keystrokesVisible: Bool
        let cameraLayouts: [VideoCameraLayoutRegion]
        let selection: Selection
        let zoom: Double
        let lock: Double?
        let thumbnails: Int
        let waveform: Int
        let sourceSize: CGSize
    }

    /// Bumps the timeline's revision when anything it draws changed.
    func refreshTimeline() {
        let signature = TimelineSignature(
            segments: segments,
            zooms: project.zoomRegions,
            overlays: project.overlayEffects,
            clicks: project.clickEvents,
            captions: project.captions,
            keystrokes: project.keystrokes,
            keystrokesVisible: project.keystrokeStyle.visible,
            cameraLayouts: hasWebcamFootage ? project.cameraLayouts : [],
            selection: selection,
            zoom: timelineZoom,
            lock: layoutDurationLock,
            thumbnails: thumbnails.count,
            waveform: waveform?.peaks.count ?? -1,
            sourceSize: project.sourceSize
        )
        guard signature != timelineSignature else { return }
        timelineSignature = signature
        timelineState.bump()
    }

    private struct CursorTrackKey: Equatable {
        let sampleCount: Int
        let firstSample: Double
        let lastSample: Double
        let clicks: [VideoDemoClickEvent]
        let smoothing: VideoCursorSettings.Smoothing
        let hideWhenIdle: Bool
        let tidyEnding: Bool
        let crop: VideoCropRect
        let duration: Double
    }

    init(videoURL: URL) {
        let recording = VideoDemoSidecarStore.load(for: videoURL)
        self.recording = recording
        artwork = VideoCursorArtwork(metadata: recording)
        var project = VideoDemoProject.make(sourceURL: videoURL)
        if let recording {
            project.apply(metadata: recording)
        }
        self.project = project
        plan = VideoRenderPlan(project: project, sourceDuration: 0, artwork: artwork, pointPixelScale: recording?.pointPixelScale, cursorTrack: nil, camera: .identity)

        playback.onTick = { [weak self] time in
            guard let self else { return }
            // While paused and scrubbing, the player reports each finished
            // seek — an older spot than the playhead already shows.
            guard self.isPlaying || !self.playback.isSeeking else { return }
            if self.clock.time != time { self.clock.time = time }
            if self.isPlaying { self.previewRenderer.invalidate() }
        }
        playback.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            self.isPlaying = playing
            if !playing { self.shuttleRate = 1 }
            self.previewRenderer.invalidate()
        }
    }

    // MARK: Loading

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            let source = try await playback.load(url: project.sourceURL)
            if let webcam = webcamRecording, let camera = await VideoCameraSource.load(webcam) {
                playback.setCamera(camera)
                hasWebcamFootage = true
            }
            sourceDuration = source.duration
            sourceFrameRate = source.frameRate
            hasAudio = !source.audio.isEmpty
            audioKinds = VideoAudioKind.resolve(recorded: recording?.audioTracks, channelCounts: source.audioChannelCounts)
            playback.setAudioSources(VideoAudioSource.sources(from: source, kinds: audioKinds))

            var loaded = project
            var isFresh = false
            // The store only hands back this file's own draft (moved or
            // renamed files included; copies and replaced files excluded).
            if let draft = VideoDemoDraftStore.load(for: project.sourceURL) {
                loaded = draft.project
                // The file may have moved since: this is where it is now.
                loaded.sourcePath = project.sourcePath
                // Drafts leave the (read-only) pointer path in the sidecar.
                if loaded.cursorSamples.isEmpty, let recording {
                    loaded.cursorSamples = recording.cursorSamples
                }
                restoredDraft = true
            } else {
                isFresh = recording != nil
            }
            loaded.sourceWidth = Double(source.size.width)
            loaded.sourceHeight = Double(source.size.height)
            if !restoredDraft, loaded.sourceHeight > loaded.sourceWidth * 1.1,
               loaded.aspectPreset == .widescreen || loaded.aspectPreset == .classic {
                // A tall recording in a wide frame would be a sliver.
                loaded.aspectPreset = .source
            }
            if loaded.trimEnd <= 0 || loaded.trimEnd > source.duration {
                loaded.trimEnd = source.duration
            }
            loaded.ensureTimeline(totalDuration: source.duration)

            // A fresh recording opens already produced.
            if isFresh, Settings.autoZoomNewRecordings, loaded.zoomRegions.isEmpty, !loaded.clickEvents.isEmpty {
                loaded.zoomRegions = VideoAutoZoomPlanner.regions(
                    clicks: loaded.clicksInsideCrop,
                    cursorSamples: loaded.cursorSamples,
                    segments: loaded.timelineSegments(totalDuration: source.duration),
                    scale: loaded.defaultZoomScale,
                    speed: loaded.zoomSpeed
                )
            }
            project = loaded
            if hasWebcamFootage {
                playback.cameraStore.setFindsPerson(project.webcam.needsPersonMask)
            }
            isReady = true
            playback.apply(segments: segments, audio: project.audio, keepSourceTime: nil)
            playback.seek(to: 0, fast: false)
            saveDraftNow()
            if isFresh, !project.zoomRegions.isEmpty {
                showNotice("Auto zoom applied — \(project.zoomRegions.count) zoom\(project.zoomRegions.count == 1 ? "" : "s") follow your clicks", symbol: "sparkles")
            } else if restoredDraft {
                showNotice("Picked up where you left off", symbol: "clock.arrow.circlepath")
            }
            Task { await loadThumbnails() }
            Task { await loadWaveform() }
            if project.audio.enhanceVoice {
                enhanceVoiceChanged()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Project changes

    private func projectDidChange(from old: VideoDemoProject) {
        let oldSegments = segments
        segments = project.timelineSegments(totalDuration: sourceDuration)
        refreshTimeline()
        if isReady, old.audio.enhanceVoice != project.audio.enhanceVoice {
            enhanceVoiceChanged()
        }
        if isReady, hasWebcamFootage, old.webcam.needsPersonMask != project.webcam.needsPersonMask {
            if playback.cameraStore.setFindsPerson(project.webcam.needsPersonMask) {
                playback.refreshCurrentFrame()
            }
        }
        // Cropping previews the raw recording: the plan (pointer path,
        // camera) is rebuilt once the crop is done, not on every drag.
        if !isCropping { rebuildPlan() }
        validateSelection(keepingRange: true)
        if isReady {
            // Stay on the same moment of the recording — read through the
            // cut list it was on (a speed change or cut before the playhead
            // moves that moment along the timeline).
            let keepSource = VideoDemoProject.sourceTime(forTimelineTime: clock.time, segments: oldSegments.isEmpty ? segments : oldSegments)
            // The playhead follows that moment to its new place on the
            // timeline (paused, the player won't report the move).
            if let moved = playback.apply(segments: segments, audio: project.audio, keepSourceTime: keepSource), !isPlaying {
                clock.time = moved
            }
            scheduleAutosave()
        }
        previewRenderer.invalidate()
    }

    /// After cropping: bring the plan up to date in one go.
    func refreshPlan() {
        rebuildPlan()
        previewRenderer.invalidate()
    }

    /// Steps back to an earlier project as if the edits since `depth` undo
    /// steps never happened (a cancelled crop): no extra undo step.
    func discardEdits(restoring snapshot: VideoDemoProject, undoDepth depth: Int) {
        undoStack = Array(undoStack.prefix(depth))
        redoStack.removeAll()
        lastCoalesceKey = nil
        project = snapshot
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    var undoDepth: Int { undoStack.count }

    private func rebuildPlan() {
        let key = CursorTrackKey(
            sampleCount: project.cursorSamples.count,
            firstSample: project.cursorSamples.first?.time ?? 0,
            lastSample: project.cursorSamples.last?.time ?? 0,
            clicks: project.clickEvents,
            smoothing: project.cursor.smoothing,
            hideWhenIdle: project.cursor.hideWhenIdle,
            tidyEnding: project.cursor.tidyEnding,
            crop: project.crop.normalized,
            duration: sourceDuration
        )
        let cursorTrack: VideoCursorTrack?
        if let cache = cursorTrackCache, cache.key == key {
            cursorTrack = cache.track
        } else {
            cursorTrack = VideoCursorTrack.build(
                samples: project.cursorSamples,
                clicks: project.clickEvents,
                smoothing: project.cursor.smoothing,
                hideWhenIdle: project.cursor.hideWhenIdle,
                tidyEnding: project.cursor.tidyEnding,
                crop: project.crop.normalized,
                duration: sourceDuration
            )
            cursorTrackCache = (key, cursorTrack)
        }
        // Reframing renders the recording's own shape, then crops a moving
        // window: the camera path is built for that landscape scene.
        let layoutProject = project.reframeActive ? project.reframeScene() : project
        let canvas = layoutProject.canvasSize()
        let stage = layoutProject.stageRect(in: canvas)
        let normalizedStage = CGRect(x: stage.minX / canvas.width, y: stage.minY / canvas.height, width: stage.width / canvas.width, height: stage.height / canvas.height)
        let cameraKey = CameraTrackKey(
            regions: project.zoomRegions,
            timings: segments.map { .init(start: $0.clip.sourceStart, end: $0.clip.sourceEnd, speed: $0.clip.normalizedSpeed) },
            speed: project.zoomSpeed,
            stage: normalizedStage,
            crop: project.crop.normalized,
            cursorTrack: cursorTrack.map(ObjectIdentifier.init)
        )
        let camera: VideoCameraTrack
        if let cache = cameraTrackCache, cache.key == cameraKey {
            camera = cache.track
        } else {
            camera = VideoCameraTrack.build(
                regions: project.zoomRegions,
                segments: segments,
                timelineDuration: segments.last?.timelineEnd ?? 0,
                speed: project.zoomSpeed,
                stage: normalizedStage,
                crop: project.crop.normalized,
                cursor: cursorTrack.map { track in { track.visiblePosition(at: $0) } }
            )
            cameraTrackCache = (cameraKey, camera)
        }
        let outputCanvas = project.canvasSize()
        var reframe: VideoReframe?
        if project.reframeActive,
           let fraction = VideoReframe.windowFraction(outputAspect: outputCanvas.width / max(outputCanvas.height, 1), sceneAspect: canvas.width / max(canvas.height, 1)) {
            if let cache = reframeCache, cache.key == cameraKey, cache.fraction == fraction {
                reframe = cache.reframe
            } else {
                let built = VideoReframe.build(
                    windowFraction: fraction,
                    camera: camera,
                    cursorTrack: cursorTrack,
                    segments: segments,
                    canvas: canvas,
                    stage: stage,
                    crop: project.crop.normalized,
                    duration: segments.last?.timelineEnd ?? 0
                )
                reframeCache = (cameraKey, fraction, built)
                reframe = built
            }
        }
        plan = VideoRenderPlan(
            project: layoutProject,
            sourceDuration: sourceDuration,
            artwork: artwork,
            pointPixelScale: recording?.pointPixelScale,
            cursorTrack: cursorTrack,
            camera: camera,
            hasWebcam: hasWebcamFootage,
            outputCanvasSize: outputCanvas,
            reframe: reframe
        )
    }

    // MARK: Undo

    /// Every edit goes through here. `coalesce` merges a continuous gesture
    /// (a slider drag, a block drag) into ONE undo step.
    func mutate(coalesce key: String? = nil, _ change: (inout VideoDemoProject) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        let now = Date()
        if key == nil || key != lastCoalesceKey || now.timeIntervalSince(lastMutation) > 1.5 {
            undoStack.append(project)
            if undoStack.count > 300 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastCoalesceKey = key
        lastMutation = now
        project = next
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    /// Ends a coalesced gesture so the next edit starts a new undo step.
    func endGesture() {
        lastCoalesceKey = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCoalesceKey = nil
        project = previous
        validateSelection()
        canUndo = !undoStack.isEmpty
        canRedo = true
        showNotice("Undo", symbol: "arrow.uturn.backward")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCoalesceKey = nil
        project = next
        validateSelection()
        canUndo = true
        canRedo = !redoStack.isEmpty
        showNotice("Redo", symbol: "arrow.uturn.forward")
    }

    func validateSelection(keepingRange: Bool = false) {
        switch selection {
        case .zoom(let id) where !project.zoomRegions.contains(where: { $0.id == id }),
             .overlay(let id) where !project.overlayEffects.contains(where: { $0.id == id }),
             .click(let id) where !project.clickEvents.contains(where: { $0.id == id }),
             .caption(let id) where !project.captions.contains(where: { $0.id == id }),
             .keystroke(let id) where !project.keystrokes.contains(where: { $0.id == id }),
             .cameraLayout(let id) where !project.cameraLayouts.contains(where: { $0.id == id }),
             .clip(let id) where !project.timelineClips.contains(where: { $0.id == id }):
            selection = .none
        case .range where !keepingRange:
            selection = .none
        default:
            break
        }
    }

    // MARK: Time mapping

    var timelineDuration: Double { segments.last?.timelineEnd ?? 0 }

    func sourceTime(forTimeline time: Double) -> Double {
        VideoDemoProject.sourceTime(forTimelineTime: time, segments: segments)
    }

    /// The moment of the recording something new at the playhead starts
    /// from. On a cut that's the frame after it — the one on screen — not
    /// the last frame of the material before it.
    func placementSourceTime(forTimeline time: Double) -> Double {
        if let next = segments.first(where: { abs($0.timelineStart - time) < 0.001 }) {
            return next.clip.sourceStart
        }
        return sourceTime(forTimeline: time)
    }

    func timelineTime(forSource time: Double) -> Double? {
        VideoDemoProject.timelineTimeIfIncluded(sourceTime: time, segments: segments)
    }

    func segment(atTimeline time: Double) -> VideoDemoTimelineSegment? {
        segments.first { time >= $0.timelineStart - 0.0001 && time <= $0.timelineEnd + 0.0001 }
    }

    /// Camera at a timeline moment (for preview handles).
    func cameraState(at time: Double) -> VideoCameraState {
        plan.camera.state(at: time)
    }

    // MARK: Transport

    func togglePlay() {
        shuttleRate = 1
        if isPlaying {
            playback.pause()
        } else {
            if case .zoom = selection, isAimingZoom { selection = .none }
            playback.play()
        }
    }

    func pause() {
        playback.pause()
    }

    func seek(to time: Double, fast: Bool = false) {
        let target = min(max(time, 0), timelineDuration)
        clock.time = target
        playback.seek(to: target, fast: fast)
        previewRenderer.invalidate()
    }

    func step(frames: Int) {
        playback.pause()
        seek(to: clock.time + Double(frames) / max(sourceFrameRate, 24))
    }

    func jump(by seconds: Double) {
        seek(to: clock.time + seconds)
    }

    /// L in J/K/L: play, then 2x, 4x on repeated presses.
    func shuttleForward() {
        if isPlaying {
            shuttleRate = min(shuttleRate * 2, 4)
            playback.setRate(shuttleRate)
            showNotice("Playing \(Int(shuttleRate))×", symbol: "forward.fill")
        } else {
            playback.play()
        }
    }

    /// J: step back a second (reverse playback of long-GOP video is choppy).
    func shuttleBackward() {
        playback.pause()
        jump(by: -1)
    }

    // MARK: Clips

    var selectedClipID: UUID? {
        if case .clip(let id) = selection { return id }
        return nil
    }

    func selectClip(_ id: UUID) {
        selection = .clip(id)
    }

    func splitAtPlayhead() {
        let time = clock.time
        guard let segment = segment(atTimeline: time) else { return }
        let sourceTime = segment.sourceTime(forTimelineTime: time)
        var newID: UUID?
        mutate { project in
            newID = project.splitClip(atSourceTime: sourceTime, totalDuration: sourceDuration)
        }
        if let newID {
            selection = .clip(newID)
            showNotice("Split", symbol: "scissors")
        } else {
            showNotice("Move the playhead inside a clip to split", symbol: "scissors")
        }
    }

    func deleteClip(_ id: UUID) {
        guard segments.count > 1 else {
            showNotice("A video needs at least one clip", symbol: "exclamationmark.triangle")
            return
        }
        let anchor = segments.first(where: { $0.id == id })?.timelineStart ?? clock.time
        var next: UUID?
        mutate { project in
            next = project.deleteClip(id: id, totalDuration: sourceDuration)
        }
        selection = next.map { .clip($0) } ?? .none
        seek(to: min(anchor, max(timelineDuration - 0.01, 0)))
        showNotice("Clip removed — ⌘Z to undo", symbol: "trash")
    }

    func deleteRange(_ range: VideoDemoTimelineRange) {
        let normalized = range.normalized
        var next: UUID?
        mutate { project in
            next = project.deleteTimelineRange(start: normalized.start, end: normalized.end, totalDuration: sourceDuration)
        }
        if next == nil {
            showNotice("A video needs at least one clip", symbol: "exclamationmark.triangle")
            return
        }
        selection = .none
        seek(to: min(normalized.start, max(timelineDuration - 0.01, 0)))
        showNotice("Removed \(Self.format(normalized.duration)) — ⌘Z to undo", symbol: "scissors")
    }

    func setClipSpeed(_ id: UUID, _ speed: Double) {
        mutate(coalesce: "speed-\(id)") { project in
            _ = project.updateClip(id: id, totalDuration: sourceDuration) { $0.speed = speed }
        }
    }

    func setClipMuted(_ id: UUID, _ muted: Bool) {
        mutate { project in
            _ = project.updateClip(id: id, totalDuration: sourceDuration) { $0.muted = muted }
        }
    }

    func setClipFade(_ id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        mutate(coalesce: "fade-\(id)") { project in
            _ = project.updateClip(id: id, totalDuration: sourceDuration) { clip in
                if let fadeIn { clip.fadeIn = fadeIn }
                if let fadeOut { clip.fadeOut = fadeOut }
            }
        }
    }

    /// Live clip-edge trim. `sourceTime` is the new edge; the preview peeks
    /// at it while dragging.
    func trimClip(_ id: UUID, leading: Bool, toSource sourceTime: Double) {
        if layoutDurationLock == nil { layoutDurationLock = timelineDuration }
        mutate(coalesce: "trim-\(id)-\(leading)") { project in
            if leading {
                _ = project.trimClip(id: id, sourceStart: sourceTime, totalDuration: sourceDuration)
            } else {
                _ = project.trimClip(id: id, sourceEnd: sourceTime, totalDuration: sourceDuration)
            }
        }
        if let clip = project.timelineClips.first(where: { $0.id == id }) {
            trimPeekSourceTime = leading ? clip.sourceStart : max(clip.sourceEnd - 0.02, clip.sourceStart)
        }
        previewRenderer.invalidate()
    }

    func endTrim(_ id: UUID, leading: Bool) {
        endGesture()
        trimPeekSourceTime = nil
        layoutDurationLock = nil
        if let segment = segments.first(where: { $0.id == id }) {
            seek(to: leading ? segment.timelineStart : max(segment.timelineEnd - 0.02, segment.timelineStart))
        }
    }

    func trimSelectedClipToPlayhead(leading: Bool) {
        let time = clock.time
        // The selected clip, when the playhead is in it; else the clip the
        // playhead is in — on a cut, the one after it for "starts here" and
        // the one before it for "ends here".
        let selected = selectedClipID.flatMap { id in
            segments.first { $0.id == id && time >= $0.timelineStart - 0.001 && time <= $0.timelineEnd + 0.001 }
        }
        let underPlayhead = leading
            ? segments.first { time >= $0.timelineStart - 0.001 && time < $0.timelineEnd - 0.001 }
            : segments.first { time > $0.timelineStart + 0.001 && time <= $0.timelineEnd + 0.001 }
        guard let segment = selected ?? underPlayhead else { return }
        let sourceTime = segment.sourceTime(forTimelineTime: time)
        mutate { project in
            if leading {
                _ = project.trimClip(id: segment.id, sourceStart: sourceTime, totalDuration: sourceDuration)
            } else {
                _ = project.trimClip(id: segment.id, sourceEnd: sourceTime, totalDuration: sourceDuration)
            }
        }
        selection = .clip(segment.id)
        showNotice(leading ? "Clip now starts here" : "Clip now ends here", symbol: leading ? "arrow.left.to.line" : "arrow.right.to.line")
    }

    /// Material cut between two clips (or before the first / after the last).
    struct CutGap: Identifiable {
        var id: String { "\(afterClip?.uuidString ?? "start")-\(sourceStart)" }
        let timelineTime: Double
        let sourceStart: Double
        let sourceEnd: Double
        let afterClip: UUID?
        var duration: Double { sourceEnd - sourceStart }
    }

    var cutGaps: [CutGap] {
        var gaps: [CutGap] = []
        guard let first = segments.first, let last = segments.last else { return gaps }
        if first.clip.sourceStart > 0.05 {
            gaps.append(CutGap(timelineTime: 0, sourceStart: 0, sourceEnd: first.clip.sourceStart, afterClip: nil))
        }
        for (a, b) in zip(segments, segments.dropFirst()) where b.clip.sourceStart - a.clip.sourceEnd > 0.05 {
            gaps.append(CutGap(timelineTime: a.timelineEnd, sourceStart: a.clip.sourceEnd, sourceEnd: b.clip.sourceStart, afterClip: a.id))
        }
        if sourceDuration - last.clip.sourceEnd > 0.05 {
            gaps.append(CutGap(timelineTime: last.timelineEnd, sourceStart: last.clip.sourceEnd, sourceEnd: sourceDuration, afterClip: last.id))
        }
        return gaps
    }

    /// Puts removed material back (the neighbouring clip grows over it).
    func restore(_ gap: CutGap) {
        mutate { project in
            var clips = project.normalizedTimelineClips(totalDuration: sourceDuration)
            if let after = gap.afterClip, let index = clips.firstIndex(where: { $0.id == after }) {
                if index + 1 < clips.count, abs(clips[index + 1].sourceStart - gap.sourceEnd) < 0.001,
                   abs(clips[index].normalizedSpeed - clips[index + 1].normalizedSpeed) < 0.001,
                   clips[index].muted == clips[index + 1].muted {
                    // Seamless again: merge the two clips.
                    clips[index].sourceEnd = clips[index + 1].sourceEnd
                    clips[index].fadeOut = clips[index + 1].fadeOut
                    clips.remove(at: index + 1)
                } else {
                    clips[index].sourceEnd = gap.sourceEnd
                }
            } else if !clips.isEmpty {
                clips[0].sourceStart = gap.sourceStart
            }
            project.timelineClips = clips
            project.ensureTimeline(totalDuration: sourceDuration)
        }
        showNotice("Restored \(Self.format(gap.duration))", symbol: "arrow.uturn.backward")
    }

    // MARK: Zooms

    var selectedZoomID: UUID? {
        if case .zoom(let id) = selection { return id }
        return nil
    }

    var selectedZoom: VideoZoomRegion? {
        selectedZoomID.flatMap { id in project.zoomRegions.first { $0.id == id } }
    }

    /// Paused with a manual zoom selected: the preview shows the whole frame
    /// with a draggable target rectangle.
    var isAimingZoom: Bool {
        guard !isPlaying, let zoom = selectedZoom else { return false }
        return !zoom.followsCursor
    }

    /// Timeline ranges occupied by zoom regions (for placement and drawing).
    func zoomTimelineRange(_ region: VideoZoomRegion) -> ClosedRange<Double>? {
        let ranges = VideoDemoProject.timelineRanges(sourceStart: region.start, sourceEnd: region.end, segments: segments)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return first.lowerBound...last.upperBound
    }

    /// Free space around `time` on the zoom track.
    func zoomGap(around time: Double) -> ClosedRange<Double> {
        var lower = 0.0
        var upper = timelineDuration
        for region in project.zoomRegions {
            guard let range = zoomTimelineRange(region) else { continue }
            if range.upperBound <= time { lower = max(lower, range.upperBound) }
            if range.lowerBound >= time { upper = min(upper, range.lowerBound) }
            if range.contains(time) { return time...time }
        }
        return lower...max(lower, upper)
    }

    /// Times a zoom edge likes to land on: the playhead, clip boundaries,
    /// clicks, and the edges of other zooms.
    func zoomSnapTargets(excluding id: UUID) -> [Double] {
        var targets: [Double] = [0, timelineDuration, clock.time]
        for segment in segments {
            targets.append(segment.timelineStart)
            targets.append(segment.timelineEnd)
        }
        for click in project.clickEvents {
            if let time = timelineTime(forSource: click.time) { targets.append(time) }
        }
        for region in project.zoomRegions where region.id != id {
            if let range = zoomTimelineRange(region) {
                targets.append(range.lowerBound)
                targets.append(range.upperBound)
            }
        }
        return targets
    }

    @discardableResult
    func addZoom(at time: Double, length: Double = 3) -> UUID? {
        let gap = zoomGap(around: time)
        guard gap.upperBound - gap.lowerBound >= VideoZoomRegion.minimumDuration else {
            showNotice("There's already a zoom here", symbol: "plus.magnifyingglass")
            return nil
        }
        var start = max(time - 0.2, gap.lowerBound)
        var end = min(start + length, gap.upperBound)
        if end - start < min(length, 1.2) {
            start = max(gap.lowerBound, end - length)
            end = min(gap.upperBound, start + length)
        }
        let sourceStart = sourceTime(forTimeline: start)
        let sourceEnd = sourceTime(forTimeline: end)
        guard sourceEnd - sourceStart >= VideoZoomRegion.minimumDuration else { return nil }
        // Aim where the pointer is, when we know it.
        let pointer = plan.cursorTrack?.visiblePosition(at: sourceTime(forTimeline: min(start + 0.6, end)))
        let region = VideoZoomRegion(
            start: sourceStart,
            end: sourceEnd,
            scale: project.defaultZoomScale,
            followsCursor: plan.cursorTrack != nil,
            focusX: pointer.map { Double($0.x) } ?? 0.5,
            focusY: pointer.map { Double($0.y) } ?? 0.5
        )
        mutate { project in
            project.zoomRegions.append(region)
            project.zoomRegions.sort { $0.start < $1.start }
        }
        selection = .zoom(region.id)
        return region.id
    }

    func updateZoom(_ id: UUID, coalesce: String? = nil, _ change: (inout VideoZoomRegion) -> Void) {
        mutate(coalesce: coalesce) { project in
            guard let index = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            change(&project.zoomRegions[index])
            project.zoomRegions[index].scale = min(max(project.zoomRegions[index].scale, VideoZoomRegion.scaleRange.lowerBound), VideoZoomRegion.scaleRange.upperBound)
            project.zoomRegions[index].focusX = min(max(project.zoomRegions[index].focusX, 0), 1)
            project.zoomRegions[index].focusY = min(max(project.zoomRegions[index].focusY, 0), 1)
            project.zoomRegions[index].isAuto = false
        }
    }

    /// Moves / resizes a zoom in timeline seconds, never overlapping its
    /// neighbours.
    func setZoomWindow(_ id: UUID, start: Double, end: Double, coalesce: String) {
        let others = project.zoomRegions.filter { $0.id != id }.compactMap { zoomTimelineRange($0) }
        guard let current = project.zoomRegions.first(where: { $0.id == id }).flatMap({ zoomTimelineRange($0) }) else { return }
        let lowerLimit = others.filter { $0.upperBound <= current.lowerBound + 0.001 }.map(\.upperBound).max() ?? 0
        let upperLimit = others.filter { $0.lowerBound >= current.upperBound - 0.001 }.map(\.lowerBound).min() ?? timelineDuration
        var newStart = max(start, lowerLimit)
        var newEnd = min(end, upperLimit)
        if newEnd - newStart < VideoZoomRegion.minimumDuration {
            if start != current.lowerBound && end != current.upperBound {
                // Moving: keep the length.
                let length = current.upperBound - current.lowerBound
                newStart = min(max(start, lowerLimit), upperLimit - length)
                newEnd = newStart + length
            } else if start != current.lowerBound {
                newStart = newEnd - VideoZoomRegion.minimumDuration
            } else {
                newEnd = newStart + VideoZoomRegion.minimumDuration
            }
        }
        let sourceStart = sourceTime(forTimeline: newStart)
        let sourceEnd = sourceTime(forTimeline: newEnd)
        updateZoom(id, coalesce: coalesce) { region in
            region.start = sourceStart
            region.end = max(sourceEnd, sourceStart + VideoZoomRegion.minimumDuration)
        }
    }

    func deleteZoom(_ id: UUID) {
        mutate { project in
            project.zoomRegions.removeAll { $0.id == id }
        }
        if selection == .zoom(id) { selection = .none }
        showNotice("Zoom removed — ⌘Z to undo", symbol: "trash")
    }

    /// Back to the recording as it was made: every edit goes (one undo
    /// brings them all back).
    func startOver() {
        let alert = NSAlert()
        alert.messageText = "Start over from the original recording?"
        alert.informativeText = "Every cut, zoom, annotation, caption, and style change on this video is removed. You can undo this."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var fresh = VideoDemoProject.make(sourceURL: project.sourceURL, duration: sourceDuration, sourceSize: project.sourceSize)
        if let recording { fresh.apply(metadata: recording) }
        fresh.sourceWidth = project.sourceWidth
        fresh.sourceHeight = project.sourceHeight
        fresh.ensureTimeline(totalDuration: sourceDuration)
        if fresh.sourceHeight > fresh.sourceWidth * 1.1, fresh.aspectPreset == .widescreen || fresh.aspectPreset == .classic {
            fresh.aspectPreset = .source
        }
        if recording != nil, Settings.autoZoomNewRecordings, !fresh.clickEvents.isEmpty {
            fresh.zoomRegions = VideoAutoZoomPlanner.regions(
                clicks: fresh.clicksInsideCrop,
                cursorSamples: fresh.cursorSamples,
                segments: fresh.timelineSegments(totalDuration: sourceDuration),
                scale: fresh.defaultZoomScale,
                speed: fresh.zoomSpeed
            )
        }
        selection = .none
        mutate { $0 = fresh }
        endGesture()
        showNotice("Back to the original recording — ⌘Z to undo", symbol: "arrow.counterclockwise")
    }

    /// A copy of an annotation, nudged so both are visible, on top.
    func duplicateOverlay(_ id: UUID) {
        guard let original = project.overlayEffects.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.x = min(original.x + 0.03, 0.98)
        copy.y = min(original.y + 0.03, 0.98)
        let overlapping = project.overlayEffects.filter { $0.time < copy.time + copy.duration && $0.time + $0.duration > copy.time }
        copy.layer = (overlapping.map(\.layer).max() ?? -1) + 1
        mutate { project in
            project.overlayEffects.append(copy)
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        }
        selection = .overlay(copy.id)
        showNotice("Duplicated", symbol: "plus.square.on.square")
    }

    func duplicateZoom(_ id: UUID) {
        guard let region = project.zoomRegions.first(where: { $0.id == id }),
              let range = zoomTimelineRange(region) else { return }
        let length = range.upperBound - range.lowerBound
        let gap = zoomGap(around: range.upperBound + 0.01)
        guard gap.upperBound - gap.lowerBound >= length * 0.5 else {
            showNotice("No room after this zoom", symbol: "plus.square.on.square")
            return
        }
        let start = gap.lowerBound + 0.1
        let end = min(start + length, gap.upperBound)
        var copy = region
        copy.id = UUID()
        copy.start = sourceTime(forTimeline: start)
        copy.end = sourceTime(forTimeline: end)
        copy.isAuto = false
        mutate { project in
            project.zoomRegions.append(copy)
            project.zoomRegions.sort { $0.start < $1.start }
        }
        selection = .zoom(copy.id)
    }

    func applyZoomScaleToAll(_ scale: Double) {
        mutate { project in
            for index in project.zoomRegions.indices {
                project.zoomRegions[index].scale = scale
            }
            project.defaultZoomScale = scale
        }
        showNotice("All zooms set to \(Self.formatScale(scale))", symbol: "plus.magnifyingglass")
    }

    func autoZoom() {
        let generated = VideoAutoZoomPlanner.regions(
            clicks: project.clicksInsideCrop,
            cursorSamples: project.cursorSamples,
            segments: segments,
            scale: project.defaultZoomScale,
            speed: project.zoomSpeed
        )
        guard !generated.isEmpty else {
            showNotice(project.clickEvents.isEmpty ? "No clicks were recorded — add zooms by hand" : "No clicks left on the timeline", symbol: "sparkles")
            return
        }
        mutate { project in
            let manual = project.zoomRegions.filter { !$0.isAuto }
            // Keep hand-made zooms; drop generated ones that would overlap them.
            let kept = generated.filter { candidate in
                !manual.contains { $0.start < candidate.end && $0.end > candidate.start }
            }
            project.zoomRegions = (manual + kept).sorted { $0.start < $1.start }
        }
        selection = .none
        showNotice("Auto zoom — \(project.zoomRegions.count) zoom\(project.zoomRegions.count == 1 ? "" : "s")", symbol: "sparkles")
    }

    func removeAllZooms() {
        guard !project.zoomRegions.isEmpty else { return }
        let count = project.zoomRegions.count
        mutate { project in
            project.zoomRegions.removeAll()
        }
        if case .zoom = selection { selection = .none }
        showNotice("Removed \(count) zoom\(count == 1 ? "" : "s") — ⌘Z to undo", symbol: "trash")
    }

    // MARK: Overlays

    var selectedOverlay: VideoDemoOverlayEffect? {
        if case .overlay(let id) = selection {
            return project.overlayEffects.first { $0.id == id }
        }
        return nil
    }

    func addOverlay(_ kind: VideoDemoOverlayEffectKind) {
        let time = clock.time
        let sourceStart = placementSourceTime(forTimeline: time)
        let sourceEnd = sourceTime(forTimeline: min(time + (kind == .blur ? 4 : 3), timelineDuration))
        var effect = VideoDemoOverlayEffect(
            kind: kind,
            time: sourceStart,
            duration: max(sourceEnd - sourceStart, 0.5),
            x: 0.5,
            y: kind == .text ? 0.14 : 0.5,
            width: kind == .text ? 0.5 : (kind == .arrow ? 0.18 : 0.3),
            height: kind == .text ? 0.09 : (kind == .arrow ? 0.18 : 0.2),
            text: kind == .text ? "Your text" : kind.title,
            color: VideoOverlayStyleMemory.color(for: kind),
            thickness: VideoOverlayStyleMemory.thickness(for: kind)
        )
        // Land where it can be seen: zooms and vertical reframing show only
        // part of the frame, so place (and if needed shrink) it inside that.
        let visible = visibleRegion(at: time)
        effect.width = min(effect.width, Double(visible.width) * 0.9)
        effect.height = min(effect.height, Double(visible.height) * 0.9)
        // Text goes near the top: captions, keycaps, and the camera bubble
        // live at the bottom.
        var center = CGPoint(x: visible.midX, y: kind == .text ? visible.minY + visible.height * 0.14 : visible.midY)
        if kind != .text, let raw = plan.cursorTrack?.visiblePosition(at: sourceStart) {
            // Annotations live in the (cropped) frame's coordinates.
            let pointer = project.crop.normalized.map(raw)
            if visible.insetBy(dx: visible.width * 0.05, dy: visible.height * 0.05).contains(pointer) {
                center = pointer
                if kind == .arrow {
                    // The head (top right) lands just beside the pointer.
                    center.x -= CGFloat(effect.width / 2) - visible.width * 0.02
                    center.y += CGFloat(effect.height / 2) + visible.height * 0.03
                }
            }
        }
        let halfWidth = CGFloat(effect.width / 2)
        let halfHeight = CGFloat(effect.height / 2)
        effect.x = Double(min(max(center.x, visible.minX + halfWidth), visible.maxX - halfWidth))
        effect.y = Double(min(max(center.y, visible.minY + halfHeight), visible.maxY - halfHeight))
        // New annotations stack ON TOP of anything they overlap: a higher
        // lane on the timeline, drawn in front in the video.
        let overlapping = project.overlayEffects.filter {
            $0.time < effect.time + effect.duration && $0.time + $0.duration > effect.time
        }
        effect.layer = (overlapping.map(\.layer).max() ?? -1) + 1
        mutate { project in
            project.overlayEffects.append(effect)
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        }
        selection = .overlay(effect.id)
    }

    /// The part of the frame on screen at a timeline moment, in annotation
    /// coordinates (0…1 across the cropped recording): zooms and vertical
    /// reframing show only some of it.
    func visibleRegion(at time: Double) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let canvas = plan.canvasSize
        let stage = (project.reframeActive ? project.reframeScene() : project).stageRect(in: canvas)
        guard canvas.width > 0, canvas.height > 0, stage.width > 0, stage.height > 0 else { return whole }
        var window = cameraState(at: time).window(in: canvas)
        if let reframe = plan.reframe {
            // The output is a window across the (camera's) scene.
            let fraction = reframe.windowFraction
            let origin = min(max(reframe.center(at: time) - fraction / 2, 0), 1 - fraction)
            window = CGRect(x: window.minX + window.width * origin, y: window.minY, width: window.width * fraction, height: window.height)
        }
        let region = CGRect(
            x: (window.minX - stage.minX) / stage.width,
            y: (window.minY - stage.minY) / stage.height,
            width: window.width / stage.width,
            height: window.height / stage.height
        ).intersection(whole)
        return region.width > 0.05 && region.height > 0.05 ? region : whole
    }

    func updateOverlay(_ id: UUID, coalesce: String? = nil, _ change: (inout VideoDemoOverlayEffect) -> Void) {
        mutate(coalesce: coalesce) { project in
            guard let index = project.overlayEffects.firstIndex(where: { $0.id == id }) else { return }
            change(&project.overlayEffects[index])
            var effect = project.overlayEffects[index]
            effect.width = min(max(effect.width, 0.04), 1)
            effect.height = min(max(effect.height, 0.03), 1)
            effect.x = min(max(effect.x, 0.02), 0.98)
            effect.y = min(max(effect.y, 0.02), 0.98)
            effect.duration = max(effect.duration, 0.2)
            project.overlayEffects[index] = effect
        }
    }

    func setOverlayWindow(_ id: UUID, start: Double, end: Double, coalesce: String) {
        let safeStart = min(max(start, 0), max(timelineDuration - 0.2, 0))
        let safeEnd = min(max(end, safeStart + 0.2), timelineDuration)
        let sourceStart = sourceTime(forTimeline: safeStart)
        let sourceEnd = sourceTime(forTimeline: safeEnd)
        updateOverlay(id, coalesce: coalesce) { effect in
            effect.time = sourceStart
            effect.duration = max(sourceEnd - sourceStart, 0.2)
        }
    }

    func setOverlayLayer(_ id: UUID, layer: Int, coalesce: String) {
        updateOverlay(id, coalesce: coalesce) { effect in
            effect.layer = min(max(layer, 0), 7)
        }
    }

    /// Settles lanes after a pill drag.
    func finishOverlayDrag() {
        endGesture()
        let normalized = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        if normalized != project.overlayEffects {
            // Part of the same gesture's undo step.
            var next = project
            next.overlayEffects = normalized
            project = next
        }
    }

    func deleteOverlay(_ id: UUID) {
        mutate { project in
            project.overlayEffects.removeAll { $0.id == id }
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        }
        if selection == .overlay(id) { selection = .none }
        showNotice("Removed — ⌘Z to undo", symbol: "trash")
    }

    // MARK: Clicks

    func moveClick(_ id: UUID, toTimeline time: Double) {
        let sourceTime = sourceTime(forTimeline: min(max(time, 0), timelineDuration))
        mutate(coalesce: "click-\(id)") { project in
            guard let index = project.clickEvents.firstIndex(where: { $0.id == id }) else { return }
            let press = project.clickEvents[index].pressDuration
            project.clickEvents[index].time = sourceTime
            project.clickEvents[index].endTime = sourceTime + press
            project.clickEvents.sort { $0.time < $1.time }
        }
    }

    func deleteClick(_ id: UUID) {
        mutate { project in
            project.clickEvents.removeAll { $0.id == id }
        }
        if selection == .click(id) { selection = .none }
        showNotice("Click removed — ⌘Z to undo", symbol: "trash")
    }

    // MARK: Delete / Escape

    func deleteSelection() {
        switch selection {
        case .none:
            break
        case .zoom(let id):
            deleteZoom(id)
        case .overlay(let id):
            deleteOverlay(id)
        case .click(let id):
            deleteClick(id)
        case .caption(let id):
            deleteCaption(id)
        case .keystroke(let id):
            deleteKeystroke(id)
        case .cameraLayout(let id):
            deleteCameraLayout(id)
        case .clip(let id):
            deleteClip(id)
        case .range(let range):
            deleteRange(range)
        }
    }

    // MARK: Style

    func setStyle(coalesce key: String? = nil, _ change: (inout VideoDemoProject) -> Void) {
        mutate(coalesce: key, change)
    }

    func saveStyleAsDefault() {
        VideoStylePreset.saveAsDefault(project.style)
        showNotice("Saved — new recordings will use this look", symbol: "checkmark.circle.fill")
    }

    /// Back to the built-in Shotnix look.
    func resetStyle() {
        mutate { project in
            project.apply(style: .factory)
        }
        showNotice("Reset to the Shotnix look", symbol: "arrow.counterclockwise")
    }

    var styleMatchesDefault: Bool {
        guard let saved = VideoStylePreset.savedDefault else { return false }
        return saved == project.style
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setStyle { $0.background = .image(url.path) }
    }

    func shuffleBackground() {
        let options = VideoBackgroundCatalog.wallpapers.map { VideoBackground.wallpaper($0.id) }
            + VideoBackgroundCatalog.pickerGradients.map { VideoBackground.gradient($0.id) }
        let choices = options.filter { $0 != project.background }
        guard let pick = choices.randomElement() else { return }
        setStyle { $0.background = pick }
    }

    // MARK: Idle speed-up

    /// Stretches of the recording where nothing happens: the pointer is
    /// still, nobody clicks, and it's quiet. Source seconds.
    func idleRanges(minimum: Double = 2.5) -> [ClosedRange<Double>] {
        guard sourceDuration > 0 else { return [] }
        var activity: [Double] = []
        var previous: VideoDemoCursorSample?
        for sample in project.cursorSamples {
            if let previous {
                let dx = sample.x - previous.x
                let dy = sample.y - previous.y
                if dx * dx + dy * dy > 0.002 * 0.002 { activity.append(sample.time) }
            }
            previous = sample
        }
        for click in project.clickEvents {
            activity.append(click.time)
            activity.append(click.time + click.pressDuration)
        }
        if let waveform, !waveform.peaks.isEmpty {
            let loud: Float = 0.06
            for (index, peak) in waveform.peaks.enumerated() where peak > loud && index % 5 == 0 {
                activity.append(Double(index) / VideoWaveform.bucketsPerSecond)
            }
        }
        activity.sort()
        var ranges: [ClosedRange<Double>] = []
        var last = 0.0
        let margin = 0.5
        for time in activity + [sourceDuration] {
            if time - last >= minimum + margin * 2 {
                ranges.append((last + margin)...(time - margin))
            }
            last = max(last, time)
        }
        return ranges
    }

    func speedUpIdle(speed: Double = 8) {
        // Without the pointer's path there's no telling a quiet screen from
        // a busy one — it would speed up everything.
        guard !project.cursorSamples.isEmpty else {
            showNotice("Speed Up Idle works on Shotnix recordings — it watches the pointer", symbol: "hare")
            return
        }
        let ranges = idleRanges()
        guard !ranges.isEmpty else {
            showNotice("No idle moments found — nice and tight", symbol: "hare")
            return
        }
        var saved = 0.0
        mutate { project in
            for range in ranges {
                // Only speed up material still on the timeline at 1×.
                _ = project.splitClip(atSourceTime: range.lowerBound, totalDuration: sourceDuration)
                _ = project.splitClip(atSourceTime: range.upperBound, totalDuration: sourceDuration)
                let clips = project.normalizedTimelineClips(totalDuration: sourceDuration)
                for clip in clips where clip.sourceStart >= range.lowerBound - 0.001 && clip.sourceEnd <= range.upperBound + 0.001 && abs(clip.normalizedSpeed - 1) < 0.01 {
                    _ = project.updateClip(id: clip.id, totalDuration: sourceDuration) { $0.speed = speed; $0.muted = true }
                    saved += clip.sourceDuration * (1 - 1 / speed)
                }
            }
        }
        showNotice("Sped up \(ranges.count) idle moment\(ranges.count == 1 ? "" : "s") — saved \(Self.format(saved))", symbol: "hare.fill")
    }

    // MARK: Notices

    func showNotice(_ message: String, symbol: String = "info.circle") {
        noticeWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            notice = VideoEditorNotice(message: message, symbol: symbol)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    // MARK: Autosave

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveDraftNow() }
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveDraftNow() {
        guard isReady else { return }
        autosaveWork?.cancel()
        autosaveWork = nil
        var draft = project
        // The pointer path can't be edited and lives in the recording's
        // sidecar — keeping it out makes autosave instant on long takes.
        if let recording, recording.cursorSamples == draft.cursorSamples {
            draft.cursorSamples = []
        }
        VideoDemoDraftStore.save(draft, for: draft.sourceURL)
    }

    /// Export, the command palette, or the shortcut sheet is up: edits
    /// behind it (undo) stay put.
    var hasOverlayOpen: Bool { isExportPresented || isCommandPalettePresented || isShortcutsPresented }

    /// Something that shouldn't be dropped silently by closing the window.
    var runningJobDescription: String? {
        if isExporting { return "exporting" }
        if captionTask != nil { return "transcribing" }
        if voiceJob != nil { return "cleaning up the voice" }
        return nil
    }

    /// The window closed: nothing keeps working (or writing to the
    /// clipboard) unseen.
    func stop() {
        playback.pause()
        if isExporting { cancelExport() }
        cancelCaptions()
        voiceTask?.cancel()
        saveDraftNow()
    }

    // MARK: Export

    var exportCanvas: CGSize { project.canvasSize() }

    func beginExport(toClipboard: Bool) {
        if case .running = exportPhase { return }
        let settings = exportSettings
        settings.saveAsDefaults()
        let destination: URL
        if toClipboard {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shotnix Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = folder.appendingPathComponent("\(exportBaseName).\(settings.fileExtension)")
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = settings.format == .gif ? [.gif] : [.mpeg4Movie]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(exportBaseName).\(settings.fileExtension)"
            panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        runExport(to: destination, settings: settings, toClipboard: toClipboard)
    }

    private var exportBaseName: String {
        let stamp = ImageExporter.timestampedName
        let cleaned = stamp.hasPrefix("Shotnix ") ? String(stamp.dropFirst("Shotnix ".count)) : stamp
        return "Shotnix Video \(cleaned)"
    }

    private func runExport(to destination: URL, settings: VideoExportSettings, toClipboard: Bool) {
        playback.pause()
        exportCancelled = false
        exportPhase = .running(progress: 0, started: Date(), destination: destination, toClipboard: toClipboard)
        let project = self.project
        let recording = self.recording
        let bridge = VideoExportBridge(model: self)
        let voice = project.audio.enhanceVoice ? startVoiceEnhancementIfNeeded() : nil
        Task {
            do {
                // The enhanced voice has to exist before it can be exported
                // (the sheet shows that progress; Cancel stops it).
                var voiceFailed = false
                if let voice {
                    // Cancel stops the waiting, not the cleanup (it keeps
                    // going for the preview and the next export).
                    while self.voiceTask != nil, !self.exportCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if exportCancelled { throw VideoDemoExportError.cancelled }
                    voiceFailed = !(await voice.value)
                }
                if exportCancelled { throw VideoDemoExportError.cancelled }
                _ = try await VideoDemoExporter.export(
                    project: project,
                    recording: recording,
                    destinationURL: destination,
                    settings: settings,
                    progress: { value in await bridge.progress(value) },
                    shouldCancel: { await bridge.isCancelled() }
                )
                let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                if toClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([destination as NSURL])
                } else {
                    VideoDemoRecentExportStore.add(exportURL: destination, sourceURL: project.sourceURL)
                }
                exportPhase = .finished(url: destination, bytes: bytes, copied: toClipboard)
                if voiceFailed {
                    showNotice("Exported without Enhance voice — it couldn't finish", symbol: "exclamationmark.triangle.fill")
                }
            } catch {
                if exportCancelled {
                    exportPhase = .idle
                    showNotice("Export cancelled", symbol: "xmark.circle")
                } else {
                    exportPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    fileprivate func updateExportProgress(_ value: Double) {
        if case .running(_, let started, let destination, let clipboard) = exportPhase {
            exportPhase = .running(progress: value, started: started, destination: destination, toClipboard: clipboard)
        }
    }

    fileprivate var exportIsCancelled: Bool { exportCancelled }

    func cancelExport() {
        exportCancelled = true
    }

    /// Closes the export sheet; a finished or failed export is cleared so
    /// the next ⌘E starts on the options.
    func closeExportSheet() {
        withAnimation(.easeOut(duration: 0.15)) {
            isExportPresented = false
        }
        if case .running = exportPhase { return }
        exportPhase = .idle
    }

    func revealExport(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openExport(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyExport(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        showNotice("Copied — paste it anywhere", symbol: "doc.on.doc")
    }

    func revealSource() {
        NSWorkspace.shared.activateFileViewerSelecting([project.sourceURL])
    }

    /// Copies the frame under the playhead (as rendered) to the clipboard.
    func copyCurrentFrame() {
        let size = exportSettings.outputSize(canvas: project.canvasSize())
        guard let image = previewRenderer.snapshot(size: size) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showNotice("Frame copied", symbol: "photo.on.rectangle")
    }

    // MARK: Thumbnails & waveform

    private func loadThumbnails() async {
        let url = project.sourceURL
        let duration = sourceDuration
        guard duration > 0 else { return }
        let count = min(max(Int(duration / 1.2), 12), 160)
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        let images = await Task.detached(priority: .utility) { () -> [VideoTimelineThumbnail] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 200)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            return times.compactMap { time in
                guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { return nil }
                return VideoTimelineThumbnail(time: time, image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }.value
        thumbnails = images
    }

    private func loadWaveform() async {
        let url = project.sourceURL
        let peaks = await Task.detached(priority: .utility) { () -> [Float]? in
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            let samplesPerBucket = Int(8_000 / VideoWaveform.bucketsPerSecond)
            var peaks: [Float] = []
            var current: Float = 0
            var counted = 0
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer else { continue }
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                    for index in 0..<count {
                        current = max(current, abs(floats[index]))
                        counted += 1
                        if counted >= samplesPerBucket {
                            peaks.append(current)
                            current = 0
                            counted = 0
                        }
                    }
                }
            }
            if counted > 0 { peaks.append(current) }
            // Normalize so quiet recordings still read.
            let top = peaks.max() ?? 0
            guard top > 0.0001 else { return peaks }
            let gain = min(1 / top, 4)
            return peaks.map { min($0 * gain, 1) }
        }.value
        if let peaks {
            waveform = VideoWaveform(peaks: peaks)
        }
    }

    // MARK: Formatting

    /// "4.2s", "42s", "1:05".
    static func format(_ seconds: Double) -> String {
        let safe = max(seconds, 0)
        if safe < 10 { return String(format: "%.1fs", safe) }
        if safe < 60 { return String(format: "%.0fs", safe) }
        return String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
    }

    static func timecode(_ seconds: Double) -> String {
        let safe = max(seconds, 0)
        let minutes = Int(safe) / 60
        let whole = Int(safe) % 60
        let tenths = Int((safe - Double(Int(safe))) * 10)
        return String(format: "%d:%02d.%d", minutes, whole, tenths)
    }

    static func formatScale(_ scale: Double) -> String {
        abs(scale - scale.rounded()) < 0.05 ? String(format: "%.0f×", scale) : String(format: "%.1f×", scale)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Hops export progress/cancel checks onto the main actor.
private final class VideoExportBridge: @unchecked Sendable {
    @MainActor private weak var model: VideoEditorModel?

    @MainActor
    init(model: VideoEditorModel) {
        self.model = model
    }

    @MainActor
    func progress(_ value: Double) {
        model?.updateExportProgress(value)
    }

    @MainActor
    func isCancelled() -> Bool {
        model?.exportIsCancelled ?? true
    }
}
