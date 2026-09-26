import AppKit
import SwiftUI

/// Pointer position over the timeline, kept out of the surface so moving
/// the mouse only redraws the hover guides, never the lanes.
@MainActor
final class VideoTimelineHover: ObservableObject {
    @Published private(set) var time: Double?
    @Published private(set) var overZoomTrack = false
    /// Hover guides hide while anything is being dragged.
    @Published private(set) var dragging = false
    /// Where a dragged edge snapped (a guide line shows it).
    @Published private(set) var snapTime: Double?

    func update(time: Double?, overZoomTrack: Bool) {
        if self.time != time { self.time = time }
        if self.overZoomTrack != overZoomTrack { self.overZoomTrack = overZoomTrack }
    }

    func setDragging(_ dragging: Bool) {
        if self.dragging != dragging { self.dragging = dragging }
        if !dragging { setSnap(nil) }
    }

    func setSnap(_ time: Double?) {
        if snapTime != time { snapTime = time }
    }
}

/// Where dragged bars and edges land: the playhead, clip edges, clicks,
/// and the edges of every other bar on the timeline — when one is within a
/// few points. Zooms, annotations, captions, and camera layouts all use it.
struct VideoTimelineSnapper {
    /// Sorted timeline times.
    let targets: [Double]
    /// Seconds (the reach in points at the current scale).
    let threshold: Double

    init(targets: [Double], pointsPerSecond: CGFloat, reach: CGFloat = 8) {
        self.targets = targets.sorted()
        threshold = Double(reach / max(pointsPerSecond, 0.0001))
    }

    /// The target nearest `time`, when it's within reach.
    func target(near time: Double) -> Double? {
        guard !targets.isEmpty else { return nil }
        var low = 0
        var high = targets.count
        while low < high {
            let mid = (low + high) / 2
            if targets[mid] < time { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { targets.indices.contains($0) }.map { targets[$0] }
        guard let best = candidates.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) <= threshold else { return nil }
        return best
    }

    /// An edge being dragged: the target it lands on (or itself).
    func snap(_ time: Double) -> (time: Double, target: Double?) {
        guard let target = target(near: time) else { return (time, nil) }
        return (target, target)
    }

    /// A whole bar being moved: the shift that lands its nearer edge on a
    /// target (0 when neither edge is near one).
    func shift(start: Double, end: Double) -> (delta: Double, target: Double?) {
        let a = target(near: start).map { ($0 - start, $0) }
        let b = target(near: end).map { ($0 - end, $0) }
        switch (a, b) {
        case let (a?, b?): return abs(a.0) <= abs(b.0) ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return (0, nil)
        }
    }
}

/// x ↔ time for the lanes (identical to the surface's mapping).
struct VideoTimelineGeometry: Equatable {
    let pointsPerSecond: CGFloat
    let duration: Double
    /// Content width including the insets.
    let width: CGFloat

    func x(_ time: Double) -> CGFloat { VideoTimelineMetrics.inset + CGFloat(time) * pointsPerSecond }
    func time(_ x: CGFloat) -> Double {
        min(max(Double((x - VideoTimelineMetrics.inset) / pointsPerSecond), 0), duration)
    }
}

// MARK: - Hover guides

/// The ghost playhead that follows the mouse, the "+ Zoom" preview on the
/// zoom track, and the empty-track hint.
struct VideoTimelineHoverLayer: View {
    @ObservedObject var hover: VideoTimelineHover
    let model: VideoEditorModel
    let geometry: VideoTimelineGeometry
    let height: CGFloat
    let zoomTop: CGFloat
    let showsZoomHint: Bool
    let viewportWidth: CGFloat

    private typealias M = VideoTimelineMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsZoomHint, !hover.overZoomTrack {
                HStack(spacing: 6) {
                    Image(systemName: "plus.magnifyingglass")
                    Text("Click to add a zoom — or press Z at the playhead")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .frame(width: min(geometry.width - M.inset * 2, viewportWidth - M.inset * 2), height: M.zoomTrackHeight)
                .offset(x: M.inset, y: zoomTop)
            }
            if let time = hover.time, !hover.dragging {
                if hover.overZoomTrack { zoomGhost(at: time) }
                ghostPlayhead(time)
            }
            if hover.dragging, let snap = hover.snapTime {
                // A dragged edge landed on something.
                Rectangle()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 1, height: height - M.rulerHeight)
                    .offset(x: geometry.x(snap), y: M.rulerHeight)
            }
        }
        .frame(width: geometry.width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func ghostPlayhead(_ time: Double) -> some View {
        let position = geometry.x(time)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: height - M.rulerHeight)
                .offset(x: position, y: M.rulerHeight)
            Text(VideoEditorModel.timecode(time))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                .offset(x: position + 4, y: 3)
        }
    }

    @ViewBuilder
    private func zoomGhost(at time: Double) -> some View {
        let gap = model.zoomGap(around: time)
        let length = min(3, gap.upperBound - gap.lowerBound)
        let start = max(min(time - 0.2, gap.upperBound - length), gap.lowerBound)
        if length >= VideoZoomRegion.minimumDuration {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Zoom")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.8))
            .frame(width: max(CGFloat(length) * geometry.pointsPerSecond, 30), height: M.zoomTrackHeight - 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VideoEditorTheme.zoom.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(VideoEditorTheme.zoom.opacity(0.14)))
            )
            .offset(x: geometry.x(start), y: zoomTop + 2)
        }
    }
}

// MARK: - Captions lane

/// Every caption as a chip on one canvas: drag to move, drag an edge to
/// retime, click to select. One view for hundreds of captions.
struct VideoCaptionLane: View, Equatable {
    struct Item: Equatable {
        let id: UUID
        let start: Double
        let end: Double
        let text: String
    }

    let items: [Item]
    let selectedIDs: Set<UUID>
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedIDs == b.selectedIDs && a.geometry == b.geometry
    }

    private typealias Mode = VideoLaneDrag.Mode

    private struct Drag {
        let id: UUID
        let mode: Mode
        let originStart: Double
        let originEnd: Double
        let press: VideoLaneDrag.Press
        var moved = false
    }

    @State private var drag: Drag?
    private typealias M = VideoTimelineMetrics
    private static let edge: CGFloat = 7

    private func rect(_ item: Item) -> CGRect {
        let minX = geometry.x(item.start) + 1
        let width = max(CGFloat(item.end - item.start) * geometry.pointsPerSecond - 2, 8)
        return CGRect(x: minX, y: 0, width: width, height: M.captionLaneHeight)
    }

    private func hit(_ point: CGPoint) -> (Item, Mode)? {
        // Topmost (last drawn) first.
        for item in items.reversed() {
            let frame = rect(item)
            guard frame.insetBy(dx: -2, dy: 0).contains(point) else { continue }
            if frame.width > Self.edge * 3 {
                if point.x < frame.minX + Self.edge { return (item, .leading) }
                if point.x > frame.maxX - Self.edge { return (item, .trailing) }
            }
            return (item, .move)
        }
        return nil
    }

    var body: some View {
        Canvas { context, size in
            for item in items {
                let frame = rect(item)
                guard frame.maxX >= 0, frame.minX <= size.width else { continue }
                let selected = selectedIDs.contains(item.id)
                let path = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)
                context.fill(path, with: .color(VideoEditorTheme.caption.opacity(selected ? 0.85 : 0.34)))
                context.stroke(path, with: .color(.white.opacity(selected ? 0.95 : 0.12)), lineWidth: selected ? 1.5 : 1)
                if frame.width > 26 {
                    var inner = context
                    inner.clip(to: Path(frame.insetBy(dx: 5, dy: 0)))
                    inner.draw(
                        Text(item.text).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(selected ? 1 : 0.88)),
                        at: CGPoint(x: frame.minX + 6, y: frame.midY),
                        anchor: .leading
                    )
                }
                if frame.width > Self.edge * 3, selected {
                    for x in [frame.minX + 3, frame.maxX - 3] {
                        context.fill(Path(roundedRect: CGRect(x: x - 1, y: frame.midY - 5, width: 2, height: 10), cornerRadius: 1), with: .color(.white.opacity(0.7)))
                    }
                }
            }
        }
        .frame(width: geometry.width, height: M.captionLaneHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase, let (_, mode) = hit(point) else {
                NSCursor.arrow.set()
                return
            }
            (mode == .move ? NSCursor.openHand : NSCursor.resizeLeftRight).set()
        }
        .gesture(dragGesture)
        // Drawn chips have no views: VoiceOver gets one element for each.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captions")
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.id) { item in
                    let frame = rect(item)
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                        .accessibilityElement()
                        .accessibilityLabel(model.accessibilityDescription(of: .caption(item.id)))
                        .accessibilityAddTraits(selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { model.selectCaption(item.id) }
                        .accessibilityAction(named: "Delete") { model.deleteCaption(item.id) }
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    guard let (item, mode) = hit(value.startLocation) else {
                        // Empty lane space scrubs like the rest of the timeline.
                        model.seek(to: geometry.time(value.location.x), fast: true)
                        return
                    }
                    let press = VideoLaneDrag.Press(model: model, item: .caption(item.id), moving: mode == .move, pointsPerSecond: geometry.pointsPerSecond)
                    drag = Drag(id: item.id, mode: mode, originStart: item.start, originEnd: item.end, press: press)
                    hover.setDragging(true)
                    if !press.group, !press.extending { model.selection = .caption(item.id) }
                }
                guard var current = drag else { return }
                if abs(value.translation.width) > 2 { current.moved = true }
                drag = current
                guard current.moved else { return }
                let (start, end) = VideoLaneDrag.window(mode: current.mode, start: current.originStart, end: current.originEnd, snapper: current.press.snapper, delta: Double(value.translation.width / geometry.pointsPerSecond), duration: geometry.duration, minimum: 0.2, hover: hover)
                if current.press.group {
                    model.moveGroup(by: start - current.originStart)
                } else {
                    model.setCaptionWindow(current.id, timelineStart: start, timelineEnd: end, moveWords: current.mode == .move)
                }
            }
            .onEnded { value in
                defer {
                    drag = nil
                    hover.setDragging(false)
                }
                guard let current = drag else {
                    model.seek(to: geometry.time(value.location.x), fast: false)
                    return
                }
                current.press.end(model: model)
                if !current.moved {
                    if current.press.extending { model.toggleSelection(.caption(current.id)) } else { model.selectCaption(current.id) }
                }
            }
    }
}

/// Moving a chip on a lane, or dragging one of its edges.
enum VideoLaneDrag {
    enum Mode { case move, leading, trailing }

    /// How a press on a chip began: ⇧/⌘ held (a click adds to or takes
    /// from the selection), or on one of several selected (a move drags
    /// them all) — and where its edges can land.
    @MainActor
    struct Press {
        let extending: Bool
        let group: Bool
        let snapper: VideoTimelineSnapper

        init(model: VideoEditorModel, item: VideoEditorModel.Selection, moving: Bool, pointsPerSecond: CGFloat) {
            extending = VideoEditorModel.extendsSelection
            group = moving && !extending && model.movesAsGroup(item)
            let excluded = Set((group ? model.selectedItems : [item]).compactMap(\.itemID))
            snapper = VideoTimelineSnapper(targets: model.snapTargets(excluding: excluded), pointsPerSecond: pointsPerSecond)
            if group { model.beginGroupMove() }
        }

        func end(model: VideoEditorModel) {
            if group { model.endGroupMove() } else { model.endGesture() }
        }
    }

    /// Where the chip goes, landing on anything in reach.
    @MainActor
    static func window(mode: Mode, start: Double, end: Double, snapper: VideoTimelineSnapper, delta: Double, duration: Double, minimum: Double, hover: VideoTimelineHover) -> (Double, Double) {
        switch mode {
        case .move:
            let length = end - start
            let raw = min(max(start + delta, 0), max(duration - length, 0))
            let shift = snapper.shift(start: raw, end: raw + length)
            hover.setSnap(shift.target)
            let moved = min(max(raw + shift.delta, 0), max(duration - length, 0))
            return (moved, moved + length)
        case .leading:
            let snapped = snapper.snap(start + delta)
            hover.setSnap(snapped.target)
            return (min(max(snapped.time, 0), end - minimum), end)
        case .trailing:
            let snapped = snapper.snap(end + delta)
            hover.setSnap(snapped.target)
            return (start, min(max(snapped.time, start + minimum), duration))
        }
    }
}

// MARK: - Shortcuts lane

/// Keyboard shortcuts as small chips on one canvas; click to select.
struct VideoKeysLane: View, Equatable {
    struct Item: Equatable {
        let id: UUID
        let time: Double
        let label: String
    }

    let items: [Item]
    let selectedIDs: Set<UUID>
    let hidden: Bool
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedIDs == b.selectedIDs && a.hidden == b.hidden && a.geometry == b.geometry
    }

    private typealias M = VideoTimelineMetrics

    private func rect(_ item: Item) -> CGRect {
        CGRect(x: geometry.x(item.time), y: 0, width: CGFloat(item.label.count) * 7 + 10, height: M.keysLaneHeight)
    }

    private func hit(_ point: CGPoint) -> Item? {
        items.reversed().first { rect($0).contains(point) }
    }

    var body: some View {
        Canvas { context, size in
            for item in items {
                let frame = rect(item)
                guard frame.maxX >= 0, frame.minX <= size.width else { continue }
                let selected = selectedIDs.contains(item.id)
                let path = Path(roundedRect: frame, cornerRadius: 5, style: .continuous)
                context.fill(path, with: .color(VideoEditorTheme.keys.opacity(selected ? 0.9 : (hidden ? 0.16 : 0.4))))
                context.stroke(path, with: .color(.white.opacity(selected ? 0.95 : 0.14)), lineWidth: selected ? 1.5 : 1)
                context.draw(
                    Text(item.label).font(.system(size: 9.5, weight: .semibold)).foregroundColor(.white.opacity(hidden ? 0.45 : 0.95)),
                    at: CGPoint(x: frame.midX, y: frame.midY)
                )
            }
        }
        .frame(width: geometry.width, height: M.keysLaneHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase, hit(point) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if hit(value.startLocation) == nil {
                        model.seek(to: geometry.time(value.location.x), fast: true)
                    }
                }
                .onEnded { value in
                    if let item = hit(value.startLocation), abs(value.translation.width) < 3 {
                        if VideoEditorModel.extendsSelection { model.toggleSelection(.keystroke(item.id)) } else { model.selectKeystroke(item.id) }
                    } else {
                        model.seek(to: geometry.time(value.location.x), fast: false)
                    }
                }
        )
        .help("Keyboard shortcuts — click one to select it, ⌫ hides it")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.id) { item in
                    let frame = rect(item)
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                        .accessibilityElement()
                        .accessibilityLabel(model.accessibilityDescription(of: .keystroke(item.id)))
                        .accessibilityAddTraits(selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { model.selectKeystroke(item.id) }
                        .accessibilityAction(named: "Hide") { model.deleteKeystroke(item.id) }
                }
            }
        }
    }
}

// MARK: - Clicks lane

/// Recorded clicks as dots on one canvas: drag a dot to retime it (ripples
/// and Auto Zoom follow), click to jump there.
struct VideoClickLane: View, Equatable {
    struct Item: Equatable {
        let id: UUID
        let time: Double
    }

    let items: [Item]
    let selectedIDs: Set<UUID>
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedIDs == b.selectedIDs && a.geometry == b.geometry
    }

    private struct Drag {
        let id: UUID
        let origin: Double
        var time: Double
        let press: VideoLaneDrag.Press
        var moved = false
    }

    @State private var drag: Drag?
    private typealias M = VideoTimelineMetrics

    private func hit(_ point: CGPoint) -> Item? {
        let nearest = items.min { abs(geometry.x($0.time) - point.x) < abs(geometry.x($1.time) - point.x) }
        guard let nearest, abs(geometry.x(nearest.time) - point.x) <= 7 else { return nil }
        return nearest
    }

    var body: some View {
        Canvas { context, size in
            for item in items {
                let time = drag?.id == item.id ? (drag?.time ?? item.time) : item.time
                let x = geometry.x(time)
                guard x >= -8, x <= size.width + 8 else { continue }
                let selected = selectedIDs.contains(item.id) || drag?.id == item.id
                let dot = Path(ellipseIn: CGRect(x: x - 4, y: (M.clickLaneHeight - 8) / 2, width: 8, height: 8))
                context.fill(dot, with: .color(selected ? .white : .white.opacity(0.55)))
                context.stroke(dot, with: .color(selected ? VideoEditorTheme.zoom : .black.opacity(0.4)), lineWidth: selected ? 2 : 1)
            }
        }
        .frame(width: geometry.width, height: M.clickLaneHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase, hit(point) != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil {
                        guard let item = hit(value.startLocation) else {
                            model.seek(to: geometry.time(value.location.x), fast: true)
                            return
                        }
                        let press = VideoLaneDrag.Press(model: model, item: .click(item.id), moving: true, pointsPerSecond: geometry.pointsPerSecond)
                        drag = Drag(id: item.id, origin: item.time, time: item.time, press: press)
                        hover.setDragging(true)
                        if !press.group, !press.extending { model.selection = .click(item.id) }
                    }
                    guard var current = drag else { return }
                    if abs(value.translation.width) > 2 { current.moved = true }
                    if current.moved {
                        current.time = min(max(current.origin + Double(value.translation.width / geometry.pointsPerSecond), 0), geometry.duration)
                        // With others selected, they all move now.
                        if current.press.group { model.moveGroup(by: current.time - current.origin) }
                    }
                    drag = current
                }
                .onEnded { value in
                    defer {
                        drag = nil
                        hover.setDragging(false)
                    }
                    guard let current = drag else {
                        model.seek(to: geometry.time(value.location.x), fast: false)
                        return
                    }
                    if current.moved {
                        if !current.press.group { model.moveClick(current.id, toTimeline: current.time) }
                        current.press.end(model: model)
                    } else if current.press.extending {
                        model.toggleSelection(.click(current.id))
                    } else {
                        model.seek(to: current.origin)
                    }
                }
        )
        .help("Clicks — drag one to retime it, ⌫ removes the selected one")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clicks")
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.id) { item in
                    Color.clear
                        .frame(width: 14, height: M.clickLaneHeight)
                        .offset(x: geometry.x(item.time) - 7)
                        .accessibilityElement()
                        .accessibilityLabel(model.accessibilityDescription(of: .click(item.id)))
                        .accessibilityAddTraits(selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction {
                            model.selection = .click(item.id)
                            model.seek(to: item.time)
                        }
                        .accessibilityAction(named: "Delete") { model.deleteClick(item.id) }
                }
            }
        }
    }
}

// MARK: - Camera layouts lane

/// Where the camera goes full screen, side by side, or hides: drag to
/// move, drag an edge to retime, click to choose the layout.
struct VideoCameraLayoutLane: View, Equatable {
    struct Item: Equatable {
        let id: UUID
        let start: Double
        let end: Double
        let layout: VideoCameraLayoutRegion.Layout
    }

    let items: [Item]
    let selectedIDs: Set<UUID>
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedIDs == b.selectedIDs && a.geometry == b.geometry
    }

    private typealias Mode = VideoLaneDrag.Mode

    private struct Drag {
        let id: UUID
        let mode: Mode
        let originStart: Double
        let originEnd: Double
        let press: VideoLaneDrag.Press
        var moved = false
    }

    @State private var drag: Drag?
    private typealias M = VideoTimelineMetrics
    private static let edge: CGFloat = 7

    private func rect(_ item: Item) -> CGRect {
        CGRect(x: geometry.x(item.start) + 1, y: 0, width: max(CGFloat(item.end - item.start) * geometry.pointsPerSecond - 2, 10), height: M.cameraLaneHeight)
    }

    private func hit(_ point: CGPoint) -> (Item, Mode)? {
        for item in items.reversed() {
            let frame = rect(item)
            guard frame.insetBy(dx: -2, dy: 0).contains(point) else { continue }
            if frame.width > Self.edge * 3 {
                if point.x < frame.minX + Self.edge { return (item, .leading) }
                if point.x > frame.maxX - Self.edge { return (item, .trailing) }
            }
            return (item, .move)
        }
        return nil
    }

    var body: some View {
        Canvas { context, size in
            for item in items {
                let frame = rect(item)
                guard frame.maxX >= 0, frame.minX <= size.width else { continue }
                let selected = selectedIDs.contains(item.id)
                let path = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)
                context.fill(path, with: .color(VideoEditorTheme.camera.opacity(selected ? 0.9 : 0.45)))
                context.stroke(path, with: .color(.white.opacity(selected ? 0.95 : 0.14)), lineWidth: selected ? 1.5 : 1)
                if frame.width > 30 {
                    var inner = context
                    inner.clip(to: Path(frame.insetBy(dx: 5, dy: 0)))
                    inner.draw(
                        Text("\(Image(systemName: item.layout.symbol)) \(frame.width > 90 ? item.layout.title : "")")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white),
                        at: CGPoint(x: frame.minX + 7, y: frame.midY),
                        anchor: .leading
                    )
                }
            }
        }
        .frame(width: geometry.width, height: M.cameraLaneHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase, let (_, mode) = hit(point) else {
                NSCursor.arrow.set()
                return
            }
            (mode == .move ? NSCursor.openHand : NSCursor.resizeLeftRight).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil {
                        guard let (item, mode) = hit(value.startLocation) else {
                            model.seek(to: geometry.time(value.location.x), fast: true)
                            return
                        }
                        let press = VideoLaneDrag.Press(model: model, item: .cameraLayout(item.id), moving: mode == .move, pointsPerSecond: geometry.pointsPerSecond)
                        drag = Drag(id: item.id, mode: mode, originStart: item.start, originEnd: item.end, press: press)
                        hover.setDragging(true)
                        if !press.group, !press.extending { model.selection = .cameraLayout(item.id) }
                    }
                    guard var current = drag else { return }
                    if abs(value.translation.width) > 2 { current.moved = true }
                    drag = current
                    guard current.moved else { return }
                    let (start, end) = VideoLaneDrag.window(
                        mode: current.mode, start: current.originStart, end: current.originEnd, snapper: current.press.snapper,
                        delta: Double(value.translation.width / geometry.pointsPerSecond), duration: geometry.duration,
                        minimum: VideoCameraLayoutRegion.minimumDuration, hover: hover
                    )
                    if current.press.group {
                        model.moveGroup(by: start - current.originStart)
                    } else {
                        model.setCameraLayoutWindow(current.id, timelineStart: start, timelineEnd: end, moving: current.mode == .move)
                    }
                }
                .onEnded { value in
                    defer {
                        drag = nil
                        hover.setDragging(false)
                    }
                    guard let current = drag else {
                        model.seek(to: geometry.time(value.location.x), fast: false)
                        return
                    }
                    current.press.end(model: model)
                    if !current.moved, current.press.extending {
                        model.toggleSelection(.cameraLayout(current.id))
                    } else if !current.moved {
                        model.selectCameraLayout(current.id)
                        model.inspectorTab = .camera
                    }
                }
        )
        .help("Camera layouts — drag to move, drag an edge to retime, click to change")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera layouts")
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.id) { item in
                    let frame = rect(item)
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                        .accessibilityElement()
                        .accessibilityLabel(model.accessibilityDescription(of: .cameraLayout(item.id)))
                        .accessibilityAddTraits(selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction {
                            model.selectCameraLayout(item.id)
                            model.inspectorTab = .camera
                        }
                        .accessibilityAction(named: "Delete") { model.deleteCameraLayout(item.id) }
                }
            }
        }
    }
}
