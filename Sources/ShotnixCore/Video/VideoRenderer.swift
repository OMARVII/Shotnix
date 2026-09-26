import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Metal

// MARK: - Cursor artwork

/// The pointer images a recording used, decoded once with a mip chain so
/// any on-screen size samples from a close-enough bitmap (crisp at 1x,
/// crisp at 4x zoom).
final class VideoCursorArtwork: @unchecked Sendable {
    struct Shape {
        let id: String
        /// Points, top-left origin.
        let hotSpot: CGPoint
        /// Points.
        let size: CGSize
        /// Largest first. Each image's extent starts at the origin.
        let mips: [CIImage]

        func image(forPixelHeight height: CGFloat) -> CIImage {
            var best = mips[0]
            for mip in mips where mip.extent.height >= height * 0.98 {
                best = mip
            }
            return best
        }
    }

    let shapes: [String: Shape]
    let events: [VideoCursorShapeEvent]
    let arrow: Shape
    private let eventTimes: [Double]
    /// The recording's own plain arrow (it matches the Mac's style) — found
    /// by its shape: tip at the top left, taller than wide. Not simply the
    /// first pointer: a recording started over text begins with the I-beam.
    private let capturedArrow: Shape?

    init(metadata: VideoDemoRecordingMetadata?) {
        var shapes: [String: Shape] = [:]
        for stored in metadata?.cursorShapes ?? [] {
            guard let image = CIImage(data: stored.pngData, options: [.applyOrientationProperty: true]) else { continue }
            let extent = image.extent
            let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            shapes[stored.id] = Shape(
                id: stored.id,
                hotSpot: CGPoint(x: stored.hotSpotX, y: stored.hotSpotY),
                size: CGSize(width: stored.width, height: stored.height),
                mips: Self.mipChain(normalized)
            )
        }
        self.shapes = shapes
        // Collapse flicker: a shape shown for under ~0.12s (a pointer that
        // passes over a link on its way somewhere) is dropped.
        let raw = (metadata?.cursorShapeEvents ?? []).filter { shapes[$0.shapeID] != nil }
        var stable: [VideoCursorShapeEvent] = []
        for (index, event) in raw.enumerated() {
            let next = index + 1 < raw.count ? raw[index + 1].time : Double.infinity
            if next - event.time < 0.12, index > 0 { continue }
            if stable.last?.shapeID == event.shapeID { continue }
            stable.append(event)
        }
        events = stable
        eventTimes = stable.map(\.time)
        arrow = Self.vectorArrow
        let uses = Dictionary(grouping: stable, by: \.shapeID).mapValues(\.count)
        capturedArrow = shapes.values
            .filter { shape in
                let x = shape.hotSpot.x / max(shape.size.width, 1)
                let y = shape.hotSpot.y / max(shape.size.height, 1)
                return x < 0.35 && y < 0.3 && shape.size.height > shape.size.width * 1.2
            }
            .max { (uses[$0.id] ?? 0) < (uses[$1.id] ?? 0) }
    }

    static let empty = VideoCursorArtwork(metadata: nil)

    var hasCapturedShapes: Bool { !events.isEmpty }

    func shape(at sourceTime: Double, alwaysArrow: Bool) -> Shape {
        guard !alwaysArrow, !eventTimes.isEmpty else {
            return alwaysArrow ? (capturedArrow ?? arrow) : arrow
        }
        var low = 0
        var high = eventTimes.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if eventTimes[mid] <= sourceTime {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return shapes[events[found].shapeID] ?? arrow
    }

    private static func mipChain(_ image: CIImage) -> [CIImage] {
        var mips: [CIImage] = []
        var current = rasterize(image) ?? image
        mips.append(current)
        while current.extent.height > 40 {
            let scaled = current.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 0.5,
                kCIInputAspectRatioKey: 1.0,
            ])
            let extent = scaled.extent
            let normalized = scaled.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            guard let raster = rasterize(normalized) else { break }
            current = raster
            mips.append(current)
        }
        return mips
    }

    private static func rasterize(_ image: CIImage) -> CIImage? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = VideoRenderContext.shared.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// A macOS-style arrow drawn as vectors — used when a recording carries
    /// no captured pointer images.
    private static let vectorArrow: Shape = {
        let pointSize = CGSize(width: 20, height: 30)
        let scale: CGFloat = 12
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Shape(id: "arrow", hotSpot: CGPoint(x: 3, y: 3), size: pointSize, mips: [CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))])
        }
        // Points in top-left space → context (bottom-left).
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: (pointSize.height - y) * scale) }
        let path = CGMutablePath()
        path.move(to: p(3, 3))
        path.addLine(to: p(3, 21.2))
        path.addLine(to: p(7.3, 17))
        path.addLine(to: p(10.3, 24.1))
        path.addLine(to: p(13.3, 22.8))
        path.addLine(to: p(10.4, 16.1))
        path.addLine(to: p(16.3, 16.1))
        path.closeSubpath()

        context.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2.6 * scale, color: CGColor(gray: 0, alpha: 0.42))
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(2.4 * scale)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2.4 * scale)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()

        let image = context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage(color: .black)
        return Shape(id: "arrow", hotSpot: CGPoint(x: 3, y: 3), size: pointSize, mips: mipChain(image))
    }()
}

/// Shared Core Image context for small one-off rasterizing jobs.
enum VideoRenderContext {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    static let shared: CIContext = makeContext()

    static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false,
            .name: "Shotnix Video",
        ]
        if let device {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }
}

// MARK: - Render plan

/// Everything the renderer needs for one project, compiled once per edit:
/// geometry, the camera path, the pointer path, and timeline-mapped
/// clicks and overlays. Immutable — safe to hand to an export thread.
final class VideoRenderPlan: @unchecked Sendable {
    struct Click {
        let start: Double
        let end: Double
        let x: Double
        let y: Double
    }

    struct Overlay {
        let effect: VideoDemoOverlayEffect
        let start: Double
        let end: Double
    }

    /// A shortcut on screen; repeats of the same combo stack into one
    /// badge with a counter (⌘Z ×3).
    struct Keystroke {
        let keys: [String]
        /// Timeline times of each press.
        var presses: [Double]
        var end: Double

        var start: Double { presses.first ?? 0 }

        func pressCount(at time: Double) -> Int { presses.filter { $0 <= time + 0.0001 }.count }
        func lastPress(at time: Double) -> Double { presses.last { $0 <= time + 0.0001 } ?? start }
    }

    struct Caption {
        let id: UUID
        let start: Double
        let end: Double
        let text: String
        /// Source-time word timings for highlighting.
        let words: [VideoCaptionWord]
    }

    /// How long a shortcut stays up after its last press (timeline seconds).
    static let keystrokeHold = 1.6

    let canvasSize: CGSize
    let stageRect: CGRect
    /// The recording's size after cropping.
    let sourceSize: CGSize
    /// The kept part of the recording (source-normalized, y down).
    let crop: VideoCropRect
    let background: VideoBackground
    let backgroundBlur: Double
    let cornerRadius: Double
    let shadow: Double
    let outline: Bool
    let fullBleed: Bool
    let segments: [VideoDemoTimelineSegment]
    let timelineDuration: Double
    let camera: VideoCameraTrack
    let cursorTrack: VideoCursorTrack?
    let cursorSettings: VideoCursorSettings
    let rendersCursor: Bool
    let artwork: VideoCursorArtwork
    let pointPixelScale: Double
    let clicks: [Click]
    let overlays: [Overlay]
    let motionBlur: Double
    let keystrokes: [Keystroke]
    let keystrokeStyle: VideoKeystrokeStyle
    let captions: [Caption]
    let captionStyle: VideoCaptionStyle
    /// Camera bubble settings — nil when the recording has no camera.
    let webcam: VideoWebcamSettings?

    struct CameraLayoutSpan {
        let start: Double
        let end: Double
        let layout: VideoCameraLayoutRegion.Layout
    }

    /// Timeline stretches where the camera changes layout.
    let cameraLayouts: [CameraLayoutSpan]
    /// The frame the video is exported at (differs from `canvasSize` when
    /// reframing: the scene is landscape, the output is not).
    let outputCanvasSize: CGSize
    /// Pan path for narrow outputs (nil when not reframing).
    let reframe: VideoReframe?

    /// The layout at `time` and how far into it we are (0 → 1 → 0 across
    /// the stretch, easing over half a second at each end).
    func cameraLayout(at time: Double) -> (layout: VideoCameraLayoutRegion.Layout, progress: Double)? {
        guard let span = cameraLayouts.first(where: { time >= $0.start && time <= $0.end }) else { return nil }
        let ramp = min(0.5, (span.end - span.start) / 3)
        let progress = ramp > 0 ? min((time - span.start) / ramp, (span.end - time) / ramp, 1) : 1
        return (span.layout, min(max(progress, 0), 1))
    }

    init(
        project: VideoDemoProject,
        sourceDuration: Double,
        artwork: VideoCursorArtwork,
        pointPixelScale: Double?,
        cursorTrack: VideoCursorTrack?,
        camera: VideoCameraTrack,
        hasWebcam: Bool = false,
        outputCanvasSize: CGSize? = nil,
        reframe: VideoReframe? = nil
    ) {
        webcam = hasWebcam ? project.webcam : nil
        canvasSize = project.canvasSize()
        self.outputCanvasSize = outputCanvasSize ?? project.canvasSize()
        self.reframe = reframe
        let layoutSegments = project.timelineSegments(totalDuration: sourceDuration)
        cameraLayouts = hasWebcam ? project.cameraLayouts.sorted { $0.start < $1.start }.compactMap { region in
            let ranges = VideoDemoProject.timelineRanges(sourceStart: region.start, sourceEnd: region.end, segments: layoutSegments)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return CameraLayoutSpan(start: first.lowerBound, end: last.upperBound, layout: region.layout)
        } : []
        stageRect = project.stageRect(in: canvasSize)
        crop = project.crop.normalized
        sourceSize = project.croppedSourceSize.width > 0 ? project.croppedSourceSize : CGSize(width: 1920, height: 1080)
        background = project.background
        backgroundBlur = project.backgroundBlur
        cornerRadius = project.effectiveCornerRadius
        shadow = project.effectiveShadow
        outline = project.outline && !project.usesRawSourceFrame
        fullBleed = project.usesRawSourceFrame
        segments = project.timelineSegments(totalDuration: sourceDuration)
        timelineDuration = segments.last?.timelineEnd ?? 0
        self.camera = camera
        self.cursorTrack = cursorTrack
        cursorSettings = project.cursor
        rendersCursor = project.rendersCursor && cursorTrack != nil
        self.artwork = artwork
        self.pointPixelScale = pointPixelScale ?? 2
        motionBlur = project.motionBlur

        let segments = self.segments
        let pointerEnd = cursorTrack?.endTime ?? .infinity
        clicks = project.clicksInsideCrop.sorted { $0.time < $1.time }.filter { $0.time < pointerEnd }.compactMap { click in
            guard let start = VideoDemoProject.timelineTimeIfIncluded(sourceTime: click.time, segments: segments) else { return nil }
            let end = VideoDemoProject.timelineTimeIfIncluded(sourceTime: click.time + click.pressDuration, segments: segments) ?? start + 0.12
            return Click(start: start, end: max(end, start + 0.05), x: click.x, y: click.y)
        }
        // Draw order follows the timeline lanes: lower lanes first, so the
        // highest lane ends up in front.
        let ordered = project.overlayEffects.sorted { $0.layer != $1.layer ? $0.layer < $1.layer : $0.time < $1.time }
        overlays = ordered.compactMap { effect in
            let ranges = VideoDemoProject.timelineRanges(sourceStart: effect.time, sourceEnd: effect.time + max(effect.duration, 0.1), segments: segments)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return Overlay(effect: effect, start: first.lowerBound, end: last.upperBound)
        }

        keystrokeStyle = project.keystrokeStyle
        let pressed: [(time: Double, keys: [String])] = project.keystrokes.sorted { $0.time < $1.time }.compactMap { event in
            guard let time = VideoDemoProject.timelineTimeIfIncluded(sourceTime: event.time, segments: segments) else { return nil }
            return (time, event.keys)
        }
        var keystrokes: [Keystroke] = []
        for press in pressed {
            if var last = keystrokes.last, last.keys == press.keys, press.time < last.end {
                last.presses.append(press.time)
                last.end = press.time + Self.keystrokeHold
                keystrokes[keystrokes.count - 1] = last
                continue
            }
            // A new combo replaces the one on screen.
            if var last = keystrokes.last, last.end > press.time {
                last.end = press.time
                keystrokes[keystrokes.count - 1] = last
            }
            keystrokes.append(Keystroke(keys: press.keys, presses: [press.time], end: press.time + Self.keystrokeHold))
        }
        self.keystrokes = keystrokes

        captionStyle = project.captionStyle
        captions = Self.visibleCaptions(project.captions, segments: segments)
    }

    /// Caption lines as they appear in the edited video: timeline times,
    /// and words cut from the video (an "um", a retake) left out — the
    /// preview, the export, and the subtitles file all use this.
    static func visibleCaptions(_ lines: [VideoCaptionLine], segments: [VideoDemoTimelineSegment]) -> [Caption] {
        // Included source spans, sorted, for a binary-search "was this word
        // cut?" (hundreds of lines × words on long takes).
        let included = segments.map { $0.clip.sourceStart...$0.clip.sourceEnd }.sorted { $0.lowerBound < $1.lowerBound }
        func isIncluded(_ time: Double) -> Bool {
            var low = 0
            var high = included.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if time < included[mid].lowerBound - 0.0001 {
                    high = mid - 1
                } else if time > included[mid].upperBound + 0.0001 {
                    low = mid + 1
                } else {
                    return true
                }
            }
            return false
        }
        return lines.sorted { $0.start < $1.start }.compactMap { line in
            let ranges = VideoDemoProject.timelineRanges(sourceStart: line.start, sourceEnd: max(line.end, line.start + 0.1), segments: segments)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            var text = line.text
            var words = line.words
            if !words.isEmpty {
                let kept = words.filter { isIncluded(($0.start + $0.end) / 2) }
                guard !kept.isEmpty else { return nil }
                if kept.count != words.count {
                    words = kept
                    text = VideoCaptionBuilder.joined(kept.map(\.text))
                }
            }
            return Caption(id: line.id, start: first.lowerBound, end: last.upperBound, text: text, words: words)
        }
    }

    func keystroke(at time: Double) -> Keystroke? {
        keystrokes.last { time >= $0.start && time < $0.end }
    }

    func caption(at time: Double) -> Caption? {
        captions.last { time >= $0.start && time < $0.end }
    }

    func sourceTime(forTimelineTime time: Double) -> Double {
        VideoDemoProject.sourceTime(forTimelineTime: time, segments: segments)
    }

    /// Canvas px per recorded source px at rest.
    var stageScale: CGFloat { stageRect.width / max(sourceSize.width, 1) }
}

// MARK: - Renderer

/// Composes one output frame: background, shadow, the rounded recording,
/// overlays, click effects, and the pointer — all placed through the
/// camera, in output pixels. Used verbatim by the live preview and by the
/// exporter, so the two can't disagree.
final class VideoFrameRenderer {
    struct Options {
        /// Show the whole frame (camera at rest) — used while aiming a zoom.
        var cameraOverride: VideoCameraState?
        /// Frames per second the output plays at — sizes motion blur.
        var frameRate: Double = 60
        /// Draft quality skips the most expensive passes (preview while
        /// scrubbing fast).
        var draft = false
        /// Pointer lookup at this SOURCE moment instead of the timeline's
        /// (previewing a clip edge that is being dragged).
        var sourceTimeOverride: Double?
        /// Just the recording, whole and uncropped (crop mode).
        var rawSource = false
        /// The camera frame for this moment (nil: no bubble).
        var webcamFrame: CIImage?
        /// Where the person is in `webcamFrame` (blur/remove/cutout looks).
        var webcamMask: CIImage?
        /// Render only the scene (reframing draws output layers itself).
        var sceneOnly = false
        /// The annotation being edited: drawn fully visible even inside its
        /// fade (a new one starts at the playhead, where it would be clear).
        var solidOverlay: UUID?
    }

    private struct BackgroundKey: Equatable {
        let background: VideoBackground
        let blur: Double
        let width: Int
        let height: Int
    }

    private struct ShadowKey: Equatable {
        let stage: CGRect
        let radius: Double
        let shadow: Double
        let k: Double
    }

    private var backgroundCache: (key: BackgroundKey, image: CIImage)?
    private var shadowCache: (key: ShadowKey, image: CIImage)?
    private var overlayCache: [String: CIImage] = [:]
    private var overlayCacheOrder: [String] = []
    private lazy var ringImage: CIImage = Self.makeRingImage()
    private let supportsSmoothCorners: Bool

    init() {
        supportsSmoothCorners = CIFilter(name: "CIRoundedRectangleGenerator")?.inputKeys.contains("inputSmoothness") ?? false
    }

    struct Geometry {
        let canvas: CGSize
        let output: CGSize
        let k: CGFloat
        let camera: VideoCameraState

        var pixelScale: CGFloat { CGFloat(camera.scale) * k }

        /// Logical canvas coordinates (bottom-left origin) → output pixels.
        var transform: CGAffineTransform {
            let s = pixelScale
            let cx = CGFloat(camera.centerX) * canvas.width
            let cy = (1 - CGFloat(camera.centerY)) * canvas.height
            return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: output.width / 2 - cx * s, ty: output.height / 2 - cy * s)
        }

        /// Logical point (TOP-left origin) → output pixel (bottom-left).
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: canvas.height - p.y).applying(transform)
        }

        /// Logical rect (TOP-left origin) → output rect (bottom-left).
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: canvas.height - r.maxY, width: r.width, height: r.height).applying(transform)
        }
    }

    func render(
        source: CIImage?,
        timelineTime: Double,
        plan: VideoRenderPlan,
        outputSize: CGSize,
        options: Options = Options()
    ) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        if options.rawSource {
            let black = CIImage(color: CIColor.black).cropped(to: outputRect)
            guard let source else { return black }
            let extent = source.extent
            let scale = min(outputSize.width / max(extent.width, 1), outputSize.height / max(extent.height, 1))
            let placed = source
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (outputSize.width - extent.width * scale) / 2, y: (outputSize.height - extent.height * scale) / 2))
            return placed.composited(over: black).cropped(to: outputRect)
        }
        // Reframing: render the landscape scene at the output's height,
        // crop the pointer-following window, then add the output layers.
        if let reframe = plan.reframe, !options.sceneOnly {
            let sceneSize = CGSize(width: (outputSize.height * plan.canvasSize.width / max(plan.canvasSize.height, 1)).rounded(), height: outputSize.height)
            var sceneOptions = options
            sceneOptions.sceneOnly = true
            let scene = render(source: source, timelineTime: timelineTime, plan: plan, outputSize: sceneSize, options: sceneOptions)
            let x0 = reframe.windowOrigin(at: timelineTime, sceneWidth: sceneSize.width)
            let framed = scene.transformed(by: CGAffineTransform(translationX: -x0, y: 0)).cropped(to: outputRect)
            let k = sceneSize.width / max(plan.canvasSize.width, 1)
            let camera = options.cameraOverride ?? plan.camera.state(at: timelineTime)
            let geometry = Geometry(canvas: plan.canvasSize, output: sceneSize, k: k, camera: camera)
            let stageOut = geometry.rect(plan.stageRect).offsetBy(dx: -x0, dy: 0)
            let sourceTime = options.sourceTimeOverride ?? plan.sourceTime(forTimelineTime: timelineTime)
            return drawOutputLayers(on: framed, plan: plan, timelineTime: timelineTime, sourceTime: sourceTime, cameraScale: camera.scale, stageOut: stageOut, outputSize: outputSize, k: k, options: options)
                .cropped(to: outputRect)
        }
        let k = outputSize.width / max(plan.canvasSize.width, 1)
        let camera = options.cameraOverride ?? plan.camera.state(at: timelineTime)
        let geometry = Geometry(canvas: plan.canvasSize, output: outputSize, k: k, camera: camera)
        let sourceTime = options.sourceTimeOverride ?? plan.sourceTime(forTimelineTime: timelineTime)

        // 1. Background (cached at rest resolution, moved by the camera).
        var scene: CIImage
        if plan.fullBleed {
            scene = CIImage(color: CIColor.black).cropped(to: outputRect)
        } else {
            let background = backgroundImage(plan: plan, k: k)
            scene = background.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k).concatenating(geometry.transform))
        }

        // 2. Shadow.
        if !plan.fullBleed, plan.shadow > 0.01 {
            let shadow = shadowImage(plan: plan, k: k)
            scene = shadow.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k).concatenating(geometry.transform)).composited(over: scene)
        }

        // 3. The recording.
        let stageOut = geometry.rect(plan.stageRect)
        let radius = CGFloat(plan.cornerRadius) * geometry.pixelScale
        if let source {
            let video = placedVideo(source, plan: plan, geometry: geometry, stageOut: stageOut, draft: options.draft)
            if plan.fullBleed || radius < 0.5 {
                scene = video.cropped(to: stageOut).composited(over: scene)
            } else {
                let mask = roundedRect(stageOut, radius: radius, color: CIColor.white)
                let clipped = video.cropped(to: stageOut).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                scene = clipped.composited(over: scene)
            }
        } else {
            let placeholder = roundedRect(stageOut, radius: radius, color: CIColor(red: 0.08, green: 0.08, blue: 0.09))
            scene = placeholder.composited(over: scene)
        }

        if plan.outline, radius >= 0 {
            let width = max(1, 1.0 * geometry.pixelScale)
            let outer = roundedRect(stageOut, radius: radius, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.16))
            let inner = roundedRect(stageOut.insetBy(dx: width, dy: width), radius: max(radius - width, 0), color: CIColor.white)
            let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            scene = ring.composited(over: scene)
        }

        // 4. Overlays (text, arrows, highlights, blur).
        for overlay in plan.overlays where timelineTime >= overlay.start && timelineTime <= overlay.end {
            scene = composite(overlay: overlay, over: scene, plan: plan, geometry: geometry, time: timelineTime, solid: overlay.effect.id == options.solidOverlay)
        }

        // 5. Camera motion blur.
        if !options.draft, plan.motionBlur > 0.01, options.cameraOverride == nil {
            scene = cameraMotionBlur(scene, plan: plan, geometry: geometry, time: timelineTime, frameRate: options.frameRate)
        }

        // 6. Click ripples and the pointer.
        if plan.rendersCursor, let track = plan.cursorTrack {
            let alpha = track.alpha(at: sourceTime)
            if alpha > 0.01 {
                scene = drawPointer(on: scene, track: track, plan: plan, geometry: geometry, timelineTime: timelineTime, sourceTime: sourceTime, alpha: alpha, options: options)
            }
        } else if plan.cursorSettings.clickEffect == .ripple, !plan.clicks.isEmpty {
            // Baked-cursor recordings still get ripples at the click spots.
            scene = drawRipples(on: scene, plan: plan, geometry: geometry, time: timelineTime, pointerHeight: 28 * geometry.pixelScale * plan.stageScale * CGFloat(plan.pointPixelScale))
        }

        // 7. The camera, captions, and shortcuts — on the output, not the
        // zoomed video, so they stay put and readable.
        if !options.sceneOnly {
            scene = drawOutputLayers(on: scene, plan: plan, timelineTime: timelineTime, sourceTime: sourceTime, cameraScale: camera.scale, stageOut: stageOut, outputSize: outputSize, k: k, options: options)
        }

        return scene.cropped(to: outputRect)
    }

    /// Camera, captions, and shortcuts over a finished scene, in output
    /// pixels.
    private func drawOutputLayers(
        on input: CIImage,
        plan: VideoRenderPlan,
        timelineTime: Double,
        sourceTime: Double,
        cameraScale: Double,
        stageOut: CGRect,
        outputSize: CGSize,
        k: CGFloat,
        options: Options
    ) -> CIImage {
        var scene = input
        let outputRect = CGRect(origin: .zero, size: outputSize)
        /// Where the camera bubble sits — text steps around it (fully, or
        /// easing away while a layout takes the camera elsewhere).
        var avoid: CGRect?
        var avoidWeight: CGFloat = 1
        if let webcam = plan.webcam, webcam.visible, let frame = options.webcamFrame {
            let bubble = Self.webcamRect(webcam, outputSize: outputSize, cameraScale: cameraScale)
            let bubbleRadius = Self.webcamCornerRadius(webcam, rect: bubble)
            let camera = CameraPicture(frame: frame, mask: options.webcamMask, settings: webcam)
            switch plan.cameraLayout(at: timelineTime) {
            case let (layout, progress)? where layout == .fullscreen:
                // The bubble grows to fill the frame.
                let e = CGFloat(VideoCameraEasing.spring(progress))
                let rect = Self.lerp(bubble, outputRect, e)
                let look = CameraLook(radius: bubbleRadius + (0 - bubbleRadius) * e, rim: Double(1 - e), shadow: Double(1 - e), opacity: 1, cutout: webcam.shape == .cutout && e < 0.5)
                scene = drawCamera(camera, in: rect, look: look, plan: plan, outputSize: outputSize, k: k, over: scene)
                avoid = bubble
                avoidWeight = 1 - e
            case let (layout, progress)? where layout == .sideBySide:
                scene = drawSideBySide(scene: scene, camera: camera, bubble: bubble, bubbleRadius: bubbleRadius, progress: progress, stage: stageOut, plan: plan, outputSize: outputSize, k: k)
                avoid = bubble
                avoidWeight = 1 - CGFloat(VideoCameraEasing.spring(progress))
            case let (layout, progress)? where layout == .hidden:
                // Fades and settles away; fully hidden in the middle.
                if progress < 0.999 {
                    let shrink = 1 - 0.12 * CGFloat(progress)
                    let rect = CGRect(x: bubble.midX - bubble.width * shrink / 2, y: bubble.midY - bubble.height * shrink / 2, width: bubble.width * shrink, height: bubble.height * shrink)
                    let look = CameraLook(radius: bubbleRadius * shrink, rim: 1, shadow: 1, opacity: 1 - progress, cutout: webcam.shape == .cutout)
                    scene = drawCamera(camera, in: rect, look: look, plan: plan, outputSize: outputSize, k: k, over: scene)
                }
                avoid = bubble
                avoidWeight = CGFloat(1 - progress)
            default:
                let look = CameraLook(radius: bubbleRadius, rim: 1, shadow: 1, opacity: 1, cutout: webcam.shape == .cutout)
                scene = drawCamera(camera, in: bubble, look: look, plan: plan, outputSize: outputSize, k: k, over: scene)
                avoid = bubble
            }
        }
        scene = drawTextLayers(on: scene, plan: plan, outputSize: outputSize, timelineTime: timelineTime, sourceTime: sourceTime, avoid: avoid, avoidWeight: avoidWeight)
        return scene
    }

    // MARK: Layers

    private func backgroundImage(plan: VideoRenderPlan, k: CGFloat) -> CIImage {
        let width = max(Int((plan.canvasSize.width * k).rounded()), 2)
        let height = max(Int((plan.canvasSize.height * k).rounded()), 2)
        let key = BackgroundKey(background: plan.background, blur: plan.backgroundBlur, width: width, height: height)
        if let cached = backgroundCache, cached.key == key { return cached.image }
        let rendered = VideoBackgroundRenderer.image(for: plan.background, blur: plan.backgroundBlur, size: CGSize(width: width, height: height))
        // Rasterize once: the mesh and blur passes are too heavy to redo per frame.
        let image: CIImage
        if let cgImage = VideoRenderContext.shared.createCGImage(rendered, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            image = CIImage(cgImage: cgImage)
        } else {
            image = rendered
        }
        backgroundCache = (key, image)
        return image
    }

    private func shadowImage(plan: VideoRenderPlan, k: CGFloat) -> CIImage {
        let key = ShadowKey(stage: plan.stageRect, radius: plan.cornerRadius, shadow: plan.shadow, k: Double(k))
        if let cached = shadowCache, cached.key == key { return cached.image }
        let canvas = plan.canvasSize
        let unit = min(canvas.width, canvas.height) / 1080
        let strength = CGFloat(plan.shadow)
        let blur = (14 + 36 * strength) * unit * k
        let offset = (6 + 16 * strength) * unit * k
        let stage = CGRect(
            x: plan.stageRect.minX * k,
            y: (canvas.height - plan.stageRect.maxY) * k,
            width: plan.stageRect.width * k,
            height: plan.stageRect.height * k
        )
        let body = roundedRect(stage.insetBy(dx: stage.width * 0.01, dy: 0), radius: CGFloat(plan.cornerRadius) * k, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.28 + 0.5 * strength))
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
        // No clampedToExtent here: the body is a shape on transparency, and
        // clamping would smear its edge pixels across the whole canvas.
        let blurred = body.applyingGaussianBlur(sigma: Double(blur) * 0.5)
            .cropped(to: CGRect(x: 0, y: 0, width: canvas.width * k, height: canvas.height * k))
        // A tight contact shadow under the soft one grounds the window.
        let contact = roundedRect(stage, radius: CGFloat(plan.cornerRadius) * k, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.18 * strength))
            .transformed(by: CGAffineTransform(translationX: 0, y: -1.5 * unit * k))
            .applyingGaussianBlur(sigma: Double(3 * unit * k))
        let combined = contact.composited(over: blurred)
        let extent = CGRect(x: 0, y: 0, width: canvas.width * k, height: canvas.height * k)
        let image: CIImage
        if let cgImage = VideoRenderContext.shared.createCGImage(combined, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            image = CIImage(cgImage: cgImage)
        } else {
            image = combined
        }
        shadowCache = (key, image)
        return image
    }

    private func placedVideo(_ fullSource: CIImage, plan: VideoRenderPlan, geometry: Geometry, stageOut: CGRect, draft: Bool = false) -> CIImage {
        // Crop first (source-normalized, y down → pixels, y up).
        var source = fullSource
        if !plan.crop.isFull {
            let full = fullSource.extent
            let cropRect = CGRect(
                x: full.minX + full.width * CGFloat(plan.crop.x),
                y: full.minY + full.height * CGFloat(1 - plan.crop.y - plan.crop.height),
                width: full.width * CGFloat(plan.crop.width),
                height: full.height * CGFloat(plan.crop.height)
            ).integral
            source = fullSource.cropped(to: cropRect)
        }
        let extent = source.extent
        let normalized = extent.origin == .zero ? source : source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let effective = stageOut.width / max(extent.width, 1)
        if effective < 0.8, !draft {
            // Downscaling a sharp screen recording needs a real filter, or
            // text shimmers — Lanczos once, then a pure translation.
            let scaled = normalized.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: effective,
                kCIInputAspectRatioKey: 1.0,
            ])
            let scaledExtent = scaled.extent
            let sx = stageOut.width / max(scaledExtent.width, 1)
            let sy = stageOut.height / max(scaledExtent.height, 1)
            return scaled.transformed(by: CGAffineTransform(translationX: -scaledExtent.minX, y: -scaledExtent.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: stageOut.minX, y: stageOut.minY)))
        }
        let sx = stageOut.width / max(extent.width, 1)
        let sy = stageOut.height / max(extent.height, 1)
        return normalized.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: stageOut.minX, y: stageOut.minY)))
    }

    func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        guard rect.width > 0, rect.height > 0 else { return CIImage.empty() }
        let clamped = min(max(radius, 0), min(rect.width, rect.height) / 2)
        guard clamped > 0.25 else { return CIImage(color: color).cropped(to: rect) }
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")
        filter?.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter?.setValue(clamped, forKey: "inputRadius")
        filter?.setValue(color, forKey: kCIInputColorKey)
        if supportsSmoothCorners {
            // Continuous ("squircle") corners, like the system's windows.
            filter?.setValue(1.0, forKey: "inputSmoothness")
        }
        return filter?.outputImage?.cropped(to: rect) ?? CIImage(color: color).cropped(to: rect)
    }

    // MARK: Overlays

    private func composite(overlay: VideoRenderPlan.Overlay, over scene: CIImage, plan: VideoRenderPlan, geometry: Geometry, time: Double, solid: Bool = false) -> CIImage {
        let effect = overlay.effect
        let stage = plan.stageRect
        let width = stage.width * CGFloat(min(max(effect.width, 0.02), 1))
        let height = stage.height * CGFloat(min(max(effect.height, 0.02), 1))
        let center = CGPoint(x: stage.minX + stage.width * CGFloat(effect.x), y: stage.minY + stage.height * CGFloat(effect.y))
        let logical = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let rect = geometry.rect(logical)

        // Fade in and out (blur stays fully opaque while visible).
        let fade = min(0.18, (overlay.end - overlay.start) / 3)
        var opacity = 1.0
        if effect.kind != .blur, fade > 0, !solid {
            opacity = min((time - overlay.start) / fade, (overlay.end - time) / fade, 1)
        }
        opacity = min(max(opacity, 0), 1)
        guard opacity > 0.001 else { return scene }

        let unit = geometry.pixelScale * min(plan.canvasSize.width, plan.canvasSize.height) / 1080
        switch effect.kind {
        case .blur:
            let sigma = Double(max(rect.width, rect.height) * 0.08 + 14 * unit)
            let blurred = scene.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
            // Darken slightly so blurred text can't be half-read.
            let dimmed = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.8, kCIInputBrightnessKey: -0.04])
            let mask = roundedRect(rect, radius: 12 * unit, color: CIColor.white)
            let clipped = dimmed.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            return clipped.composited(over: scene)
        case .highlight:
            let tint = effect.resolvedColor
            let stroke = max(3 * unit * effect.thickness.scale, 1.5)
            let outer = roundedRect(rect.insetBy(dx: -stroke / 2, dy: -stroke / 2), radius: 14 * unit + stroke / 2, color: CIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 0.95 * opacity))
            let inner = roundedRect(rect.insetBy(dx: stroke / 2, dy: stroke / 2), radius: max(14 * unit - stroke / 2, 0), color: CIColor.white)
            let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            let fill = roundedRect(rect, radius: 14 * unit, color: CIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 0.10 * opacity))
            let glow = ring.applyingGaussianBlur(sigma: Double(6 * unit)).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55)])
            return ring.composited(over: fill.composited(over: glow.composited(over: scene)))
        case .arrow:
            // From its tail to its head, whichever way it points.
            let ends = effect.arrowPoints
            func output(_ p: CGPoint) -> CGPoint {
                geometry.point(CGPoint(x: stage.minX + stage.width * p.x, y: stage.minY + stage.height * p.y))
            }
            guard let arrow = arrowImage(from: output(ends.tail), to: output(ends.head), unit: unit, color: effect.resolvedColor, thickness: effect.thickness) else { return scene }
            return faded(arrow.image, opacity).transformed(by: CGAffineTransform(translationX: arrow.origin.x, y: arrow.origin.y)).composited(over: scene)
        case .spotlight:
            // The picture dims around the spot (inside the recording's frame).
            let stageOut = geometry.rect(plan.stageRect)
            let dim = roundedRect(stageOut, radius: CGFloat(plan.cornerRadius) * geometry.pixelScale, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.58 * opacity))
            let hole = effect.shape == .ellipse ? ellipseMask(rect, feather: 3 * unit) : roundedRect(rect, radius: 12 * unit, color: CIColor.white)
            return dim.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: hole]).composited(over: scene)
        case .text:
            guard let image = textImage(effect.text, box: rect.size, unit: unit, background: effect.resolvedColor) else { return scene }
            let x = rect.midX - image.extent.width / 2
            let y = rect.midY - image.extent.height / 2
            return faded(image, opacity).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded())).composited(over: scene)
        }
    }

    /// The color matrix works on un-premultiplied color, so only alpha is
    /// scaled (scaling RGB too would darken every fade: opacity squared).
    private func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(opacity, 0))),
        ])
    }

    private func cached(_ key: String, make: () -> CIImage?) -> CIImage? {
        if let image = overlayCache[key] { return image }
        guard let image = make() else { return nil }
        overlayCache[key] = image
        overlayCacheOrder.append(key)
        if overlayCacheOrder.count > 48 {
            overlayCache.removeValue(forKey: overlayCacheOrder.removeFirst())
        }
        return image
    }

    /// A soft-edged ellipse filling `rect` (white inside).
    private func ellipseMask(_ rect: CGRect, feather: CGFloat) -> CIImage {
        guard rect.width > 1, rect.height > 1 else { return CIImage.empty() }
        // A unit-circle gradient, stretched into the ellipse.
        let radius: CGFloat = 1000
        let soft = min(feather / max(min(rect.width, rect.height) / 2, 1), 0.5) * radius
        let circle = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": radius - soft,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)) ?? CIImage.empty()
        return circle.transformed(by: CGAffineTransform(scaleX: rect.width / (radius * 2), y: rect.height / (radius * 2))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }

    /// An arrow from `tail` to `head` (output pixels, y up), and where its
    /// image goes.
    private func arrowImage(from tail: CGPoint, to head: CGPoint, unit: CGFloat, color tint: VideoRGBA, thickness: VideoOverlayThickness) -> (image: CIImage, origin: CGPoint)? {
        let length = hypot(head.x - tail.x, head.y - tail.y)
        guard length > 2 else { return nil }
        let line = max(7 * unit * thickness.scale, 2)
        // Long arrows keep a head of the usual size.
        let headSize = min(max(line * 3.4, min(length * 0.2, 56 * unit)), length * 0.6)
        // Room for the head and the shadow around the line's box.
        let pad = headSize + 10 * unit + 4
        let origin = CGPoint(x: (min(tail.x, head.x) - pad).rounded(.down), y: (min(tail.y, head.y) - pad).rounded(.down))
        let width = Int((max(tail.x, head.x) + pad - origin.x).rounded(.up))
        let height = Int((max(tail.y, head.y) + pad - origin.y).rounded(.up))
        let start = CGPoint(x: tail.x - origin.x, y: tail.y - origin.y)
        let end = CGPoint(x: head.x - origin.x, y: head.y - origin.y)
        let key = "arrow-\(Int(start.x * 2))-\(Int(start.y * 2))-\(Int(end.x * 2))-\(Int(end.y * 2))-\(width)x\(height)-\(Int(unit * 100))-\(tint.hashValue)-\(thickness.rawValue)"
        let image = cached(key) {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = headSize
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: CGPoint(x: end.x - cos(angle) * head * 0.55, y: end.y - sin(angle) * head * 0.55))
            context.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: 8 * unit, color: CGColor(gray: 0, alpha: 0.35))
            context.setLineCap(.round)
            context.setLineWidth(line)
            context.setStrokeColor(CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 1))
            context.addPath(path)
            context.strokePath()
            let headPath = CGMutablePath()
            headPath.move(to: end)
            headPath.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
            headPath.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
            headPath.closeSubpath()
            context.setFillColor(CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 1))
            context.setLineJoin(.round)
            context.addPath(headPath)
            context.fillPath()
            return context.makeImage().map { CIImage(cgImage: $0) }
        }
        return image.map { ($0, origin) }
    }

    private func textImage(_ text: String, box: CGSize, unit: CGFloat, background: VideoRGBA) -> CIImage? {
        let content = text.isEmpty ? " " : text
        let fontSize = max(min(box.height * 0.46, 64 * unit), 8)
        let key = "text-\(content.hashValue)-\(Int(fontSize * 4))-\(Int(box.width))-\(background.hashValue)"
        return cached(key) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            // No tag: white text with a soft shadow. A light, mostly solid
            // tag gets dark text; a see-through one keeps white text (with
            // the shadow once it's faint), whatever its hue.
            let plain = background.a < 0.05
            let ink: NSColor = background.a >= 0.6 && background.luminance > 0.62 ? NSColor(white: 0.08, alpha: 1) : .white
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]
            if background.a < 0.5 {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
                shadow.shadowBlurRadius = fontSize * 0.22
                shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.05)
                attributes[.shadow] = shadow
            }
            let attributed = NSAttributedString(string: content, attributes: attributes)
            let maxTextWidth = max(box.width - fontSize * 1.4, fontSize)
            let bounds = attributed.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let padX = fontSize * 0.75
            let padY = fontSize * 0.42
            let width = Int(ceil(min(bounds.width, maxTextWidth) + padX * 2))
            let height = Int(ceil(bounds.height + padY * 2))
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: min(CGFloat(height) / 2, fontSize * 0.7), cornerHeight: min(CGFloat(height) / 2, fontSize * 0.7), transform: nil)
            if !plain {
                context.addPath(pill)
                context.setFillColor(CGColor(srgbRed: background.r, green: background.g, blue: background.b, alpha: background.a))
                context.fillPath()
                context.addPath(pill)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
                context.setLineWidth(max(unit, 1))
                context.strokePath()
            }
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            attributed.draw(with: CGRect(x: padX, y: padY, width: CGFloat(width) - padX * 2, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage().map { CIImage(cgImage: $0) }
        }
    }

    // MARK: Captions and shortcuts

    private func drawTextLayers(on scene: CIImage, plan: VideoRenderPlan, outputSize: CGSize, timelineTime: Double, sourceTime: Double, avoid: CGRect?, avoidWeight: CGFloat = 1) -> CIImage {
        var output = scene
        let shortSide = min(outputSize.width, outputSize.height)
        let margin = (shortSide * 0.055).rounded()
        let spacing = (shortSide * 0.016).rounded()
        // Distance used from each edge so layers on the same edge stack.
        var usedBottom = margin
        var usedTop = margin

        func place(_ image: CIImage, position: VideoTextPosition, opacity: Double, pop: CGFloat) {
            let size = image.extent.size
            let x = ((outputSize.width - size.width) / 2).rounded()
            var y: CGFloat
            if position == .bottom {
                y = usedBottom
                // Step above the camera bubble rather than run under it.
                if let avoid, avoidWeight > 0.001, CGRect(x: x, y: y, width: size.width, height: size.height).intersects(avoid.insetBy(dx: -spacing, dy: -spacing)) {
                    y += (avoid.maxY + spacing - y) * avoidWeight
                }
                usedBottom = y + size.height + spacing
            } else {
                y = outputSize.height - usedTop - size.height
                if let avoid, avoidWeight > 0.001, CGRect(x: x, y: y, width: size.width, height: size.height).intersects(avoid.insetBy(dx: -spacing, dy: -spacing)) {
                    y += (avoid.minY - spacing - size.height - y) * avoidWeight
                }
                usedTop = outputSize.height - y + spacing
            }
            var placed = image.transformed(by: CGAffineTransform(translationX: x, y: y.rounded()))
            if pop < 0.999 {
                let center = CGPoint(x: x + size.width / 2, y: y + size.height / 2)
                placed = placed.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(scaleX: pop, y: pop))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            }
            output = faded(placed, opacity).composited(over: output)
        }

        if plan.captionStyle.visible, let caption = plan.caption(at: timelineTime) {
            let opacity = Self.fade(time: timelineTime, start: caption.start, end: caption.end, fadeIn: 0.08, fadeOut: 0.12)
            if opacity > 0.001, let image = captionImage(caption, style: plan.captionStyle, sourceTime: sourceTime, outputSize: outputSize) {
                place(image, position: plan.captionStyle.position, opacity: opacity, pop: 1)
            }
        }

        if plan.keystrokeStyle.visible, let stroke = plan.keystroke(at: timelineTime) {
            let opacity = Self.fade(time: timelineTime, start: stroke.start, end: stroke.end, fadeIn: 0.1, fadeOut: 0.22)
            let sincePress = timelineTime - stroke.lastPress(at: timelineTime)
            // A small spring pop on every press.
            let t = min(max(sincePress / 0.16, 0), 1)
            let pop = CGFloat(0.9 + 0.1 * VideoCameraEasing.spring(t))
            if opacity > 0.001, let image = keystrokeImage(stroke.keys, count: stroke.pressCount(at: timelineTime), style: plan.keystrokeStyle, outputSize: outputSize) {
                place(image, position: plan.keystrokeStyle.position, opacity: opacity, pop: pop)
            }
        }
        return output
    }

    // MARK: Camera bubble

    /// Where the bubble sits in output pixels (bottom-left origin).
    static func webcamRect(_ settings: VideoWebcamSettings, outputSize: CGSize, cameraScale: Double = 1) -> CGRect {
        let shortSide = min(outputSize.width, outputSize.height)
        var height = shortSide * CGFloat(min(max(settings.size, VideoWebcamSettings.sizeRange.lowerBound), VideoWebcamSettings.sizeRange.upperBound))
        if settings.shrinkWhenZoomed {
            // Eases down to 70% as the camera pushes in.
            let amount = min(max((cameraScale - 1) / 0.6, 0), 1)
            height *= CGFloat(1 - 0.3 * VideoCameraEasing.spring(amount))
        }
        let width = height * settings.shape.aspect
        let margin = (shortSide * 0.04).rounded()
        let unit = settings.anchor.unit
        let x = margin + (outputSize.width - width - margin * 2) * unit.x
        let yFromTop = margin + (outputSize.height - height - margin * 2) * unit.y
        return CGRect(x: x.rounded(), y: (outputSize.height - yFromTop - height).rounded(), width: width.rounded(), height: height.rounded())
    }

    static func webcamCornerRadius(_ settings: VideoWebcamSettings, rect: CGRect) -> CGFloat {
        switch settings.shape {
        case .circle: return min(rect.width, rect.height) / 2
        case .square: return rect.height * 0.22
        case .rectangle: return rect.height * 0.12
        case .cutout: return 0
        }
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    struct CameraPicture {
        let frame: CIImage
        let mask: CIImage?
        let settings: VideoWebcamSettings
    }

    struct CameraLook {
        var radius: CGFloat
        /// 0…1 strength of the thin light rim.
        var rim: Double
        /// 0…1 strength of the soft drop shadow.
        var shadow: Double
        var opacity: Double
        /// Just the person — no card (needs a person mask).
        var cutout: Bool
    }

    /// Aspect-fills the camera (and its mask) into `rect`, mirrored like a
    /// selfie when set, with the chosen backdrop.
    private func placedCamera(_ camera: CameraPicture, in rect: CGRect, plan: VideoRenderPlan, k: CGFloat) -> (picture: CIImage, person: CIImage?) {
        let frame = camera.frame
        let extent = frame.extent
        var transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        if camera.settings.mirror {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
        }
        let scale = max(rect.width / max(extent.width, 1), rect.height / max(extent.height, 1))
        transform = transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX - extent.width * scale / 2, y: rect.midY - extent.height * scale / 2))
        var picture = frame.transformed(by: transform)
        if scale < 0.8 { picture = picture.samplingLinear() }
        picture = picture.cropped(to: rect)

        guard camera.settings.needsPersonMask, let mask = camera.mask, mask.extent.width > 0, mask.extent.height > 0 else {
            return (picture, nil)
        }
        // The mask covers the whole frame at its own resolution.
        let toFrame = CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let feather = Double(max(rect.height * 0.004, 0.8))
        let person = mask.transformed(by: toFrame).transformed(by: transform)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: feather)
            .cropped(to: rect)

        let backdrop: CIImage
        switch camera.settings.backdrop {
        case .blur:
            backdrop = picture.clampedToExtent().applyingGaussianBlur(sigma: Double(rect.height * 0.035)).cropped(to: rect)
        case .remove, .original:
            // The video's own background shows behind you.
            backdrop = backgroundImage(plan: plan, k: k).clampedToExtent().cropped(to: rect)
        }
        if camera.settings.backdrop != .original || camera.settings.shape == .cutout {
            picture = picture.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop,
                kCIInputMaskImageKey: person,
            ])
        }
        return (picture, person)
    }

    private func drawCamera(_ camera: CameraPicture, in rect: CGRect, look: CameraLook, plan: VideoRenderPlan, outputSize: CGSize, k: CGFloat, over scene: CIImage) -> CIImage {
        guard rect.width > 2, rect.height > 2, look.opacity > 0.001 else { return scene }
        let shortSide = min(outputSize.width, outputSize.height)
        let placed = placedCamera(camera, in: rect, plan: plan, k: k)

        if look.cutout, let person = placed.person {
            // Just you: the picture where the mask is, a soft shadow below.
            let alpha = person.applyingFilter("CIMaskToAlpha")
            let cut = placed.picture.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
            let shadow = alpha
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.45 * look.shadow)),
                ])
                .transformed(by: CGAffineTransform(translationX: 0, y: -shortSide * 0.006))
                // Not clamped: a mask that touches the bubble's edge would
                // smear its edge pixels outward into a hard gray band.
                .applyingGaussianBlur(sigma: Double(shortSide * 0.01))
                .cropped(to: rect.insetBy(dx: -shortSide * 0.05, dy: -shortSide * 0.05))
            return faded(cut.composited(over: shadow), look.opacity).composited(over: scene)
        }

        let radius = max(look.radius, 0)
        let mask = roundedRect(rect, radius: radius, color: CIColor.white)
        let card = placed.picture.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        var layer = card
        if look.shadow > 0.01 {
            let shadowOffset = shortSide * 0.008
            let shadow = roundedRect(rect.offsetBy(dx: 0, dy: -shadowOffset), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(0.4 * look.shadow)))
                .applyingGaussianBlur(sigma: Double(shortSide * 0.014))
            layer = card.composited(over: shadow)
        }
        if look.rim > 0.01 {
            let rim = max(1.5, shortSide * 0.0028)
            let outer = roundedRect(rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(0.85 * look.rim)))
            let inner = roundedRect(rect.insetBy(dx: rim, dy: rim), radius: max(radius - rim, 0), color: CIColor.white)
            let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            layer = ring.composited(over: layer)
        }
        return faded(layer, look.opacity).composited(over: scene)
    }

    /// Screen on one side, camera on the other (stacked on tall outputs);
    /// `progress` animates from the normal layout into it and back.
    private func drawSideBySide(scene: CIImage, camera: CameraPicture, bubble: CGRect, bubbleRadius: CGFloat, progress: Double, stage: CGRect, plan: VideoRenderPlan, outputSize: CGSize, k: CGFloat) -> CIImage {
        let e = CGFloat(VideoCameraEasing.spring(progress))
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let shortSide = min(outputSize.width, outputSize.height)
        let margin = shortSide * 0.05
        let gap = shortSide * 0.035
        let cameraPanel: CGRect
        let screenPanel: CGRect
        if outputSize.width >= outputSize.height {
            let cameraWidth = (outputSize.width - margin * 2 - gap) * 0.36
            cameraPanel = CGRect(x: outputSize.width - margin - cameraWidth, y: margin, width: cameraWidth, height: outputSize.height - margin * 2)
            screenPanel = CGRect(x: margin, y: margin, width: outputSize.width - margin * 2 - gap - cameraWidth, height: outputSize.height - margin * 2)
        } else {
            let cameraHeight = (outputSize.height - margin * 2 - gap) * 0.4
            cameraPanel = CGRect(x: margin, y: margin, width: outputSize.width - margin * 2, height: cameraHeight)
            screenPanel = CGRect(x: margin, y: margin + cameraHeight + gap, width: outputSize.width - margin * 2, height: outputSize.height - margin * 2 - gap - cameraHeight)
        }
        // The visible part of the recording, fitted into its panel.
        var visible = stage.intersection(outputRect)
        if visible.isNull || visible.width < 4 || visible.height < 4 { visible = outputRect }
        let fit = min(screenPanel.width / visible.width, screenPanel.height / visible.height)
        let fitted = CGRect(
            x: screenPanel.midX - visible.width * fit / 2,
            y: screenPanel.midY - visible.height * fit / 2,
            width: visible.width * fit,
            height: visible.height * fit
        )
        let source = Self.lerp(outputRect, visible, e)
        let destination = Self.lerp(outputRect, fitted, e)
        let screen = scene.cropped(to: source).transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(CGAffineTransform(scaleX: destination.width / max(source.width, 1), y: destination.height / max(source.height, 1)))
            .concatenating(CGAffineTransform(translationX: destination.minX, y: destination.minY)))
        let radius = shortSide * 0.018 * e
        let screenMask = roundedRect(destination, radius: radius, color: CIColor.white)
        let screenCard = screen.cropped(to: destination).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: screenMask])
        var output = backgroundImage(plan: plan, k: k).cropped(to: outputRect)
        if e > 0.01 {
            let shadow = roundedRect(destination.offsetBy(dx: 0, dy: -shortSide * 0.008), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 * e))
                .applyingGaussianBlur(sigma: Double(shortSide * 0.014))
            output = shadow.composited(over: output)
        }
        output = screenCard.composited(over: output)

        let cameraRect = Self.lerp(bubble, cameraPanel, e)
        let cameraRadius = bubbleRadius + (shortSide * 0.018 - bubbleRadius) * e
        let look = CameraLook(radius: cameraRadius, rim: Double(1 - e), shadow: 1, opacity: 1, cutout: false)
        return drawCamera(camera, in: cameraRect, look: look, plan: plan, outputSize: outputSize, k: k, over: output)
    }

    static func fade(time: Double, start: Double, end: Double, fadeIn: Double, fadeOut: Double) -> Double {
        let length = max(end - start, 0.001)
        let a = min(fadeIn, length / 3)
        let b = min(fadeOut, length / 3)
        var value = 1.0
        if a > 0 { value = min(value, (time - start) / a) }
        if b > 0 { value = min(value, (end - time) / b) }
        return min(max(value, 0), 1)
    }

    private func captionImage(_ caption: VideoRenderPlan.Caption, style: VideoCaptionStyle, sourceTime: Double, outputSize: CGSize) -> CIImage? {
        let shortSide = min(outputSize.width, outputSize.height)
        let fontSize = max((style.size.scale * shortSide).rounded(), 9)
        let maxWidth = (outputSize.width * 0.82).rounded()
        let highlight = style.highlightWords && !caption.words.isEmpty
        let spoken = highlight ? (caption.words.lastIndex { $0.start <= sourceTime + 0.02 } ?? -1) : -1
        let key = "caption-\(caption.id)-\(caption.text.hashValue)-\(highlight)-\(spoken)-\(Int(fontSize))-\(Int(maxWidth))"
        return cached(key) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = fontSize * 0.08
            let text = NSMutableAttributedString()
            if highlight {
                for (index, word) in caption.words.enumerated() {
                    if index > 0, VideoCaptionBuilder.needsSpace(between: caption.words[index - 1].text, and: word.text) {
                        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
                    }
                    let color = index <= spoken ? NSColor.white : NSColor.white.withAlphaComponent(0.5)
                    text.append(NSAttributedString(string: word.text, attributes: [.font: font, .foregroundColor: color]))
                }
            } else {
                text.append(NSAttributedString(string: caption.text.isEmpty ? " " : caption.text, attributes: [.font: font, .foregroundColor: NSColor.white]))
            }
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            let padX = (fontSize * 0.7).rounded()
            let padY = (fontSize * 0.36).rounded()
            let bounds = text.boundingRect(with: CGSize(width: maxWidth - padX * 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let width = Int(ceil(bounds.width + padX * 2))
            let height = Int(ceil(bounds.height + padY * 2))
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let radius = min(CGFloat(height) / 2, fontSize * 0.55)
            let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(pill)
            context.setFillColor(CGColor(gray: 0.03, alpha: 0.86))
            context.fillPath()
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            text.draw(with: CGRect(x: padX, y: padY, width: CGFloat(width) - padX * 2, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage().map { CIImage(cgImage: $0) }
        }
    }

    /// Keycaps on a dark tray: ⌘ ⇧ 4, with ×N for repeats.
    private func keystrokeImage(_ keys: [String], count: Int, style: VideoKeystrokeStyle, outputSize: CGSize) -> CIImage? {
        let shortSide = min(outputSize.width, outputSize.height)
        let fontSize = max((style.size.scale * shortSide).rounded(), 9)
        let key = "keys-\(keys.joined(separator: "\u{1}"))-\(count)-\(Int(fontSize))"
        return cached(key) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let labels = keys.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white]) }
            let counter = count > 1
                ? NSAttributedString(string: "×\(count)", attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.72)])
                : nil
            let capHeight = (fontSize * 1.8).rounded()
            let capPad = (fontSize * 0.45).rounded()
            let gap = (fontSize * 0.3).rounded()
            let tray = (fontSize * 0.34).rounded()
            let capWidths = labels.map { max(ceil($0.size().width) + capPad * 2, capHeight) }
            var contentWidth = capWidths.reduce(0, +) + gap * CGFloat(max(capWidths.count - 1, 0))
            if let counter { contentWidth += gap * 1.4 + ceil(counter.size().width) }
            let width = Int(contentWidth + tray * 2)
            let height = Int(capHeight + tray * 2)
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

            let trayRadius = min(CGFloat(height) / 2, capHeight * 0.34 + tray)
            let trayPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: trayRadius, cornerHeight: trayRadius, transform: nil)
            context.addPath(trayPath)
            context.setFillColor(CGColor(gray: 0.05, alpha: 0.9))
            context.fillPath()
            context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: CGFloat(width) - 1, height: CGFloat(height) - 1), cornerWidth: trayRadius, cornerHeight: trayRadius, transform: nil))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            context.setLineWidth(1)
            context.strokePath()

            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            var x = tray
            let capRadius = capHeight * 0.26
            let lip = max((fontSize * 0.1).rounded(), 1)
            for (label, capWidth) in zip(labels, capWidths) {
                let cap = CGRect(x: x, y: tray, width: capWidth, height: capHeight)
                // Base (the key's side), then the lighter top face.
                context.addPath(CGPath(roundedRect: cap, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 0.10))
                context.fillPath()
                let face = CGRect(x: cap.minX, y: cap.minY + lip, width: cap.width, height: cap.height - lip)
                context.addPath(CGPath(roundedRect: face, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 0.17))
                context.fillPath()
                context.addPath(CGPath(roundedRect: face.insetBy(dx: 0.5, dy: 0.5), cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
                context.setLineWidth(1)
                context.strokePath()
                let size = label.size()
                label.draw(at: CGPoint(x: (face.midX - size.width / 2).rounded(), y: (face.midY - size.height / 2 + font.descender * 0.1).rounded()))
                x += capWidth + gap
            }
            if let counter {
                let size = counter.size()
                counter.draw(at: CGPoint(x: (x - gap + gap * 1.4).rounded(), y: (CGFloat(height) / 2 - size.height / 2).rounded()))
            }
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage().map { CIImage(cgImage: $0) }
        }
    }

    // MARK: Motion blur

    private func cameraMotionBlur(_ scene: CIImage, plan: VideoRenderPlan, geometry: Geometry, time: Double, frameRate: Double) -> CIImage {
        let velocity = plan.camera.velocity(at: time)
        let perFrame = 1 / max(frameRate, 1)
        let amount = plan.motionBlur
        var image = scene
        let extent = scene.extent

        // Zoom: radial streaks as long as a half-open shutter would record.
        // CIZoomBlur's `amount` smears a pixel by ~1.5% of its distance from
        // the center per unit, while the scale change moves it by
        // Δlog(scale) × distance per frame.
        let zoomAmount = abs(velocity.logScale) * perFrame * 0.5 / 0.015 * amount
        if zoomAmount > 0.12 {
            let filter = CIFilter.zoomBlur()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: geometry.output.width / 2, y: geometry.output.height / 2)
            filter.amount = Float(min(zoomAmount, 2.5))
            if let output = filter.outputImage { image = output.cropped(to: extent) }
        }

        // Pan: directional streaks along the camera's travel.
        let dx = velocity.x * Double(geometry.canvas.width) * Double(geometry.pixelScale) * perFrame
        let dy = velocity.y * Double(geometry.canvas.height) * Double(geometry.pixelScale) * perFrame
        let panStreak = (dx * dx + dy * dy).squareRoot() * 0.3 * amount
        if panStreak > 1.0 {
            let filter = CIFilter.motionBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(min(panStreak, 40))
            // Canvas y is down; CI y is up.
            filter.angle = Float(atan2(-dy, dx))
            if let output = filter.outputImage { image = output.cropped(to: extent) }
        }
        return image
    }

    // MARK: Pointer

    private func pointerPixelHeight(plan: VideoRenderPlan, geometry: Geometry, shape: VideoCursorArtwork.Shape) -> CGFloat {
        // Points → recorded pixels → canvas → output, times the user's size.
        shape.size.height * CGFloat(plan.pointPixelScale) * plan.stageScale * geometry.pixelScale * CGFloat(plan.cursorSettings.size)
    }

    private func drawPointer(
        on scene: CIImage,
        track: VideoCursorTrack,
        plan: VideoRenderPlan,
        geometry: Geometry,
        timelineTime: Double,
        sourceTime: Double,
        alpha: Double,
        options: Options
    ) -> CIImage {
        let shape = plan.artwork.shape(at: sourceTime, alwaysArrow: plan.cursorSettings.alwaysArrow)
        let height = pointerPixelHeight(plan: plan, geometry: geometry, shape: shape)
        var output = scene

        if plan.cursorSettings.clickEffect == .ripple {
            output = drawRipples(on: output, plan: plan, geometry: geometry, time: timelineTime, pointerHeight: height)
        }

        // Press: squeeze on the way down, spring back on release.
        var press: CGFloat = 1
        if plan.cursorSettings.clickEffect != .none {
            // The most recent press wins (clicks are time-ordered); the
            // release rebound overshoots slightly past 1 for a springy feel.
            for click in plan.clicks where timelineTime >= click.start - 0.001 && timelineTime <= click.end + 0.6 {
                if timelineTime <= click.end {
                    press = CGFloat(1 - 0.2 * VideoCameraEasing.spring((timelineTime - click.start) / 0.09))
                } else {
                    let u = timelineTime - click.end
                    press = CGFloat(1 - 0.2 * exp(-13 * u) * cos(19 * u))
                }
            }
        }

        let position = plan.crop.map(track.position(at: sourceTime))
        let logical = CGPoint(
            x: plan.stageRect.minX + plan.stageRect.width * position.x,
            y: plan.stageRect.minY + plan.stageRect.height * position.y
        )
        let tip = geometry.point(logical)
        let drawHeight = height * press
        let image = shape.image(forPixelHeight: drawHeight)
        let scale = drawHeight / max(image.extent.height, 1)
        // Hot spot (points, top-left) → pixels of this mip (bottom-left).
        let hotX = shape.hotSpot.x / max(shape.size.width, 1) * image.extent.width
        let hotY = (1 - shape.hotSpot.y / max(shape.size.height, 1)) * image.extent.height
        var pointer = image
            .transformed(by: CGAffineTransform(translationX: -hotX, y: -hotY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tip.x, y: tip.y))

        if plan.cursorSettings.motionBlur, !options.draft {
            let velocity = track.velocity(at: sourceTime)
            let perFrame = 1 / max(options.frameRate, 1)
            let dx = velocity.dx * Double(plan.stageRect.width) * Double(geometry.pixelScale) * perFrame
            let dy = velocity.dy * Double(plan.stageRect.height) * Double(geometry.pixelScale) * perFrame
            let speed = (dx * dx + dy * dy).squareRoot()
            if speed > 3 {
                let filter = CIFilter.motionBlur()
                filter.inputImage = pointer
                filter.radius = Float(min(speed * 0.18, Double(drawHeight) * 0.3))
                filter.angle = Float(atan2(-dy, dx))
                if let blurred = filter.outputImage { pointer = blurred }
            }
        }

        if alpha < 0.999 {
            pointer = faded(pointer, alpha)
        }
        return pointer.composited(over: output)
    }

    private func drawRipples(on scene: CIImage, plan: VideoRenderPlan, geometry: Geometry, time: Double, pointerHeight: CGFloat) -> CIImage {
        var output = scene
        let duration = 0.55
        for click in plan.clicks where time >= click.start && time <= click.start + duration {
            let progress = (time - click.start) / duration
            let eased = 1 - pow(1 - progress, 3)
            let diameter = pointerHeight * CGFloat(0.5 + 1.6 * eased)
            let alpha = 0.7 * pow(1 - progress, 1.4)
            let spot = plan.crop.map(CGPoint(x: click.x, y: click.y))
            let logical = CGPoint(
                x: plan.stageRect.minX + plan.stageRect.width * spot.x,
                y: plan.stageRect.minY + plan.stageRect.height * spot.y
            )
            let center = geometry.point(logical)
            let ring = ringImage
            let scale = diameter / ring.extent.width
            let placed = faded(ring, alpha)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2))
            output = placed.composited(over: output)
        }
        return output
    }

    private static func makeRingImage() -> CIImage {
        let size = 512
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        // Soft fill + crisp rim + faint dark edge so it reads on any content.
        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.fillEllipse(in: rect.insetBy(dx: 40, dy: 40))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(30)
        context.strokeEllipse(in: rect.insetBy(dx: 36, dy: 36))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(22)
        context.strokeEllipse(in: rect.insetBy(dx: 36, dy: 36))
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }
}
