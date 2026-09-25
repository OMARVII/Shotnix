import AppKit
import SwiftUI

/// Layout of the timeline surface.
enum VideoTimelineMetrics {
    static let inset: CGFloat = 18
    static let rulerHeight: CGFloat = 24
    static let zoomTrackHeight: CGFloat = 34
    static let clickLaneHeight: CGFloat = 14
    static let clipTrackHeight: CGFloat = 66
    static let overlayLaneHeight: CGFloat = 26
    static let overlayLaneGap: CGFloat = 4
    static let captionLaneHeight: CGFloat = 22
    static let keysLaneHeight: CGFloat = 18
    static let cameraLaneHeight: CGFloat = 22
    static let gap: CGFloat = 7

    /// Captions, shortcuts, and camera layouts sit in front of everything
    /// else in the picture, so their lanes come first (0 when none).
    static func textLanesHeight(_ project: VideoDemoProject) -> CGFloat {
        var height: CGFloat = 0
        if !project.captions.isEmpty { height += captionLaneHeight + overlayLaneGap }
        if !project.keystrokes.isEmpty { height += keysLaneHeight + overlayLaneGap }
        if !project.cameraLayouts.isEmpty { height += cameraLaneHeight + overlayLaneGap }
        return height > 0 ? height - overlayLaneGap + gap : 0
    }

    static func overlayLanes(_ project: VideoDemoProject) -> Int {
        guard !project.overlayEffects.isEmpty else { return 0 }
        return (project.overlayEffects.map { max($0.layer, 0) }.max() ?? 0) + 1
    }

    /// Height of the annotation lanes block (0 when there are none).
    static func overlayAreaHeight(_ project: VideoDemoProject) -> CGFloat {
        let lanes = overlayLanes(project)
        guard lanes > 0 else { return 0 }
        return CGFloat(lanes) * overlayLaneHeight + CGFloat(lanes - 1) * overlayLaneGap + gap
    }

    /// Top-to-bottom the timeline stacks like the picture does: captions
    /// and shortcuts (always in front), annotation lanes (the highest lane
    /// is the frontmost layer), the camera, clicks, and the recording
    /// itself at the base.
    static func contentHeight(_ project: VideoDemoProject) -> CGFloat {
        var height = rulerHeight + gap + textLanesHeight(project) + overlayAreaHeight(project) + zoomTrackHeight + gap
        if !project.clickEvents.isEmpty { height += clickLaneHeight + 3 }
        height += clipTrackHeight
        return height + 12
    }
}

/// Redraws only when something on the timeline changes (see
/// `VideoTimelineState`); the toolbar follows the model on its own.
struct VideoTimelineView: View, Equatable {
    let model: VideoEditorModel
    @ObservedObject var timeline: VideoTimelineState

    init(model: VideoEditorModel) {
        self.model = model
        timeline = model.timelineState
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model === b.model
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoTimelineToolbar(model: model, clock: model.clock)
                .frame(height: 44)
            Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
            GeometryReader { proxy in
                VideoTimelineSurface(model: model, timeline: timeline, viewport: proxy.size)
            }
        }
        .background(VideoEditorTheme.panel)
    }
}

// MARK: - Toolbar

struct VideoTimelineToolbar: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var clock: VideoDemoPlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(VideoToolButtonStyle(prominent: true))
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            HStack(spacing: 3) {
                Text(VideoEditorModel.timecode(clock.time))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                Text("/")
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                Text(VideoEditorModel.timecode(model.timelineDuration))
                    .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .frame(minWidth: 118, alignment: .leading)

            toolbarDivider

            toolButton("scissors", "Split", "Split at the playhead (S)") { model.splitAtPlayhead() }
            toolButton("plus.magnifyingglass", "Zoom", "Add a zoom at the playhead (Z)") {
                model.addZoom(at: clock.time)
            }
            toolbarDivider

            toolButton("sparkles", "Auto Zoom", "Plan zooms from your clicks — keeps zooms you placed by hand") { model.autoZoom() }
            toolButton("hare", "Speed Up Idle", "Fast-forward moments where nothing happens") { model.speedUpIdle() }

            Spacer(minLength: 8)

            if model.selectedClipID != nil || model.selection != .none {
                Button {
                    model.deleteSelection()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help("Delete selection (⌫)")
            }

            HStack(spacing: 6) {
                Button {
                    model.timelineZoom = max(model.timelineZoom / 1.4, 1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                Slider(value: Binding(get: { log(model.timelineZoom) / log(40) }, set: { model.timelineZoom = pow(40, $0) }), in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)
                Button {
                    model.timelineZoom = min(model.timelineZoom * 1.4, 40)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
            }
            .font(.system(size: 12, weight: .semibold))
            .help("Timeline zoom (pinch, or ⌘-scroll)")
        }
        .padding(.horizontal, 14)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(VideoEditorTheme.hairline)
            .frame(width: 1, height: 18)
    }

    private func toolButton(_ symbol: String, _ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 26)
        }
        .buttonStyle(VideoToolButtonStyle())
        .help(help)
    }
}

// MARK: - Surface

struct VideoTimelineSurface: View {
    let model: VideoEditorModel
    @ObservedObject var timeline: VideoTimelineState
    let viewport: CGSize

    /// Held, not observed: hovering redraws only the hover layer.
    @State private var hover = VideoTimelineHover()
    @State private var zoomDrag: (id: UUID, start: Double, end: Double)?
    @State private var overlayDrag: (id: UUID, start: Double, end: Double, layer: Int)?
    /// Where the dragged object was when the drag began. SwiftUI hands each
    /// update the freshly rendered closure, so computing from the object's
    /// CURRENT position would compound the movement — always start here.
    @State private var dragOrigin: TimelineDragOrigin?
    @State private var rangeStart: Double?
    @State private var pinchBase: Double?
    @State private var scrollMonitor: Any?

    private typealias M = VideoTimelineMetrics

    private var duration: Double { max(model.timelineDuration, model.layoutDurationLock ?? 0, 0.1) }
    private var contentWidth: CGFloat { max(viewport.width - M.inset * 2, 100) * CGFloat(model.timelineZoom) }
    private var pointsPerSecond: CGFloat { contentWidth / CGFloat(duration) }

    private var geometry: VideoTimelineGeometry {
        VideoTimelineGeometry(pointsPerSecond: pointsPerSecond, duration: duration, width: contentWidth + M.inset * 2)
    }

    private func x(_ time: Double) -> CGFloat { M.inset + CGFloat(time) * pointsPerSecond }
    private func time(_ x: CGFloat) -> Double { min(max(Double((x - M.inset) / pointsPerSecond), 0), duration) }

    private var textTop: CGFloat { M.rulerHeight + M.gap }
    private var captionTop: CGFloat { textTop }
    private var keysTop: CGFloat { textTop + (model.project.captions.isEmpty ? 0 : M.captionLaneHeight + M.overlayLaneGap) }
    private var cameraLaneTop: CGFloat { keysTop + (model.project.keystrokes.isEmpty ? 0 : M.keysLaneHeight + M.overlayLaneGap) }
    private var overlayTop: CGFloat { textTop + M.textLanesHeight(model.project) }
    private var zoomTop: CGFloat { overlayTop + M.overlayAreaHeight(model.project) }
    private var clickTop: CGFloat { zoomTop + M.zoomTrackHeight + M.gap }
    private var clipTop: CGFloat { clickTop + (model.project.clickEvents.isEmpty ? 0 : M.clickLaneHeight + 3) }

    /// Lane `layer` sits higher the higher its layer (and draws in front).
    private func laneY(_ layer: Int) -> CGFloat {
        let lanes = M.overlayLanes(model.project)
        return CGFloat(max(lanes - 1 - layer, 0)) * (M.overlayLaneHeight + M.overlayLaneGap)
    }

    var body: some View {
        let height = max(M.contentHeight(model.project), viewport.height)
        // Lanes that don't fit scroll vertically (the recording is at the
        // bottom and must stay reachable).
        ScrollView(.vertical, showsIndicators: height > viewport.height + 0.5) {
        ScrollView(.horizontal, showsIndicators: model.timelineZoom > 1.01) {
            ZStack(alignment: .topLeading) {
                // Scrub anywhere that isn't an object.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)

                VideoTimelineRuler(duration: duration, pointsPerSecond: pointsPerSecond, inset: M.inset)
                    .frame(width: contentWidth + M.inset * 2, height: M.rulerHeight)
                    .allowsHitTesting(false)

                zoomTrack
                if !model.project.clickEvents.isEmpty {
                    VideoClickLane(
                        items: model.project.clickEvents.compactMap { click in
                            model.timelineTime(forSource: click.time).map { VideoClickLane.Item(id: click.id, time: $0) }
                        },
                        selectedID: { if case .click(let id) = model.selection { return id } else { return nil } }(),
                        geometry: geometry,
                        model: model,
                        hover: hover
                    )
                    .equatable()
                    .offset(y: clickTop)
                }
                clipTrack
                if !model.project.overlayEffects.isEmpty { overlayLanes }
                if !model.project.captions.isEmpty {
                    VideoCaptionLane(
                        items: model.plan.captions.map { VideoCaptionLane.Item(id: $0.id, start: $0.start, end: $0.end, text: $0.text) },
                        selectedID: model.selectedCaptionID,
                        geometry: geometry,
                        model: model,
                        hover: hover
                    )
                    .equatable()
                    .offset(y: captionTop)
                }
                if !model.project.keystrokes.isEmpty {
                    VideoKeysLane(
                        items: model.project.keystrokes.compactMap { event in
                            model.timelineTime(forSource: event.time).map { VideoKeysLane.Item(id: event.id, time: $0, label: event.keys.joined()) }
                        },
                        selectedID: { if case .keystroke(let id) = model.selection { return id } else { return nil } }(),
                        hidden: !model.project.keystrokeStyle.visible,
                        geometry: geometry,
                        model: model
                    )
                    .equatable()
                    .offset(y: keysTop)
                }

                if !model.project.cameraLayouts.isEmpty {
                    VideoCameraLayoutLane(
                        items: model.cameraLayoutSpans.map { VideoCameraLayoutLane.Item(id: $0.region.id, start: $0.start, end: $0.end, layout: $0.region.layout) },
                        selectedID: model.selectedCameraLayoutID,
                        geometry: geometry,
                        model: model,
                        hover: hover
                    )
                    .equatable()
                    .offset(y: cameraLaneTop)
                }

                VideoTimelineHoverLayer(
                    hover: hover,
                    model: model,
                    geometry: geometry,
                    height: height,
                    zoomTop: zoomTop,
                    showsZoomHint: model.project.zoomRegions.isEmpty,
                    viewportWidth: viewport.width
                )
                VideoTimelinePlayhead(clock: model.clock, x: { x($0) }, height: height)
            }
            .frame(width: contentWidth + M.inset * 2, height: height, alignment: .topLeading)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hover.update(time: time(location.x), overZoomTrack: location.y >= zoomTop && location.y <= zoomTop + M.zoomTrackHeight)
                case .ended:
                    hover.update(time: nil, overZoomTrack: false)
                }
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = model.timelineZoom }
                        model.timelineZoom = min(max((pinchBase ?? 1) * value, 1), 40)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .frame(height: height)
        }
        .onAppear(perform: installScrollZoom)
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    /// ⌘-scroll zooms the timeline.
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [model] event in
            guard event.modifierFlags.contains(.command),
                  event.window?.delegate is VideoDemoEditorWindowController else { return event }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            let factor = pow(1.01, Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 6))
            MainActor.assumeIsolated {
                model.timelineZoom = min(max(model.timelineZoom * factor, 1), 40)
            }
            return nil
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = time(value.location.x)
                if NSEvent.modifierFlags.contains(.shift) {
                    if rangeStart == nil { rangeStart = time(value.startLocation.x) }
                    if let rangeStart {
                        model.selection = .range(VideoDemoTimelineRange(start: rangeStart, end: t).normalized)
                    }
                } else {
                    if value.translation == .zero, model.selection != .none, !isRangeSelection {
                        model.selection = .none
                    }
                    model.seek(to: t, fast: true)
                }
            }
            .onEnded { value in
                if rangeStart == nil {
                    model.seek(to: time(value.location.x), fast: false)
                }
                rangeStart = nil
            }
    }

    private var isRangeSelection: Bool {
        if case .range = model.selection { return true }
        return false
    }

    // MARK: Zoom track

    private var zoomTrack: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .frame(width: contentWidth, height: M.zoomTrackHeight)
                .offset(x: M.inset)
                .onTapGesture { location in
                    let at = time(location.x + M.inset)
                    if let id = model.addZoom(at: at),
                       let range = model.project.zoomRegions.first(where: { $0.id == id }).flatMap({ model.zoomTimelineRange($0) }) {
                        // Park inside the new zoom so the preview shows it.
                        model.seek(to: min(range.lowerBound + min(1.2, (range.upperBound - range.lowerBound) / 2), range.upperBound))
                        model.inspectorTab = .zoom
                    }
                }

            ForEach(model.project.zoomRegions) { region in
                if let range = model.zoomTimelineRange(region) {
                    zoomBlock(region, range: range)
                }
            }
        }
        .offset(y: zoomTop)
    }

    private func zoomBlock(_ region: VideoZoomRegion, range: ClosedRange<Double>) -> some View {
        let selected = model.selectedZoomID == region.id
        let shown = zoomDrag?.id == region.id ? (zoomDrag!.start...zoomDrag!.end) : range
        let width = max(CGFloat(shown.upperBound - shown.lowerBound) * pointsPerSecond, 14)
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [VideoEditorTheme.zoom, VideoEditorTheme.zoom.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .opacity(selected ? 1 : 0.82)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.16), lineWidth: selected ? 1.5 : 1)
            if width > 44 {
                HStack(spacing: 4) {
                    Image(systemName: region.followsCursor ? "cursorarrow.motionlines" : "scope")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(width > 80 ? "\(VideoEditorModel.formatScale(region.scale)) Zoom" : VideoEditorModel.formatScale(region.scale))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                    if width > 150 {
                        Text(region.followsCursor ? "· follows cursor" : "· aimed")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if region.isAuto, width > 150 {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
            }
            HStack(spacing: 0) {
                edgeHandle
                    .gesture(zoomEdgeGesture(region, range: range, leading: true))
                Spacer(minLength: 0)
                edgeHandle
                    .gesture(zoomEdgeGesture(region, range: range, leading: false))
            }
        }
        .frame(width: width, height: M.zoomTrackHeight - 4)
        .shadow(color: selected ? VideoEditorTheme.zoom.opacity(0.5) : .clear, radius: 8)
        .contentShape(Rectangle())
        .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        .gesture(zoomMoveGesture(region, range: range))
        .contextMenu { zoomMenu(region) }
        .offset(x: x(shown.lowerBound), y: 2)
        .help("Zoom — drag to move, drag an edge to resize, click to edit")
    }

    private var edgeHandle: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 2.5, height: 12)
            )
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.openHand).set() }
    }

    private func zoomMoveGesture(_ region: VideoZoomRegion, range: ClosedRange<Double>) -> some Gesture {
        // Global space: the block moves under the pointer, so local
        // coordinates would lag behind it.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != region.id {
                    dragOrigin = TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                    zoomDrag = (region.id, range.lowerBound, range.upperBound)
                    hover.setDragging(true)
                    model.selection = .zoom(region.id)
                    if !region.followsCursor { model.pause() }
                }
                guard let origin = dragOrigin, abs(value.translation.width) > 2 else { return }
                NSCursor.closedHand.set()
                let delta = Double(value.translation.width / pointsPerSecond)
                let length = origin.end - origin.start
                let start = min(max(origin.start + delta, 0), duration - length)
                model.setZoomWindow(region.id, start: start, end: start + length, coalesce: "zoom-move-\(region.id)")
                if let updated = model.project.zoomRegions.first(where: { $0.id == region.id }).flatMap({ model.zoomTimelineRange($0) }) {
                    zoomDrag = (region.id, updated.lowerBound, updated.upperBound)
                }
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                if abs(value.translation.width) > 2 {
                    // Magnet on release: whichever edge is near a target lands on it.
                    let delta = Double(value.translation.width / pointsPerSecond)
                    let length = origin.end - origin.start
                    let start = min(max(origin.start + delta, 0), duration - length)
                    let snappedStart = snap(start, excluding: region.id)
                    let snappedEnd = snap(start + length, excluding: region.id)
                    let shift = abs(snappedStart - start) <= abs(snappedEnd - (start + length)) ? snappedStart - start : snappedEnd - (start + length)
                    if abs(shift) > 0.0001 {
                        model.setZoomWindow(region.id, start: start + shift, end: start + shift + length, coalesce: "zoom-move-\(region.id)")
                    }
                }
                zoomDrag = nil
                dragOrigin = nil
                hover.setDragging(false)
                model.endGesture()
                if abs(value.translation.width) <= 2 {
                    model.selection = .zoom(region.id)
                    model.inspectorTab = .zoom
                    if !(region.followsCursor) || !model.isPlaying {
                        // Show the zoom: park inside it once the camera arrived.
                        let target = min(origin.start + min(1.2, (origin.end - origin.start) / 2), origin.end)
                        model.seek(to: target)
                    }
                }
                NSCursor.openHand.set()
            }
    }

    private func zoomEdgeGesture(_ region: VideoZoomRegion, range: ClosedRange<Double>, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != region.id {
                    dragOrigin = TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                    zoomDrag = (region.id, range.lowerBound, range.upperBound)
                    hover.setDragging(true)
                    model.selection = .zoom(region.id)
                }
                guard let origin = dragOrigin else { return }
                let delta = Double(value.translation.width / pointsPerSecond)
                let start = leading ? min(origin.start + delta, origin.end - VideoZoomRegion.minimumDuration) : origin.start
                let end = leading ? origin.end : max(origin.end + delta, origin.start + VideoZoomRegion.minimumDuration)
                model.setZoomWindow(region.id, start: start, end: end, coalesce: "zoom-edge-\(region.id)")
                if let updated = model.project.zoomRegions.first(where: { $0.id == region.id }).flatMap({ model.zoomTimelineRange($0) }) {
                    zoomDrag = (region.id, updated.lowerBound, updated.upperBound)
                }
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                let delta = Double(value.translation.width / pointsPerSecond)
                if leading {
                    let start = snap(min(origin.start + delta, origin.end - VideoZoomRegion.minimumDuration), excluding: region.id)
                    model.setZoomWindow(region.id, start: start, end: origin.end, coalesce: "zoom-edge-\(region.id)")
                } else {
                    let end = snap(max(origin.end + delta, origin.start + VideoZoomRegion.minimumDuration), excluding: region.id)
                    model.setZoomWindow(region.id, start: origin.start, end: end, coalesce: "zoom-edge-\(region.id)")
                }
                zoomDrag = nil
                dragOrigin = nil
                hover.setDragging(false)
                model.endGesture()
            }
    }

    /// Lands `time` on a nearby target (within 8 points).
    private func snap(_ time: Double, excluding id: UUID) -> Double {
        let threshold = Double(8 / pointsPerSecond)
        guard let best = model.zoomSnapTargets(excluding: id).min(by: { abs($0 - time) < abs($1 - time) }),
              abs(best - time) <= threshold else { return time }
        return best
    }

    @ViewBuilder
    private func zoomMenu(_ region: VideoZoomRegion) -> some View {
        Button(region.followsCursor ? "Aim by Hand" : "Follow Cursor") {
            model.updateZoom(region.id) { $0.followsCursor.toggle() }
        }
        Menu("Zoom Level") {
            ForEach([1.25, 1.5, 2, 2.5, 3, 4], id: \.self) { scale in
                Button(VideoEditorModel.formatScale(scale)) {
                    model.updateZoom(region.id) { $0.scale = scale }
                }
            }
        }
        Button("Duplicate") { model.duplicateZoom(region.id) }
        Divider()
        Button("Delete Zoom", role: .destructive) { model.deleteZoom(region.id) }
    }

    // MARK: Clip track

    private var clipTrack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                VideoTimelineClipView(
                    model: model,
                    segment: segment,
                    index: index,
                    pointsPerSecond: pointsPerSecond,
                    selected: model.selectedClipID == segment.id,
                    thumbnails: model.thumbnails,
                    waveform: model.waveform,
                    sourceAspect: model.project.sourceHeight > 0 ? model.project.sourceWidth / model.project.sourceHeight : 16 / 9
                )
                .equatable()
                .offset(x: x(segment.timelineStart) + 1)
            }

            if case .range(let range) = model.selection {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.red.opacity(0.8), lineWidth: 1.5))
                    .frame(width: max(CGFloat(range.duration) * pointsPerSecond, 3), height: M.clipTrackHeight)
                    .offset(x: x(range.start))
                    .allowsHitTesting(false)
            }

            ForEach(model.cutGaps) { gap in
                Button {
                    model.restore(gap)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "scissors")
                        Text(VideoEditorModel.format(gap.duration))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color(red: 1, green: 0.84, blue: 0.3)))
                }
                .buttonStyle(.plain)
                .help("Removed \(VideoEditorModel.format(gap.duration)) — click to restore")
                .offset(x: x(gap.timelineTime) - 24, y: -9)
            }
        }
        .offset(y: clipTop)
    }

    // MARK: Overlays

    private var overlayLanes: some View {
        // Where each annotation is on screen after cuts — the same span the
        // renderer draws (its first moment may have been cut away).
        let spans = Dictionary(model.plan.overlays.map { ($0.effect.id, ($0.start, $0.end)) }, uniquingKeysWith: { first, _ in first })
        return ZStack(alignment: .topLeading) {
            ForEach(model.project.overlayEffects) { effect in
                if let span = spans[effect.id] {
                    overlayPill(effect, start: span.0, end: max(span.1, span.0 + 0.1))
                }
            }
        }
        .offset(y: overlayTop)
    }

    private func overlayPill(_ effect: VideoDemoOverlayEffect, start: Double, end: Double) -> some View {
        let selected = model.selection == .overlay(effect.id)
        let shown = overlayDrag?.id == effect.id ? (overlayDrag!.start, overlayDrag!.end) : (start, end)
        let width = max(CGFloat(shown.1 - shown.0) * pointsPerSecond, 26)
        // The pill wears the annotation's own color, so the two match up.
        let custom = effect.color.flatMap { $0.a > 0.1 && effect.kind.hasColor ? $0 : nil }
        let tint = custom.map { Color(nsColor: $0.withAlpha(1).nsColor) } ?? VideoEditorTheme.overlayTint(effect.kind)
        let ink: Color = (custom?.luminance ?? 0) > 0.62 ? Color.black.opacity(0.8) : .white
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(selected ? 0.9 : 0.62))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.95 : 0.14), lineWidth: selected ? 1.5 : 1)
            HStack(spacing: 4) {
                Image(systemName: effect.kind.icon)
                    .font(.system(size: 9.5, weight: .bold))
                if width > 70 {
                    Text(effect.kind == .text ? effect.text : effect.kind.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            HStack(spacing: 0) {
                edgeHandle.gesture(overlayEdgeGesture(effect, start: start, end: end, leading: true))
                Spacer(minLength: 0)
                edgeHandle.gesture(overlayEdgeGesture(effect, start: start, end: end, leading: false))
            }
        }
        .frame(width: width, height: M.overlayLaneHeight)
        .contentShape(Rectangle())
        .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        .gesture(overlayMoveGesture(effect, start: start, end: end))
        .contextMenu {
            Button("Delete", role: .destructive) { model.deleteOverlay(effect.id) }
        }
        .offset(x: x(shown.0), y: laneY(effect.layer))
    }

    private func overlayMoveGesture(_ effect: VideoDemoOverlayEffect, start: Double, end: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != effect.id {
                    dragOrigin = TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                    overlayDrag = (effect.id, start, end, effect.layer)
                    hover.setDragging(true)
                    model.selection = .overlay(effect.id)
                }
                guard let origin = dragOrigin, abs(value.translation.width) > 2 || abs(value.translation.height) > 4 else { return }
                let delta = Double(value.translation.width / pointsPerSecond)
                let length = origin.end - origin.start
                let newStart = min(max(origin.start + delta, 0), duration - length)
                overlayDrag = (effect.id, newStart, newStart + length, origin.layer)
                model.setOverlayWindow(effect.id, start: newStart, end: newStart + length, coalesce: "overlay-\(effect.id)")
                // Dragging UP brings it forward (a higher lane).
                let lane = Int((-value.translation.height / (M.overlayLaneHeight + M.overlayLaneGap)).rounded())
                model.setOverlayLayer(effect.id, layer: origin.layer + lane, coalesce: "overlay-\(effect.id)")
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                overlayDrag = nil
                dragOrigin = nil
                hover.setDragging(false)
                model.finishOverlayDrag()
                if abs(value.translation.width) <= 2, abs(value.translation.height) <= 4 {
                    model.selection = .overlay(effect.id)
                    model.seek(to: origin.start + min(0.3, (origin.end - origin.start) / 2))
                }
            }
    }

    private func overlayEdgeGesture(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != effect.id {
                    dragOrigin = TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                    overlayDrag = (effect.id, start, end, effect.layer)
                    hover.setDragging(true)
                    model.selection = .overlay(effect.id)
                }
                guard let origin = dragOrigin else { return }
                let delta = Double(value.translation.width / pointsPerSecond)
                let newStart = leading ? min(max(origin.start + delta, 0), origin.end - 0.2) : origin.start
                let newEnd = leading ? origin.end : min(max(origin.end + delta, origin.start + 0.2), duration)
                overlayDrag = (effect.id, newStart, newEnd, origin.layer)
                model.setOverlayWindow(effect.id, start: newStart, end: newEnd, coalesce: "overlay-edge-\(effect.id)")
            }
            .onEnded { _ in
                overlayDrag = nil
                dragOrigin = nil
                hover.setDragging(false)
                model.finishOverlayDrag()
            }
    }
}

struct TimelineDragOrigin: Equatable {
    let id: UUID
    let start: Double
    let end: Double
    var layer: Int = 0
}

// MARK: - Clip

struct VideoTimelineClipView: View, Equatable {
    let model: VideoEditorModel
    let segment: VideoDemoTimelineSegment
    let index: Int
    let pointsPerSecond: CGFloat
    let selected: Bool
    let thumbnails: [VideoTimelineThumbnail]
    let waveform: VideoWaveform?
    let sourceAspect: Double

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.segment == b.segment && a.index == b.index && a.pointsPerSecond == b.pointsPerSecond && a.selected == b.selected
            && a.thumbnails.map(\.id) == b.thumbnails.map(\.id) && a.waveform?.peaks.count == b.waveform?.peaks.count && a.sourceAspect == b.sourceAspect
    }

    @State private var hovered = false
    @State private var trimOrigin: (leading: Bool, source: Double)?

    private typealias M = VideoTimelineMetrics

    var body: some View {
        let width = max(CGFloat(segment.duration) * pointsPerSecond - 2, 8)
        ZStack(alignment: .topLeading) {
            VideoClipFilmstrip(segment: segment, width: width, height: M.clipTrackHeight, thumbnails: thumbnails, waveform: waveform, sourceAspect: sourceAspect)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Amber identity bar along the bottom, like a film edge.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(VideoEditorTheme.clip)
                    .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)

            if width > 70 {
                HStack(spacing: 5) {
                    Text("Clip \(index + 1)")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(VideoEditorModel.format(segment.duration))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    if abs(segment.clip.normalizedSpeed - 1) > 0.01 {
                        Text(VideoEditorModel.formatScale(segment.clip.normalizedSpeed))
                            .font(.system(size: 9.5, weight: .heavy))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                    if segment.clip.muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(Capsule().fill(Color.black.opacity(0.62)))
                .padding(5)
                .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.white : (hovered ? Color.white.opacity(0.35) : Color.white.opacity(0.12)), lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                trimHandle(leading: true)
                Spacer(minLength: 0)
                trimHandle(leading: false)
            }
        }
        .frame(width: width, height: M.clipTrackHeight)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(scrubGesture)
        .contextMenu { clipMenu }
    }

    @State private var rangeAnchor: Double?

    private func timelineTime(_ localX: CGFloat) -> Double {
        min(max(segment.timelineStart + Double(localX / pointsPerSecond), 0), model.timelineDuration)
    }

    /// Drag scrubs; ⇧-drag marks a range to delete; a click selects.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = timelineTime(value.location.x)
                if NSEvent.modifierFlags.contains(.shift) || rangeAnchor != nil {
                    if rangeAnchor == nil { rangeAnchor = timelineTime(value.startLocation.x) }
                    if let rangeAnchor {
                        model.selection = .range(VideoDemoTimelineRange(start: rangeAnchor, end: time).normalized)
                    }
                } else {
                    model.seek(to: time, fast: true)
                }
            }
            .onEnded { value in
                if rangeAnchor == nil {
                    model.seek(to: timelineTime(value.location.x), fast: false)
                    if abs(value.translation.width) < 3 {
                        model.selectClip(segment.id)
                    }
                }
                rangeAnchor = nil
            }
    }

    private func trimHandle(leading: Bool) -> some View {
        let emphasized = hovered || selected || trimOrigin?.leading == leading
        return ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(emphasized ? Color.white : Color.white.opacity(0.35))
                .frame(width: emphasized ? 5 : 3, height: emphasized ? 30 : 20)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .frame(width: 14, height: M.clipTrackHeight)
        .contentShape(Rectangle())
        .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
        .highPriorityGesture(
            // Global space: the trailing handle moves with the pointer.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if trimOrigin?.leading != leading {
                        trimOrigin = (leading, leading ? segment.clip.sourceStart : segment.clip.sourceEnd)
                        model.pause()
                        model.selectClip(segment.id)
                    }
                    guard let origin = trimOrigin else { return }
                    let deltaSource = Double(value.translation.width / pointsPerSecond) * segment.clip.normalizedSpeed
                    model.trimClip(segment.id, leading: leading, toSource: origin.source + deltaSource)
                }
                .onEnded { _ in
                    trimOrigin = nil
                    model.endTrim(segment.id, leading: leading)
                }
        )
        .help(leading ? "Drag to change where this clip starts" : "Drag to change where this clip ends")
    }

    @ViewBuilder
    private var clipMenu: some View {
        Button("Split at Playhead") {
            model.splitAtPlayhead()
        }
        Menu("Speed") {
            ForEach([0.5, 1, 1.5, 2, 3, 4, 8, 16], id: \.self) { speed in
                Button {
                    model.setClipSpeed(segment.id, speed)
                    model.endGesture()
                } label: {
                    if abs(segment.clip.normalizedSpeed - speed) < 0.01 {
                        Label(VideoEditorModel.formatScale(speed), systemImage: "checkmark")
                    } else {
                        Text(VideoEditorModel.formatScale(speed))
                    }
                }
            }
        }
        Button(segment.clip.muted ? "Unmute Clip" : "Mute Clip") {
            model.setClipMuted(segment.id, !segment.clip.muted)
        }
        Divider()
        Button("Delete Clip", role: .destructive) {
            model.deleteClip(segment.id)
        }
        .disabled(model.segments.count <= 1)
    }
}

/// Thumbnails for the clip's source range, plus its waveform.
struct VideoClipFilmstrip: View {
    let segment: VideoDemoTimelineSegment
    let width: CGFloat
    let height: CGFloat
    let thumbnails: [VideoTimelineThumbnail]
    let waveform: VideoWaveform?
    let sourceAspect: Double

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.16)))
            let aspect = sourceAspect
            let tileWidth = max(size.height * CGFloat(aspect), 20)
            if !thumbnails.isEmpty {
                var x: CGFloat = 0
                while x < size.width {
                    let fraction = Double((x + tileWidth / 2) / max(size.width, 1))
                    let sourceTime = segment.clip.sourceStart + segment.clip.sourceDuration * min(max(fraction, 0), 1)
                    let nearest = thumbnails.min { abs($0.time - sourceTime) < abs($1.time - sourceTime) }
                    if let nearest {
                        context.draw(Image(nsImage: nearest.image), in: CGRect(x: x, y: 0, width: tileWidth, height: size.height))
                    }
                    x += tileWidth
                }
            }
            if let waveform {
                let barWidth: CGFloat = 2
                let spacing: CGFloat = 1
                let baseline = size.height - 3
                let maxHeight = size.height * 0.42
                var path = Path()
                var x: CGFloat = 2
                while x < size.width - 2 {
                    let a = segment.clip.sourceStart + segment.clip.sourceDuration * Double(x / size.width)
                    let b = segment.clip.sourceStart + segment.clip.sourceDuration * Double((x + barWidth + spacing) / size.width)
                    let peak = CGFloat(waveform.peak(from: a, to: b))
                    let h = max(peak * maxHeight, 1)
                    path.addRoundedRect(in: CGRect(x: x, y: baseline - h, width: barWidth, height: h), cornerSize: CGSize(width: 1, height: 1))
                    x += barWidth + spacing
                }
                context.fill(path, with: .color(segment.clip.muted ? Color.white.opacity(0.25) : Color.white.opacity(0.78)))
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Ruler & playhead

struct VideoTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let major = steps.first { CGFloat($0) * pointsPerSecond >= 72 } ?? 600
            let minor = major / (major >= 1 && major.truncatingRemainder(dividingBy: 5) == 0 ? 5 : 4)
            var t = 0.0
            while t <= duration + 0.0001 {
                let x = inset + CGFloat(t) * pointsPerSecond
                let isMajor = abs((t / major).rounded() * major - t) < 0.0001
                let height: CGFloat = isMajor ? 8 : 4
                context.fill(Path(CGRect(x: x, y: size.height - height, width: 1, height: height)), with: .color(Color.white.opacity(isMajor ? 0.35 : 0.14)))
                if isMajor {
                    let label = context.resolve(Text(Self.label(t, step: major))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45)))
                    // The first label clears the playhead's knob; the last
                    // one is skipped rather than cut off.
                    let labelX = t == 0 ? x + 9 : x + 3
                    if labelX + label.measure(in: size).width <= size.width {
                        context.draw(label, at: CGPoint(x: labelX, y: size.height - 16), anchor: .leading)
                    }
                }
                t += minor
            }
        }
    }

    static func label(_ time: Double, step: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        if step < 1 {
            return String(format: "%d:%04.1f", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }
}

struct VideoTimelinePlayhead: View {
    @ObservedObject var clock: VideoDemoPlaybackClock
    let x: (Double) -> CGFloat
    let height: CGFloat

    var body: some View {
        let position = x(clock.time)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(VideoEditorTheme.playhead)
                .frame(width: 2, height: height)
            PlayheadKnob()
                .fill(VideoEditorTheme.playhead)
                .frame(width: 13, height: 17)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .offset(x: position - 6.5)
        .allowsHitTesting(false)
    }
}

private struct PlayheadKnob: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 3
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
