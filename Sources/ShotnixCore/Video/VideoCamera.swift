import CoreGraphics
import Foundation

/// Where the virtual camera looks at one instant. `centerX/centerY` is the
/// canvas point (normalized, y down) shown at the middle of the output.
struct VideoCameraState: Equatable {
    var scale: Double
    var centerX: Double
    var centerY: Double

    static let rest = VideoCameraState(scale: 1, centerX: 0.5, centerY: 0.5)

    /// The visible part of the canvas (top-left origin, canvas units).
    func window(in canvas: CGSize) -> CGRect {
        let s = max(scale, 1)
        let width = canvas.width / CGFloat(s)
        let height = canvas.height / CGFloat(s)
        return CGRect(
            x: CGFloat(centerX) * canvas.width - width / 2,
            y: CGFloat(centerY) * canvas.height - height / 2,
            width: width,
            height: height
        )
    }

    /// Keeps the visible window inside the canvas — the background fills the
    /// slack near the video's edges, and nothing beyond the canvas shows.
    static func clampedCenter(_ value: Double, scale: Double) -> Double {
        let half = 0.5 / max(scale, 1)
        return min(max(value, half), 1 - half)
    }
}

/// Easing used for every camera move.
enum VideoCameraEasing {
    private static let springEnd = 1 - 8 * exp(-7.0)

    /// A critically-damped spring rise rescaled to land exactly on 1: zero
    /// starting velocity, a decisive middle, a long soft settle, and no
    /// overshoot.
    static func spring(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        let x = 7 * t
        return min((1 - (1 + x) * exp(-x)) / springEnd, 1)
    }

    /// Symmetric ease for pans between two held shots.
    static func glide(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func logLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        exp(log(max(a, 0.0001)) + (log(max(b, 0.0001)) - log(max(a, 0.0001))) * t)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}

/// The camera path for a whole edited timeline, sampled at 60Hz in
/// TIMELINE time (what the viewer sees): moves keep their on-screen pace
/// through speed changes. Built once per edit; preview and export read the
/// identical samples, so what you scrub is what exports.
final class VideoCameraTrack: @unchecked Sendable {
    static let sampleRate = 60.0
    /// Zoom regions this close (seconds) chain into one pan instead of
    /// zooming out and straight back in.
    static let chainGap = 1.25

    let duration: Double
    private let scales: [Double]
    private let xs: [Double]
    private let ys: [Double]

    init(duration: Double, scales: [Double], xs: [Double], ys: [Double]) {
        self.duration = duration
        self.scales = scales
        self.xs = xs
        self.ys = ys
    }

    static let identity = VideoCameraTrack(duration: 0, scales: [1], xs: [0.5], ys: [0.5])

    var isStatic: Bool { scales.allSatisfy { $0 <= 1.0001 } }

    func state(at time: Double) -> VideoCameraState {
        guard scales.count > 1 else {
            return VideoCameraState(scale: scales.first ?? 1, centerX: xs.first ?? 0.5, centerY: ys.first ?? 0.5)
        }
        let position = min(max(time, 0), duration) * Self.sampleRate
        let lower = min(Int(position), scales.count - 1)
        let upper = min(lower + 1, scales.count - 1)
        let fraction = position - Double(lower)
        return VideoCameraState(
            scale: VideoCameraEasing.logLerp(scales[lower], scales[upper], fraction),
            centerX: VideoCameraEasing.lerp(xs[lower], xs[upper], fraction),
            centerY: VideoCameraEasing.lerp(ys[lower], ys[upper], fraction)
        )
    }

    /// Per-second rates (log-scale for zoom) — drives camera motion blur.
    func velocity(at time: Double) -> (logScale: Double, x: Double, y: Double) {
        let dt = 1 / Self.sampleRate
        let a = state(at: time - dt / 2)
        let b = state(at: time + dt / 2)
        return (
            (log(max(b.scale, 0.0001)) - log(max(a.scale, 0.0001))) / dt,
            (b.centerX - a.centerX) / dt,
            (b.centerY - a.centerY) / dt
        )
    }

    // MARK: Building

    struct Piece {
        var start: Double
        var end: Double
        var scale: Double
        var follows: Bool
        /// Canvas-normalized aim (manual regions).
        var focus: CGPoint
        var regionID: UUID
    }

    /// Transition length for a zoom of the given depth: deeper zooms travel
    /// further, so they take proportionally longer.
    static func transitionDuration(scale: Double, speed: VideoZoomSpeed) -> Double {
        guard speed != .instant else { return speed.transitionDuration }
        let depth = (0.6 + 0.55 * log(max(scale, 1))) / (0.6 + 0.55 * log(2.0))
        return speed.transitionDuration * depth
    }

    static func pieces(
        regions: [VideoZoomRegion],
        segments: [VideoDemoTimelineSegment],
        stage: CGRect,
        crop: VideoCropRect = .full
    ) -> [Piece] {
        var pieces: [Piece] = []
        for region in regions where region.end > region.start {
            let inCrop = crop.map(CGPoint(x: region.focusX, y: region.focusY))
            let focus = CGPoint(
                x: stage.minX + stage.width * inCrop.x,
                y: stage.minY + stage.height * inCrop.y
            )
            for range in VideoDemoProject.timelineRanges(sourceStart: region.start, sourceEnd: region.end, segments: segments) {
                pieces.append(Piece(
                    start: range.lowerBound,
                    end: range.upperBound,
                    scale: region.scale,
                    follows: region.followsCursor,
                    focus: focus,
                    regionID: region.id
                ))
            }
        }
        pieces.sort { $0.start < $1.start }
        // Overlaps: the later region wins from where it starts.
        var resolved: [Piece] = []
        for piece in pieces {
            if var last = resolved.last, last.end > piece.start {
                last.end = piece.start
                resolved[resolved.count - 1] = last
                if last.end - last.start < 0.05 { resolved.removeLast() }
            }
            resolved.append(piece)
        }
        return resolved.filter { $0.end - $0.start >= 0.05 }
    }

    /// - Parameters:
    ///   - stage: the video's rect on the canvas, canvas-normalized (y down).
    ///   - cursor: smoothed pointer at a SOURCE time, video-normalized; nil
    ///     when unknown or hidden.
    static func build(
        regions: [VideoZoomRegion],
        segments: [VideoDemoTimelineSegment],
        timelineDuration: Double,
        speed: VideoZoomSpeed,
        stage: CGRect,
        crop: VideoCropRect = .full,
        cursor: ((Double) -> CGPoint?)?
    ) -> VideoCameraTrack {
        guard timelineDuration > 0 else { return .identity }
        let pieces = pieces(regions: regions, segments: segments, stage: stage, crop: crop)
        let count = Int((timelineDuration * sampleRate).rounded(.up)) + 1
        guard !pieces.isEmpty else {
            return VideoCameraTrack(
                duration: timelineDuration,
                scales: [Double](repeating: 1, count: 2),
                xs: [0.5, 0.5],
                ys: [0.5, 0.5]
            )
        }

        // Group chained pieces.
        var groups: [[Piece]] = []
        for piece in pieces {
            if let last = groups.last?.last, piece.start - last.end <= chainGap {
                groups[groups.count - 1].append(piece)
            } else {
                groups.append([piece])
            }
        }

        func canvasCursor(atTimeline time: Double) -> CGPoint? {
            guard let cursor else { return nil }
            let sourceTime = VideoDemoProject.sourceTime(forTimelineTime: time, segments: segments)
            guard let raw = cursor(sourceTime) else { return nil }
            let point = crop.map(raw)
            return CGPoint(x: stage.minX + stage.width * point.x, y: stage.minY + stage.height * point.y)
        }

        var scales = [Double](repeating: 1, count: count)
        var xs = [Double](repeating: 0.5, count: count)
        var ys = [Double](repeating: 0.5, count: count)

        let dt = 1 / sampleRate
        var groupIndex = 0

        // Follow state (reset per group).
        var leash: CGPoint?
        var springPosition: CGPoint?
        var springVelocity = CGVector.zero
        var frozenAim: CGPoint?

        for index in 0..<count {
            let t = min(Double(index) * dt, timelineDuration)
            while groupIndex < groups.count && t > (groups[groupIndex].last?.end ?? 0) {
                groupIndex += 1
                leash = nil
                springPosition = nil
                springVelocity = .zero
                frozenAim = nil
            }
            guard groupIndex < groups.count,
                  let groupStart = groups[groupIndex].first?.start,
                  t >= groupStart else {
                scales[index] = 1
                xs[index] = 0.5
                ys[index] = 0.5
                continue
            }
            let group = groups[groupIndex]
            let first = group[0]
            let last = group[group.count - 1]
            let groupEnd = last.end
            let rampIn = min(transitionDuration(scale: first.scale, speed: speed), (first.end - first.start) * 0.5)
            let rampOut = min(transitionDuration(scale: last.scale, speed: speed), (last.end - last.start) * 0.5)

            // Which piece (or chain gap) are we in?
            var held = first.scale
            var aimTarget: CGPoint
            var activePiece = first
            var chainBlend: (from: Piece, to: Piece, progress: Double)?
            for pieceIndex in group.indices {
                let piece = group[pieceIndex]
                if t < piece.start { break }
                activePiece = piece
                held = piece.scale
                if pieceIndex + 1 < group.count {
                    let next = group[pieceIndex + 1]
                    // The pan window always covers the whole gap and eats
                    // at most 45% of either neighbouring shot.
                    let gap = max(next.start - piece.end, 0)
                    let desired = min(max(gap + 0.5, 0.8), max(gap, 1.2))
                    let reach = max(min((desired - gap) / 2, (piece.end - piece.start) * 0.45, (next.end - next.start) * 0.45), 0)
                    let windowStart = piece.end - reach
                    let windowEnd = next.start + reach
                    let window = windowEnd - windowStart
                    if t >= windowStart && t <= windowEnd {
                        chainBlend = (piece, next, VideoCameraEasing.glide((t - windowStart) / max(window, 0.0001)))
                    } else if t > windowEnd {
                        continue
                    }
                }
            }

            if let blend = chainBlend {
                held = VideoCameraEasing.logLerp(blend.from.scale, blend.to.scale, blend.progress)
            }

            // Ramps in and out of the group.
            var scale = held
            var rampingOut = false
            if t < groupStart + rampIn {
                let progress = VideoCameraEasing.spring((t - groupStart) / max(rampIn, 0.0001))
                scale = VideoCameraEasing.logLerp(1, held, progress)
            } else if t > groupEnd - rampOut {
                let progress = VideoCameraEasing.spring((t - (groupEnd - rampOut)) / max(rampOut, 0.0001))
                scale = VideoCameraEasing.logLerp(held, 1, progress)
                rampingOut = true
            }

            // Aim.
            func followAim(for piece: Piece) -> CGPoint {
                let s = max(scale, 1.0001)
                if leash == nil {
                    // Look ahead to where the pointer is when the zoom lands.
                    let lookAhead = min(max(piece.start, groupStart) + rampIn, piece.end)
                    leash = canvasCursor(atTimeline: lookAhead) ?? canvasCursor(atTimeline: t) ?? piece.focus
                }
                if var current = leash, let pointer = canvasCursor(atTimeline: t) {
                    // Dead zone: small moves near the middle don't move the
                    // camera; leaving it drags the aim along.
                    let dead = 0.26 / s
                    if pointer.x > current.x + dead { current.x = pointer.x - dead }
                    if pointer.x < current.x - dead { current.x = pointer.x + dead }
                    if pointer.y > current.y + dead { current.y = pointer.y - dead }
                    if pointer.y < current.y - dead { current.y = pointer.y + dead }
                    leash = current
                }
                return leash ?? piece.focus
            }

            if let blend = chainBlend {
                let from = blend.from.follows ? (springPosition ?? followAim(for: blend.from)) : blend.from.focus
                let to: CGPoint
                if blend.to.follows {
                    to = canvasCursor(atTimeline: blend.to.start + 0.2) ?? blend.to.focus
                } else {
                    to = blend.to.focus
                }
                aimTarget = CGPoint(
                    x: VideoCameraEasing.lerp(from.x, to.x, blend.progress),
                    y: VideoCameraEasing.lerp(from.y, to.y, blend.progress)
                )
                springPosition = aimTarget
                springVelocity = .zero
                if blend.to.follows, blend.progress > 0.999 { leash = to }
            } else if activePiece.follows {
                let target = followAim(for: activePiece)
                if var position = springPosition {
                    // Critically damped spring toward the leash.
                    let omega = speed.followStiffness
                    let substeps = 2
                    let h = dt / Double(substeps)
                    for _ in 0..<substeps {
                        let ax = omega * omega * (target.x - position.x) - 2 * omega * springVelocity.dx
                        let ay = omega * omega * (target.y - position.y) - 2 * omega * springVelocity.dy
                        springVelocity.dx += ax * h
                        springVelocity.dy += ay * h
                        position.x += springVelocity.dx * h
                        position.y += springVelocity.dy * h
                    }
                    springPosition = position
                } else {
                    springPosition = target
                }
                aimTarget = springPosition ?? target
            } else {
                aimTarget = activePiece.focus
                springPosition = aimTarget
                springVelocity = .zero
            }

            // Zooming out never chases the pointer.
            if rampingOut {
                if frozenAim == nil { frozenAim = aimTarget }
                aimTarget = frozenAim ?? aimTarget
            }

            scales[index] = scale
            xs[index] = VideoCameraState.clampedCenter(Double(aimTarget.x), scale: scale)
            ys[index] = VideoCameraState.clampedCenter(Double(aimTarget.y), scale: scale)
        }
        return VideoCameraTrack(duration: timelineDuration, scales: scales, xs: xs, ys: ys)
    }
}

// MARK: - Auto Zoom

/// Plans zoom regions from what happened in the recording: clicks (and
/// drags, as one moment) become shots; bursts close in time share one
/// shot, and the camera follows the pointer inside it.
enum VideoAutoZoomPlanner {
    struct Tuning {
        /// Clicks within this many seconds of each other share a shot.
        var clusterGap = 1.2
        /// Shots closer than this join up (as adjacent regions).
        var mergeGap = 0.35
        /// Zoom lands this long before the first click.
        var settleBeforeClick = 0.25
        /// Hold this long after the last click.
        var holdAfterClick = 1.3
        var minimumShot = 2.0
        /// Clicks in the first moments are usually "focus the window".
        var ignoreLeadIn = 0.35
    }

    static func regions(
        clicks: [VideoDemoClickEvent],
        cursorSamples: [VideoDemoCursorSample],
        segments: [VideoDemoTimelineSegment],
        scale: Double,
        speed: VideoZoomSpeed,
        tuning: Tuning = Tuning()
    ) -> [VideoZoomRegion] {
        guard let lastSegment = segments.last else { return [] }
        let timelineDuration = lastSegment.timelineEnd
        guard timelineDuration > 0.5 else { return [] }

        // Moments on the edited timeline.
        struct Moment {
            var start: Double
            var end: Double
            var x: Double
            var y: Double
        }
        var moments: [Moment] = []
        for click in clicks.sorted(by: { $0.time < $1.time }) {
            guard let start = VideoDemoProject.timelineTimeIfIncluded(sourceTime: click.time, segments: segments),
                  start >= tuning.ignoreLeadIn else { continue }
            let endSource = click.time + click.pressDuration
            let end = VideoDemoProject.timelineTimeIfIncluded(sourceTime: endSource, segments: segments) ?? start
            moments.append(Moment(start: start, end: max(end, start), x: click.x, y: click.y))
        }
        guard !moments.isEmpty else { return [] }

        // Cluster.
        var clusters: [[Moment]] = []
        for moment in moments {
            if let last = clusters.last?.last, moment.start - last.end <= tuning.clusterGap {
                clusters[clusters.count - 1].append(moment)
            } else {
                clusters.append([moment])
            }
        }

        let lead = VideoCameraTrack.transitionDuration(scale: scale, speed: speed) + tuning.settleBeforeClick
        var shots: [(start: Double, end: Double, x: Double, y: Double)] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }
            var start = max(first.start - lead, 0)
            var end = min(last.end + tuning.holdAfterClick + VideoCameraTrack.transitionDuration(scale: scale, speed: speed) * 0.5, timelineDuration)
            if end - start < tuning.minimumShot {
                let missing = tuning.minimumShot - (end - start)
                end = min(end + missing, timelineDuration)
                start = max(end - tuning.minimumShot, 0)
            }
            let count = Double(cluster.count)
            shots.append((start, end, cluster.map(\.x).reduce(0, +) / count, cluster.map(\.y).reduce(0, +) / count))
        }

        // Overlapping shots become ADJACENT regions split halfway between
        // their clicks: each burst keeps its own block on the timeline, and
        // the camera chains them into one continuous pan.
        var merged: [(start: Double, end: Double, x: Double, y: Double)] = []
        for (index, shot) in shots.enumerated() {
            guard var last = merged.last else {
                merged.append(shot)
                continue
            }
            if shot.start < last.end + tuning.mergeGap {
                let previousLastClick = clusters[index - 1].last?.end ?? last.end
                let nextFirstClick = clusters[index].first?.start ?? shot.start
                let boundary = min(max((previousLastClick + nextFirstClick) / 2, last.start + VideoZoomRegion.minimumDuration), shot.end - VideoZoomRegion.minimumDuration)
                last.end = boundary
                merged[merged.count - 1] = last
                var next = shot
                next.start = boundary
                merged.append(next)
            } else {
                merged.append(shot)
            }
        }

        return merged.compactMap { shot in
            let sourceStart = VideoDemoProject.sourceTime(forTimelineTime: shot.start, segments: segments)
            let sourceEnd = VideoDemoProject.sourceTime(forTimelineTime: shot.end, segments: segments)
            guard sourceEnd - sourceStart >= VideoZoomRegion.minimumDuration else { return nil }
            return VideoZoomRegion(
                start: sourceStart,
                end: sourceEnd,
                scale: scale,
                followsCursor: !cursorSamples.isEmpty,
                focusX: min(max(shot.x, 0), 1),
                focusY: min(max(shot.y, 0), 1),
                isAuto: true
            )
        }
    }
}
