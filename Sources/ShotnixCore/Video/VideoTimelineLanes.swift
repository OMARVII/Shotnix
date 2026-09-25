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

    func update(time: Double?, overZoomTrack: Bool) {
        if self.time != time { self.time = time }
        if self.overZoomTrack != overZoomTrack { self.overZoomTrack = overZoomTrack }
    }

    func setDragging(_ dragging: Bool) {
        if self.dragging != dragging { self.dragging = dragging }
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
    let selectedID: UUID?
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedID == b.selectedID && a.geometry == b.geometry
    }

    private enum Mode { case move, leading, trailing }

    private struct Drag {
        let id: UUID
        let mode: Mode
        let originStart: Double
        let originEnd: Double
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
                let selected = item.id == selectedID
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
                    drag = Drag(id: item.id, mode: mode, originStart: item.start, originEnd: item.end)
                    hover.setDragging(true)
                    model.selection = .caption(item.id)
                }
                guard var current = drag else { return }
                if abs(value.translation.width) > 2 { current.moved = true }
                drag = current
                guard current.moved else { return }
                let delta = Double(value.translation.width / geometry.pointsPerSecond)
                var start = current.originStart
                var end = current.originEnd
                switch current.mode {
                case .move:
                    let length = end - start
                    start = min(max(current.originStart + delta, 0), geometry.duration - length)
                    end = start + length
                case .leading:
                    start = min(max(current.originStart + delta, 0), current.originEnd - 0.2)
                case .trailing:
                    end = min(max(current.originEnd + delta, current.originStart + 0.2), geometry.duration)
                }
                model.setCaptionWindow(current.id, timelineStart: start, timelineEnd: end, moveWords: current.mode == .move)
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
                model.endGesture()
                if !current.moved { model.selectCaption(current.id) }
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
    let selectedID: UUID?
    let hidden: Bool
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedID == b.selectedID && a.hidden == b.hidden && a.geometry == b.geometry
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
                let selected = item.id == selectedID
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
                        model.selectKeystroke(item.id)
                    } else {
                        model.seek(to: geometry.time(value.location.x), fast: false)
                    }
                }
        )
        .help("Keyboard shortcuts — click one to select it, ⌫ hides it")
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
    let selectedID: UUID?
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel
    let hover: VideoTimelineHover

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.items == b.items && a.selectedID == b.selectedID && a.geometry == b.geometry
    }

    private struct Drag {
        let id: UUID
        let origin: Double
        var time: Double
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
                let selected = item.id == selectedID || drag?.id == item.id
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
                        drag = Drag(id: item.id, origin: item.time, time: item.time)
                        hover.setDragging(true)
                        model.selection = .click(item.id)
                    }
                    guard var current = drag else { return }
                    if abs(value.translation.width) > 2 { current.moved = true }
                    if current.moved {
                        current.time = min(max(current.origin + Double(value.translation.width / geometry.pointsPerSecond), 0), geometry.duration)
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
                        model.moveClick(current.id, toTimeline: current.time)
                        model.endGesture()
                    } else {
                        model.seek(to: current.origin)
                    }
                }
        )
        .help("Clicks — drag one to retime it, ⌫ removes the selected one")
    }
}
