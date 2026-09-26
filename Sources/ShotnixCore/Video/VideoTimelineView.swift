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

    /// The annotation layers that get a lane, lowest first: one sitting
    /// wholly in a part that was cut away draws nothing and takes none.
    static func overlayLayers(_ project: VideoDemoProject) -> [Int] {
        let clips = project.timelineClips
        let shown = project.overlayEffects.filter { effect in
            clips.isEmpty || clips.contains { $0.sourceStart < effect.time + max(effect.duration, 0.1) && $0.sourceEnd > effect.time }
        }
        return Array(Set(shown.map { max($0.layer, 0) })).sorted()
    }

    static func overlayLanes(_ project: VideoDemoProject) -> Int {
        overlayLayers(project).count
    }

    /// The layer a pill dragged `lanes` lanes up (down when negative) from
    /// `layer` lands on, counting only the lanes on show.
    static func layer(movedFrom layer: Int, by lanes: Int, in layers: [Int]) -> Int {
        guard let index = layers.firstIndex(of: layer) else { return max(layer + lanes, 0) }
        let target = index + lanes
        if target < 0 { return max((layers.first ?? 0) - 1, 0) }
        if target < layers.count { return layers[target] }
        return (layers.last ?? 0) + (target - layers.count + 1)
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
                .accessibilityLabel("Delete selection")
            }

            if model.hasAudio {
                Button {
                    model.togglePreviewMute()
                } label: {
                    Image(systemName: model.previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help(model.previewMuted ? "Unmute the preview (M)" : "Mute the preview (M) — the export keeps its sound")
                .accessibilityLabel(model.previewMuted ? "Unmute preview" : "Mute preview")
            }

            HStack(spacing: 6) {
                Button {
                    model.zoomTimeline(by: 1 / 1.4)
                } label: {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .accessibilityLabel("Show more of the timeline")
                Slider(value: Binding(get: { log(model.timelineZoom) / log(model.maxTimelineZoom) }, set: { model.timelineZoom = pow(model.maxTimelineZoom, $0) }), in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)
                    .accessibilityLabel("Timeline scale")
                Button {
                    model.zoomTimeline(by: 1.4)
                } label: {
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .accessibilityLabel("Show the timeline in more detail")
            }
            .font(.system(size: 12, weight: .semibold))
            .help("Timeline scale (pinch, or ⌘-scroll)")
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
    /// Where the dragged bar's edges can land, gathered when the drag began.
    @State private var snapper: VideoTimelineSnapper?
    /// The drag moves every selected bar (it began on one of several).
    @State private var movesGroup = false
    /// ⇧ or ⌘ was held when the press began: a click adds or removes.
    @State private var extending = false
    @State private var rangeStart: Double?
    @State private var pinchBase: Double?
    /// Anchored zooming, ⌘-scroll, and paging after the playhead.
    @State private var scroller = VideoTimelineScroller()

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

    /// Lane `layer` sits higher the higher its layer (and draws in front);
    /// only the layers on show count.
    private func laneY(_ layer: Int, in layers: [Int]) -> CGFloat {
        let index = layers.firstIndex(of: layer) ?? layers.filter { $0 < layer }.count
        return CGFloat(max(layers.count - 1 - index, 0)) * (M.overlayLaneHeight + M.overlayLaneGap)
    }

    /// A moved bar, from where it was when the drag began, landing an edge
    /// on anything within reach.
    private func movedWindow(_ origin: TimelineDragOrigin, by translation: CGFloat) -> (start: Double, end: Double) {
        let length = origin.end - origin.start
        let raw = min(max(origin.start + Double(translation / pointsPerSecond), 0), max(duration - length, 0))
        let shift = snapper?.shift(start: raw, end: raw + length)
        hover.setSnap(shift?.target)
        let start = min(max(raw + (shift?.delta ?? 0), 0), max(duration - length, 0))
        return (start, start + length)
    }

    /// A dragged edge, landing on anything within reach.
    private func snappedEdge(_ time: Double) -> Double {
        guard let snapped = snapper?.snap(time) else { return time }
        hover.setSnap(snapped.target)
        return snapped.time
    }

    var body: some View {
        let height = max(M.contentHeight(model.project), viewport.height)
        let overflows = height > viewport.height + 0.5
        // Lanes that don't fit scroll vertically. It opens (and starts
        // overflowing) at the bottom, where the recording itself is.
        ScrollViewReader { reader in
        ScrollView(.vertical, showsIndicators: overflows) {
        VStack(spacing: 0) {
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
                        selectedIDs: model.selectedIDs { if case .click(let id) = $0 { return id } else { return nil } },
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
                        selectedIDs: model.selectedIDs { if case .caption(let id) = $0 { return id } else { return nil } },
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
                        selectedIDs: model.selectedIDs { if case .keystroke(let id) = $0 { return id } else { return nil } },
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
                        selectedIDs: model.selectedIDs { if case .cameraLayout(let id) = $0 { return id } else { return nil } },
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
                VideoTimelinePlayheadFollower(clock: model.clock, model: model, scroller: scroller, x: { x($0) })
            }
            .frame(width: contentWidth + M.inset * 2, height: height, alignment: .topLeading)
            .background(VideoTimelineScrollFinder(scroller: scroller, model: model))
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
                        // Pinching zooms around the pointer.
                        if let time = hover.time { model.pendingZoomAnchor = (time, x(time) - scroller.visible.minX) }
                        model.timelineZoom = min(max((pinchBase ?? 1) * value, 1), model.maxTimelineZoom)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .frame(height: height)
        Color.clear.frame(height: 0).id(Self.bottomAnchor)
        }
        }
        .onAppear { reader.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        .onChange(of: overflows) { now in
            // Not mid-drag: the dragged bar would leave the view.
            if now, !hover.dragging { reader.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
        }
        .onAppear {
            scroller.pointsPerSecond = pointsPerSecond
            model.timelineViewportWidth = max(viewport.width - M.inset * 2, 100)
        }
        .onChange(of: viewport.width) { width in
            model.timelineViewportWidth = max(width - M.inset * 2, 100)
        }
        .onChange(of: contentWidth) { _ in
            // A new scale: the moment under the pointer (or the playhead)
            // stays where it was once the strip has its new width.
            let anchor = scroller.anchor(playhead: model.clock.time)
            let scale = pointsPerSecond
            scroller.pointsPerSecond = scale
            DispatchQueue.main.async { scroller.restore(anchor, pointsPerSecond: scale) }
        }
        .onChange(of: duration) { _ in scroller.pointsPerSecond = pointsPerSecond }
    }

    private static let bottomAnchor = "timeline-bottom"

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
                } else if case .range(let range) = model.selection, range.duration < 0.1 {
                    // A ⇧-click, not a drag: nothing to cut.
                    model.selection = .none
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
        let selected = model.isSelected(.zoom(region.id))
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
                        Text(region.followsCursor ? "· follows cursor" : "· aim by hand")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityDescription(of: .zoom(region.id)))
        .accessibilityHint("Adjust to move it half a second")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            model.selection = .zoom(region.id)
            model.inspectorTab = .zoom
        }
        .accessibilityAction(named: "Delete") { model.deleteZoom(region.id) }
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            model.setZoomWindow(region.id, start: range.lowerBound + step, end: range.upperBound + step, coalesce: "zoom-nudge")
            model.endGesture()
        }
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
                    beginBarDrag(.zoom(region.id))
                    zoomDrag = (region.id, range.lowerBound, range.upperBound)
                    hover.setDragging(true)
                    if !movesGroup, !extending {
                        model.selection = .zoom(region.id)
                        if !region.followsCursor { model.pause() }
                    }
                }
                guard let origin = dragOrigin, abs(value.translation.width) > 2 else { return }
                NSCursor.closedHand.set()
                let moved = movedWindow(origin, by: value.translation.width)
                if movesGroup {
                    model.moveGroup(by: moved.start - origin.start)
                } else {
                    model.setZoomWindow(region.id, start: moved.start, end: moved.end, coalesce: "zoom-move-\(region.id)")
                }
                if let updated = model.project.zoomRegions.first(where: { $0.id == region.id }).flatMap({ model.zoomTimelineRange($0) }) {
                    zoomDrag = (region.id, updated.lowerBound, updated.upperBound)
                }
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                let clicked = abs(value.translation.width) <= 2
                if !clicked {
                    let moved = movedWindow(origin, by: value.translation.width)
                    if movesGroup {
                        model.moveGroup(by: moved.start - origin.start)
                    } else {
                        model.setZoomWindow(region.id, start: moved.start, end: moved.end, coalesce: "zoom-move-\(region.id)")
                    }
                }
                let wasExtending = extending
                endBarDrag()
                zoomDrag = nil
                model.endGesture()
                if clicked {
                    if wasExtending {
                        model.toggleSelection(.zoom(region.id))
                    } else {
                        model.selection = .zoom(region.id)
                        model.inspectorTab = .zoom
                        if !(region.followsCursor) || !model.isPlaying {
                            // Show the zoom: park inside it once the camera arrived.
                            let target = min(origin.start + min(1.2, (origin.end - origin.start) / 2), origin.end)
                            model.seek(to: target)
                        }
                    }
                }
                NSCursor.openHand.set()
            }
    }

    /// A press on a bar begins: will a click add to the selection, and does
    /// a drag move the whole selection?
    private func beginBarDrag(_ item: VideoEditorModel.Selection) {
        extending = VideoEditorModel.extendsSelection
        movesGroup = !extending && model.movesAsGroup(item)
        let excluded = Set((movesGroup ? model.selectedItems : [item]).compactMap(\.itemID))
        snapper = VideoTimelineSnapper(targets: model.snapTargets(excluding: excluded), pointsPerSecond: pointsPerSecond)
        if movesGroup { model.beginGroupMove() }
    }

    private func endBarDrag() {
        if movesGroup { model.endGroupMove() }
        movesGroup = false
        extending = false
        dragOrigin = nil
        snapper = nil
        hover.setDragging(false)
    }

    private func zoomEdgeGesture(_ region: VideoZoomRegion, range: ClosedRange<Double>, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != region.id {
                    dragOrigin = TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                    snapper = VideoTimelineSnapper(targets: model.snapTargets(excluding: [region.id]), pointsPerSecond: pointsPerSecond)
                    zoomDrag = (region.id, range.lowerBound, range.upperBound)
                    hover.setDragging(true)
                    model.selection = .zoom(region.id)
                }
                guard let origin = dragOrigin else { return }
                let (start, end) = zoomEdges(origin, leading: leading, by: value.translation.width)
                model.setZoomWindow(region.id, start: start, end: end, coalesce: "zoom-edge-\(region.id)")
                if let updated = model.project.zoomRegions.first(where: { $0.id == region.id }).flatMap({ model.zoomTimelineRange($0) }) {
                    zoomDrag = (region.id, updated.lowerBound, updated.upperBound)
                }
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: region.id, start: range.lowerBound, end: range.upperBound)
                let (start, end) = zoomEdges(origin, leading: leading, by: value.translation.width)
                model.setZoomWindow(region.id, start: start, end: end, coalesce: "zoom-edge-\(region.id)")
                zoomDrag = nil
                dragOrigin = nil
                snapper = nil
                hover.setDragging(false)
                model.endGesture()
            }
    }

    /// A zoom with one edge dragged (snapping), never shorter than a zoom
    /// can be.
    private func zoomEdges(_ origin: TimelineDragOrigin, leading: Bool, by translation: CGFloat) -> (Double, Double) {
        let delta = Double(translation / pointsPerSecond)
        if leading {
            return (min(snappedEdge(origin.start + delta), origin.end - VideoZoomRegion.minimumDuration), origin.end)
        }
        return (origin.start, max(snappedEdge(origin.end + delta), origin.start + VideoZoomRegion.minimumDuration))
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
                    selected: model.isSelected(.clip(segment.id)),
                    thumbnails: model.thumbnails,
                    waveform: model.waveform,
                    sourceAspect: model.project.sourceHeight > 0 ? model.project.sourceWidth / model.project.sourceHeight : 16 / 9,
                    hover: hover
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

            // Markers closer than a marker's width share one (Remove Ums can
            // leave dozens): it lists each cut and can restore them all.
            ForEach(VideoEditorModel.CutGap.grouped(model.cutGaps, within: 46 / pointsPerSecond), id: \.first!.id) { group in
                if group.count == 1, let gap = group.first {
                    Button {
                        model.restore(gap)
                    } label: {
                        restorePill(symbol: "scissors", text: VideoEditorModel.format(gap.duration))
                    }
                    .buttonStyle(.plain)
                    .help("Removed \(VideoEditorModel.format(gap.duration)) — click to restore")
                    .accessibilityLabel("Restore \(VideoEditorModel.format(gap.duration)) cut at \(VideoEditorModel.timecode(gap.timelineTime))")
                    .offset(x: x(gap.timelineTime) - 24, y: -9)
                } else {
                    let total = group.reduce(0) { $0 + $1.duration }
                    Menu {
                        ForEach(group) { gap in
                            Button("Restore \(VideoEditorModel.format(gap.duration)) at \(VideoEditorModel.timecode(gap.timelineTime))") { model.restore(gap) }
                        }
                        Divider()
                        Button("Restore All \(group.count)") { model.restore(group) }
                    } label: {
                        restorePill(symbol: "scissors", text: "\(group.count) · \(VideoEditorModel.format(total))")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(group.count) cuts here (\(VideoEditorModel.format(total)) removed) — click to restore some or all")
                    .accessibilityLabel("\(group.count) cuts, \(VideoEditorModel.format(total)) removed")
                    .offset(x: x(group.first?.timelineTime ?? 0) - 24, y: -9)
                }
            }
        }
        .offset(y: clipTop)
    }

    private func restorePill(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(Color(red: 1, green: 0.84, blue: 0.3)))
    }

    // MARK: Overlays

    private var overlayLanes: some View {
        // Where each annotation is on screen after cuts — the same span the
        // renderer draws (its first moment may have been cut away).
        let spans = Dictionary(model.plan.overlays.map { ($0.effect.id, ($0.start, $0.end)) }, uniquingKeysWith: { first, _ in first })
        let layers = M.overlayLayers(model.project)
        return ZStack(alignment: .topLeading) {
            ForEach(model.project.overlayEffects) { effect in
                if let span = spans[effect.id] {
                    overlayPill(effect, start: span.0, end: max(span.1, span.0 + 0.1), layers: layers)
                }
            }
        }
        .offset(y: overlayTop)
    }

    private func overlayPill(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, layers: [Int]) -> some View {
        let selected = model.isSelected(.overlay(effect.id))
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
        .gesture(overlayMoveGesture(effect, start: start, end: end, layers: layers))
        .contextMenu {
            Button("Delete", role: .destructive) { model.deleteOverlay(effect.id) }
        }
        .offset(x: x(shown.0), y: laneY(effect.layer, in: layers))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityDescription(of: .overlay(effect.id)))
        .accessibilityHint("Adjust to move it half a second")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selection = .overlay(effect.id) }
        .accessibilityAction(named: "Delete") { model.deleteOverlay(effect.id) }
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            model.setOverlayWindow(effect.id, start: start + step, end: end + step, coalesce: "overlay-nudge")
            model.endGesture()
        }
    }

    private func overlayMoveGesture(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, layers: [Int]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != effect.id {
                    dragOrigin = TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer, layers: layers)
                    beginBarDrag(.overlay(effect.id))
                    overlayDrag = (effect.id, start, end, effect.layer)
                    hover.setDragging(true)
                    if !movesGroup, !extending { model.selection = .overlay(effect.id) }
                }
                guard let origin = dragOrigin, abs(value.translation.width) > 2 || abs(value.translation.height) > 4 else { return }
                let moved = movedWindow(origin, by: value.translation.width)
                overlayDrag = (effect.id, moved.start, moved.end, origin.layer)
                if movesGroup {
                    // Everything selected moves along in time (lanes stay).
                    model.moveGroup(by: moved.start - origin.start)
                    return
                }
                model.setOverlayWindow(effect.id, start: moved.start, end: moved.end, coalesce: "overlay-\(effect.id)")
                // Dragging UP brings it forward (a higher lane).
                let lanes = Int((-value.translation.height / (M.overlayLaneHeight + M.overlayLaneGap)).rounded())
                model.setOverlayLayer(effect.id, layer: M.layer(movedFrom: origin.layer, by: lanes, in: origin.layers), coalesce: "overlay-\(effect.id)")
            }
            .onEnded { value in
                let origin = dragOrigin ?? TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                let wasExtending = extending
                let wasGroup = movesGroup
                endBarDrag()
                overlayDrag = nil
                if !wasGroup { model.finishOverlayDrag() }
                if abs(value.translation.width) <= 2, abs(value.translation.height) <= 4 {
                    if wasExtending {
                        model.toggleSelection(.overlay(effect.id))
                    } else {
                        model.selection = .overlay(effect.id)
                        model.seek(to: origin.start + min(0.3, (origin.end - origin.start) / 2))
                    }
                }
            }
    }

    private func overlayEdgeGesture(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin?.id != effect.id {
                    dragOrigin = TimelineDragOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                    snapper = VideoTimelineSnapper(targets: model.snapTargets(excluding: [effect.id]), pointsPerSecond: pointsPerSecond)
                    overlayDrag = (effect.id, start, end, effect.layer)
                    hover.setDragging(true)
                    model.selection = .overlay(effect.id)
                }
                guard let origin = dragOrigin else { return }
                let delta = Double(value.translation.width / pointsPerSecond)
                let newStart = leading ? min(max(snappedEdge(origin.start + delta), 0), origin.end - 0.2) : origin.start
                let newEnd = leading ? origin.end : min(max(snappedEdge(origin.end + delta), origin.start + 0.2), duration)
                overlayDrag = (effect.id, newStart, newEnd, origin.layer)
                model.setOverlayWindow(effect.id, start: newStart, end: newEnd, coalesce: "overlay-edge-\(effect.id)")
            }
            .onEnded { _ in
                overlayDrag = nil
                dragOrigin = nil
                snapper = nil
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
    /// The annotation layers on show when the drag began.
    var layers: [Int] = []
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
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.segment == b.segment && a.index == b.index && a.pointsPerSecond == b.pointsPerSecond && a.selected == b.selected
            && a.thumbnails.map(\.id) == b.thumbnails.map(\.id) && a.waveform?.peaks.count == b.waveform?.peaks.count && a.sourceAspect == b.sourceAspect
    }

    @State private var hovered = false
    @State private var trimOrigin: (leading: Bool, source: Double)?
    /// Dragging the clip by its name to another place in the video.
    @State private var reorderOffset: CGFloat?

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
                .background(Capsule().fill(Color.black.opacity(reorderOffset == nil ? 0.62 : 0.85)))
                .contentShape(Capsule())
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .gesture(reorderGesture)
                .help("Drag to move this clip to another place in the video")
                .padding(5)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityDescription(of: .clip(segment.id)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectClip(segment.id) }
        .accessibilityAction(named: "Split at Playhead") { model.splitAtPlayhead() }
        .accessibilityAction(named: "Move Earlier") { model.moveClip(segment.id, toIndex: index - 1) }
        .accessibilityAction(named: "Move Later") { model.moveClip(segment.id, toIndex: index + 1) }
        .accessibilityAction(named: "Delete") { model.deleteClip(segment.id) }
        .offset(x: reorderOffset ?? 0)
        .opacity(reorderOffset == nil ? 1 : 0.85)
        .shadow(color: .black.opacity(reorderOffset == nil ? 0 : 0.6), radius: 10, y: 4)
    }

    /// Where the dragged clip would land: the number of other clips whose
    /// middle is before its middle.
    private func reorderTarget(offset: CGFloat) -> (index: Int, boundary: Double) {
        let center = segment.timelineStart + segment.duration / 2 + Double(offset / pointsPerSecond)
        let others = model.segments.filter { $0.id != segment.id }
        let index = others.filter { $0.timelineStart + $0.duration / 2 < center }.count
        let boundary = index < others.count ? others[index].timelineStart : (others.last?.timelineEnd ?? 0)
        return (index, boundary)
    }

    /// Drag a clip by its name to put it somewhere else in the video.
    private var reorderGesture: some Gesture {
        // Global space: the clip moves under the pointer.
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if reorderOffset == nil {
                    model.pause()
                    hover.setDragging(true)
                }
                NSCursor.closedHand.set()
                reorderOffset = value.translation.width
                hover.setSnap(reorderTarget(offset: value.translation.width).boundary)
            }
            .onEnded { value in
                let target = reorderTarget(offset: value.translation.width)
                reorderOffset = nil
                hover.setDragging(false)
                model.moveClip(segment.id, toIndex: target.index)
                NSCursor.openHand.set()
            }
    }

    @State private var rangeAnchor: Double?

    private func timelineTime(_ localX: CGFloat) -> Double {
        min(max(segment.timelineStart + Double(localX / pointsPerSecond), 0), model.timelineDuration)
    }

    /// Drag scrubs; ⇧-drag marks a range to delete; a click selects (⇧- or
    /// ⌘-click adds the clip to the selection, or takes it out).
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = timelineTime(value.location.x)
                if NSEvent.modifierFlags.contains(.shift) || rangeAnchor != nil {
                    // Not a range until it moves: a ⇧-click picks the clip.
                    if rangeAnchor == nil, abs(value.translation.width) < 3 { return }
                    if rangeAnchor == nil { rangeAnchor = timelineTime(value.startLocation.x) }
                    if let rangeAnchor {
                        model.selection = .range(VideoDemoTimelineRange(start: rangeAnchor, end: time).normalized)
                    }
                } else if !NSEvent.modifierFlags.contains(.command) {
                    model.seek(to: time, fast: true)
                }
            }
            .onEnded { value in
                if rangeAnchor == nil {
                    if abs(value.translation.width) < 3, VideoEditorModel.extendsSelection {
                        model.toggleSelection(.clip(segment.id))
                    } else {
                        model.seek(to: timelineTime(value.location.x), fast: false)
                        if abs(value.translation.width) < 3 {
                            model.selectClip(segment.id)
                        }
                    }
                } else if case .range(let range) = model.selection, range.duration < 0.1 {
                    model.selection = .none
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
        Button("Move Earlier") { model.moveClip(segment.id, toIndex: index - 1) }
            .disabled(index == 0)
        Button("Move Later") { model.moveClip(segment.id, toIndex: index + 1) }
            .disabled(index >= model.segments.count - 1)
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
    /// Snapshots for the website, which draws its own live playhead.
    nonisolated(unsafe) static var hiddenInSnapshots = false

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
        .opacity(Self.hiddenInSnapshots ? 0 : 1)
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
