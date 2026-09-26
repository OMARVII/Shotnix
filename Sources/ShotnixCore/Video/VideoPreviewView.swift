import AppKit
import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

/// Draws the live preview into a Metal view with the export renderer, at
/// the view's own pixel size. Idle when nothing changes; 60fps while
/// playing or editing.
@MainActor
final class VideoPreviewRenderer: NSObject, MTKViewDelegate {
    private weak var model: VideoEditorModel?
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let context: CIContext
    private let renderer = VideoFrameRenderer()
    private var lastBuffer: CVPixelBuffer?
    private var lastBufferTime: Double = 0
    /// The camera frame composed with `lastBuffer` (kept so a missed lookup
    /// never blinks the bubble).
    private var lastCameraFrame: VideoCameraFrame?
    private var playingTime: Double?
    private var dirty = true
    private var peekImage: CIImage?
    private var peekTime: Double?
    private var peekInFlight = false
    private var pendingPeek: Double?
    private lazy var peekGenerator: AVAssetImageGenerator? = {
        guard let model else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: model.project.sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        return generator
    }()

    init(model: VideoEditorModel) {
        self.model = model
        device = VideoRenderContext.device
        queue = device?.makeCommandQueue()
        context = VideoRenderContext.makeContext()
        super.init()
    }

    func invalidate() {
        dirty = true
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { dirty = true }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        guard let model, model.isReady else { return }
        let hostTime = CACurrentMediaTime()
        if let frame = model.playback.frame(forHostTime: hostTime) {
            lastBuffer = frame.buffer
            lastBufferTime = frame.time
            if let camera = model.playback.cameraPicture(at: frame.time) {
                lastCameraFrame = camera
            }
            dirty = true
        }
        // While playing, redraw every display refresh at the exact playback
        // time: the camera and cursor move at the screen's rate even when
        // the recording has fewer frames.
        if model.isPlaying, let time = model.playback.itemTime(forHostTime: hostTime) {
            playingTime = time
            dirty = true
        } else {
            playingTime = nil
        }
        guard dirty else { return }
        let size = view.drawableSize
        guard size.width > 2, size.height > 2,
              let drawable = view.currentDrawable,
              let commandBuffer = queue?.makeCommandBuffer() else { return }
        dirty = false

        let image = compose(model: model, size: size)
        let destination = CIRenderDestination(
            width: Int(size.width),
            height: Int(size.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        _ = try? context.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func compose(model: VideoEditorModel, size: CGSize) -> CIImage {
        var options = VideoFrameRenderer.Options(frameRate: 60)
        options.solidOverlay = Self.editedOverlay(model)
        options.webcamFrame = model.plan.webcam == nil ? nil : lastCameraFrame?.image
        options.webcamMask = model.plan.webcam == nil ? nil : lastCameraFrame?.mask
        var source = lastBuffer.map { CIImage(cvPixelBuffer: $0) }
        var time = playingTime ?? lastBufferTime
        if model.isCropping {
            options.rawSource = true
        } else if let peek = model.trimPeekSourceTime {
            requestPeek(peek)
            if let peekImage { source = peekImage }
            options.cameraOverride = .rest
            options.sourceTimeOverride = peek
            time = model.clock.time
        } else if model.isAimingZoom {
            options.cameraOverride = .rest
        }
        return renderer.render(source: source, timelineTime: time, plan: model.plan, outputSize: size, options: options)
    }

    /// The annotation being edited while paused — shown fully, fades aside.
    private static func editedOverlay(_ model: VideoEditorModel) -> UUID? {
        guard !model.isPlaying, case .overlay(let id) = model.selection else { return nil }
        return id
    }

    /// Source frames for clip-edge drags (possibly outside the current
    /// edit), fetched one at a time, newest request wins.
    private func requestPeek(_ time: Double) {
        if let peekTime, abs(peekTime - time) < 0.001 { return }
        guard !peekInFlight else {
            pendingPeek = time
            return
        }
        guard let generator = peekGenerator else { return }
        peekInFlight = true
        let requested = time
        generator.generateCGImageAsynchronously(for: CMTime(seconds: requested, preferredTimescale: 600)) { [weak self] image, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.peekInFlight = false
                if let image {
                    self.peekImage = CIImage(cgImage: image)
                    self.peekTime = requested
                    self.dirty = true
                }
                if let pending = self.pendingPeek {
                    self.pendingPeek = nil
                    self.requestPeek(pending)
                }
            }
        }
    }

    /// The frame at a timeline moment, decoded directly rather than from
    /// playback — offscreen windows (editor snapshots) never show Metal.
    func still(size: CGSize, at time: Double) -> NSImage? {
        guard let model, size.width > 2, size.height > 2 else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: model.project.sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let sourceTime = model.sourceTime(forTimeline: time)
        let frame = try? generator.copyCGImage(at: CMTime(seconds: sourceTime, preferredTimescale: 600), actualTime: nil)
        var options = VideoFrameRenderer.Options(frameRate: 60)
        options.rawSource = model.isCropping
        options.solidOverlay = Self.editedOverlay(model)
        // Like the live preview: aiming a zoom shows the whole frame.
        if model.isAimingZoom && !model.isCropping { options.cameraOverride = .rest }
        if model.plan.webcam != nil, let camera = model.playback.cameraPicture(at: time) {
            options.webcamFrame = camera.image
            options.webcamMask = camera.mask
        }
        let pixels = CGSize(width: size.width * 2, height: size.height * 2)
        let image = renderer.render(source: frame.map { CIImage(cgImage: $0) }, timelineTime: time, plan: model.plan, outputSize: pixels, options: options)
        guard let cgImage = context.createCGImage(image, from: CGRect(origin: .zero, size: pixels), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// The frame under the playhead, rendered at `size`.
    func snapshot(size: CGSize) -> NSImage? {
        guard let model else { return nil }
        var options = VideoFrameRenderer.Options(frameRate: 60)
        options.webcamFrame = lastCameraFrame?.image
        options.webcamMask = lastCameraFrame?.mask
        let image = renderer.render(source: lastBuffer.map { CIImage(cvPixelBuffer: $0) }, timelineTime: lastBufferTime, plan: model.plan, outputSize: size, options: options)
        guard let cgImage = context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}

/// The Metal surface.
struct VideoPreviewSurface: NSViewRepresentable {
    let renderer: VideoPreviewRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.wantsLayer = true
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.isOpaque = true
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.invalidate()
    }
}

// MARK: - Stage (preview + direct manipulation)

struct VideoStageView: View {
    @ObservedObject var model: VideoEditorModel
    /// Snapshot tests: draw the preview as a still image.
    nonisolated(unsafe) static var drawsStills = false

    var body: some View {
        GeometryReader { proxy in
            let canvas = model.isCropping ? model.project.sourceSize : model.project.canvasSize()
            let fitted = Self.fit(canvas, in: proxy.size)
            ZStack {
                Group {
                    if Self.drawsStills, let still = model.previewRenderer.still(size: fitted, at: model.clock.time) {
                        Image(nsImage: still).resizable()
                    } else {
                        VideoPreviewSurface(renderer: model.previewRenderer)
                    }
                }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)

                if model.isCropping {
                    VideoCropOverlay(model: model, viewSize: fitted)
                        .frame(width: fitted.width, height: fitted.height)
                } else {
                    VideoStageInteractionLayer(model: model, clock: model.clock, viewSize: fitted)
                        .frame(width: fitted.width, height: fitted.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    static func fit(_ canvas: CGSize, in available: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / canvas.width, available.height / canvas.height)
        return CGSize(width: floor(canvas.width * scale), height: floor(canvas.height * scale))
    }
}

/// Handles drawn over the preview: the zoom target rectangle while aiming,
/// and selection frames for callouts. Maps through the live camera so
/// handles stay glued to what's drawn.
struct VideoStageInteractionLayer: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var clock: VideoDemoPlaybackClock
    let viewSize: CGSize

    @State private var aimOrigin: (id: UUID, centerX: Double, centerY: Double, scale: Double)?
    @State private var overlayOrigin: VideoDemoOverlayEffect?
    @State private var bubbleDrag: CGSize?
    @State private var hoveringBubble = false

    /// The canvas the scene is laid out on (the recording's own shape when
    /// reframing a narrow output).
    private var canvas: CGSize { model.plan.canvasSize }
    private var stage: CGRect { (model.project.reframeActive ? model.project.reframeScene() : model.project).stageRect(in: canvas) }
    /// Width of the whole scene in view points, and how far the reframing
    /// window has panned into it.
    private var sceneWidth: CGFloat {
        model.plan.reframe == nil ? viewSize.width : viewSize.height * canvas.width / max(canvas.height, 1)
    }
    private var sceneOffset: CGFloat {
        model.plan.reframe?.windowOrigin(at: clock.time, sceneWidth: sceneWidth) ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.selection != .none {
                        model.selection = .none
                    } else {
                        model.togglePlay()
                    }
                }

            if model.isAimingZoom, let zoom = model.selectedZoom {
                aimRectangle(zoom)
            } else if let zoom = model.selectedZoom, zoom.followsCursor, !model.isPlaying {
                followBadge
            }

            if !model.isPlaying, let overlay = model.selectedOverlay, isVisibleNow(overlay) {
                overlayFrame(overlay)
            }

            // The bubble handle only where the bubble is (not during a full
            // camera, side by side, or hidden stretch).
            if let webcam = model.plan.webcam, webcam.visible, !model.isAimingZoom, model.plan.cameraLayout(at: clock.time) == nil {
                webcamHandle(webcam)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }

    // MARK: Camera bubble

    /// The bubble's rect in view points (top-left origin).
    private func bubbleRect(_ settings: VideoWebcamSettings) -> CGRect {
        let rect = VideoFrameRenderer.webcamRect(settings, outputSize: viewSize, cameraScale: camera.scale)
        return CGRect(x: rect.minX, y: viewSize.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func nearestAnchor(to point: CGPoint, _ settings: VideoWebcamSettings) -> VideoWebcamSettings.Anchor {
        VideoWebcamSettings.Anchor.allCases.min { a, b in
            var sa = settings
            sa.anchor = a
            var sb = settings
            sb.anchor = b
            let ra = bubbleRect(sa)
            let rb = bubbleRect(sb)
            return hypot(ra.midX - point.x, ra.midY - point.y) < hypot(rb.midX - point.x, rb.midY - point.y)
        } ?? settings.anchor
    }

    /// Drag the camera anywhere — it snaps to the nearest of eight spots.
    private func webcamHandle(_ settings: VideoWebcamSettings) -> some View {
        let rect = bubbleRect(settings)
        let shown = rect.offsetBy(dx: bubbleDrag?.width ?? 0, dy: bubbleDrag?.height ?? 0)
        let radius = VideoFrameRenderer.webcamCornerRadius(settings, rect: rect)
        let target: CGRect? = bubbleDrag.map { drag in
            var snapped = settings
            snapped.anchor = nearestAnchor(to: CGPoint(x: rect.midX + drag.width, y: rect.midY + drag.height), settings)
            return bubbleRect(snapped)
        }
        return ZStack(alignment: .topLeading) {
            if let target {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(VideoEditorTheme.camera.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(VideoEditorTheme.camera, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .frame(width: target.width, height: target.height)
                    .offset(x: target.minX, y: target.minY)
                    .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(bubbleDrag != nil ? 0.95 : (hoveringBubble ? 0.7 : 0)), lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(bubbleDrag != nil ? 0.12 : 0.001)))
                .frame(width: shown.width, height: shown.height)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .offset(x: shown.minX, y: shown.minY)
                .onHover { inside in
                    hoveringBubble = inside
                    (inside ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .onTapGesture {
                    model.selection = .none
                    model.inspectorTab = .camera
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            bubbleDrag = value.translation
                            NSCursor.closedHand.set()
                        }
                        .onEnded { value in
                            let anchor = nearestAnchor(to: CGPoint(x: rect.midX + value.translation.width, y: rect.midY + value.translation.height), settings)
                            bubbleDrag = nil
                            if anchor != settings.anchor {
                                model.setStyle { $0.webcam.anchor = anchor }
                            }
                            NSCursor.openHand.set()
                        }
                )
                .help("Camera — drag to move it, click for options")
        }
    }

    private func isVisibleNow(_ effect: VideoDemoOverlayEffect) -> Bool {
        // The span the renderer draws, after cuts.
        guard let span = model.plan.overlays.first(where: { $0.effect.id == effect.id }) else { return false }
        return clock.time >= span.start - 0.05 && clock.time <= span.end + 0.05
    }

    // MARK: Geometry

    private var camera: VideoCameraState {
        model.isAimingZoom ? .rest : model.cameraState(at: clock.time)
    }

    /// Canvas point (top-left) → view point.
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let s = CGFloat(camera.scale)
        let x = ((p.x / canvas.width - CGFloat(camera.centerX)) * s + 0.5) * sceneWidth - sceneOffset
        let y = ((p.y / canvas.height - CGFloat(camera.centerY)) * s + 0.5) * viewSize.height
        return CGPoint(x: x, y: y)
    }

    private var viewScale: CGFloat { sceneWidth / max(canvas.width, 1) * CGFloat(camera.scale) }

    // MARK: Zoom aiming

    private func aimRectangle(_ zoom: VideoZoomRegion) -> some View {
        let s = zoom.scale
        let crop = model.project.crop.normalized
        let inCrop = crop.map(CGPoint(x: zoom.focusX, y: zoom.focusY))
        let focusX = (stage.minX + stage.width * inCrop.x) / canvas.width
        let focusY = (stage.minY + stage.height * inCrop.y) / canvas.height
        let cx = VideoCameraState.clampedCenter(Double(focusX), scale: s)
        let cy = VideoCameraState.clampedCenter(Double(focusY), scale: s)
        let width = sceneWidth / CGFloat(s)
        let height = viewSize.height / CGFloat(s)
        let rect = CGRect(x: CGFloat(cx) * sceneWidth - width / 2 - sceneOffset, y: CGFloat(cy) * viewSize.height - height / 2, width: width, height: height)

        return ZStack(alignment: .topLeading) {
            // Dim everything outside the shot.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
            }
            .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 2)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .background(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.magnifyingglass")
                        Text(VideoEditorModel.formatScale(zoom.scale))
                            .monospacedDigit()
                        Text("· drag to aim")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .padding(8)
                }
                .offset(x: rect.minX, y: rect.minY)
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if aimOrigin?.id != zoom.id {
                                aimOrigin = (zoom.id, cx, cy, s)
                            }
                            guard let origin = aimOrigin else { return }
                            NSCursor.closedHand.set()
                            let newX = VideoCameraState.clampedCenter(origin.centerX + Double(value.translation.width / sceneWidth), scale: origin.scale)
                            let newY = VideoCameraState.clampedCenter(origin.centerY + Double(value.translation.height / viewSize.height), scale: origin.scale)
                            // Canvas-normalized center → recording-normalized focus.
                            let inCrop = CGPoint(
                                x: (CGFloat(newX) * canvas.width - stage.minX) / max(stage.width, 1),
                                y: (CGFloat(newY) * canvas.height - stage.minY) / max(stage.height, 1)
                            )
                            let focus = crop.unmap(inCrop)
                            model.updateZoom(zoom.id, coalesce: "aim-\(zoom.id)") { region in
                                region.focusX = Double(focus.x)
                                region.focusY = Double(focus.y)
                            }
                        }
                        .onEnded { _ in
                            aimOrigin = nil
                            model.endGesture()
                            NSCursor.openHand.set()
                        }
                )

            // Corner handles resize the shot (= zoom level).
            ForEach(0..<4, id: \.self) { corner in
                let isRight = corner == 1 || corner == 3
                let isBottom = corner >= 2
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .contentShape(Circle().inset(by: -8))
                    .offset(x: (isRight ? rect.maxX : rect.minX) - 6, y: (isBottom ? rect.maxY : rect.minY) - 6)
                    .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if aimOrigin?.id != zoom.id {
                                    aimOrigin = (zoom.id, cx, cy, s)
                                }
                                guard let origin = aimOrigin else { return }
                                let originWidth = sceneWidth / CGFloat(origin.scale)
                                let delta = (isRight ? value.translation.width : -value.translation.width) * 2
                                let newWidth = max(originWidth + delta, sceneWidth / CGFloat(VideoZoomRegion.scaleRange.upperBound))
                                let newScale = Double(sceneWidth / newWidth)
                                model.updateZoom(zoom.id, coalesce: "aim-\(zoom.id)") { region in
                                    region.scale = min(max(newScale, VideoZoomRegion.scaleRange.lowerBound), VideoZoomRegion.scaleRange.upperBound)
                                }
                            }
                            .onEnded { _ in
                                aimOrigin = nil
                                model.endGesture()
                            }
                    )
            }
        }
    }

    private var followBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.motionlines")
            Text("Camera follows your cursor")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .padding(12)
        .allowsHitTesting(false)
    }

    // MARK: Overlay editing

    private func overlayFrame(_ effect: VideoDemoOverlayEffect) -> some View {
        let center = viewPoint(CGPoint(x: stage.minX + stage.width * CGFloat(effect.x), y: stage.minY + stage.height * CGFloat(effect.y)))
        let width = stage.width * CGFloat(effect.width) * viewScale
        let height = stage.height * CGFloat(effect.height) * viewScale
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let stageWidthInView = stage.width * viewScale
        let stageHeightInView = stage.height * viewScale

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    // Double-click a text annotation to type in it.
                    if effect.kind == .text { model.textEditRequest += 1 }
                })
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if overlayOrigin?.id != effect.id { overlayOrigin = effect }
                            guard let origin = overlayOrigin else { return }
                            NSCursor.closedHand.set()
                            model.updateOverlay(effect.id, coalesce: "move-\(effect.id)") { overlay in
                                overlay.x = origin.x + Double(value.translation.width / max(stageWidthInView, 1))
                                overlay.y = origin.y + Double(value.translation.height / max(stageHeightInView, 1))
                            }
                        }
                        .onEnded { _ in
                            overlayOrigin = nil
                            model.endGesture()
                        }
                )

            ForEach(0..<4, id: \.self) { corner in
                let isRight = corner == 1 || corner == 3
                let isBottom = corner >= 2
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .contentShape(Circle().inset(by: -7))
                    .offset(x: (isRight ? rect.maxX : rect.minX) - 5.5, y: (isBottom ? rect.maxY : rect.minY) - 5.5)
                    .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if overlayOrigin?.id != effect.id { overlayOrigin = effect }
                                guard let origin = overlayOrigin else { return }
                                let sx: Double = isRight ? 1 : -1
                                let sy: Double = isBottom ? 1 : -1
                                let fixedX = origin.x - sx * origin.width / 2
                                let fixedY = origin.y - sy * origin.height / 2
                                var movingX = origin.x + sx * origin.width / 2 + Double(value.translation.width / max(stageWidthInView, 1))
                                var movingY = origin.y + sy * origin.height / 2 + Double(value.translation.height / max(stageHeightInView, 1))
                                movingX = sx > 0 ? max(movingX, fixedX + 0.04) : min(movingX, fixedX - 0.04)
                                movingY = sy > 0 ? max(movingY, fixedY + 0.03) : min(movingY, fixedY - 0.03)
                                model.updateOverlay(effect.id, coalesce: "resize-\(effect.id)") { overlay in
                                    overlay.x = (fixedX + movingX) / 2
                                    overlay.y = (fixedY + movingY) / 2
                                    overlay.width = abs(movingX - fixedX)
                                    overlay.height = abs(movingY - fixedY)
                                }
                            }
                            .onEnded { _ in
                                overlayOrigin = nil
                                model.endGesture()
                            }
                    )
            }
        }
    }
}
