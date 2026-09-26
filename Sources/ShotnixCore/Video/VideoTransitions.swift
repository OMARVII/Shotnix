import AppKit
import CoreImage
import SwiftUI

// MARK: - Model

enum VideoTransitionKind: String, Codable, CaseIterable, Identifiable {
    /// A hard cut.
    case none
    /// The two clips blend into each other.
    case dissolve
    /// Out to black, then in from black.
    case fadeThroughBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Cut"
        case .dissolve: return "Dissolve"
        case .fadeThroughBlack: return "Dip to black"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "scissors"
        case .dissolve: return "square.on.square.intersection.dashed"
        case .fadeThroughBlack: return "circle.lefthalf.filled"
        }
    }
}

/// A transition chosen for one cut: the one leading INTO `clipID`.
struct VideoClipTransition: Codable, Equatable {
    var clipID: UUID
    var kind: VideoTransitionKind
    var duration: Double
}

/// How the video opens, closes, and moves between clips.
struct VideoTransitionSettings: Codable, Equatable {
    static let durationRange: ClosedRange<Double> = 0.2...2
    static let fadeRange: ClosedRange<Double> = 0...3

    /// Seconds the video fades in from black at the very start.
    var fadeIn = 0.0
    /// Seconds it fades out to black at the very end.
    var fadeOut = 0.0
    /// Every cut between clips, unless a cut has its own.
    var betweenClips: VideoTransitionKind = .none
    var duration = 0.5
    /// Per-cut choices (keyed by the clip after the cut).
    var overrides: [VideoClipTransition] = []

    init() {}

    /// The transition into `clipID`.
    func transition(into clipID: UUID) -> (kind: VideoTransitionKind, duration: Double) {
        if let own = overrides.first(where: { $0.clipID == clipID }) {
            return (own.kind, own.duration)
        }
        return (betweenClips, duration)
    }

    var isEmpty: Bool {
        fadeIn <= 0.001 && fadeOut <= 0.001 && betweenClips == .none && overrides.allSatisfy { $0.kind == .none }
    }

    private enum CodingKeys: String, CodingKey { case fadeIn, fadeOut, betweenClips, duration, overrides }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        betweenClips = (try? c.decode(VideoTransitionKind.self, forKey: .betweenClips)) ?? .none
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.5
        overrides = (try? c.decode([VideoClipTransition].self, forKey: .overrides)) ?? []
    }
}

// MARK: - Timing

/// One cut's transition as it plays on the edited timeline.
struct VideoTransitionSpan: Equatable {
    /// The cut, timeline seconds.
    let time: Double
    let kind: VideoTransitionKind
    let duration: Double
    /// The last moment of the clip before the cut and the first of the
    /// one after (source seconds) — the frames a dissolve holds.
    let outgoingSource: Double
    let incomingSource: Double
    /// Index of the clip after the cut.
    let index: Int

    var start: Double { time - duration / 2 }
    var end: Double { time + duration / 2 }

    /// 0 → 1 across the transition.
    func progress(at time: Double) -> Double {
        min(max((time - start) / max(duration, 0.0001), 0), 1)
    }

    /// Timeline moments the held frames are rendered at: just before the
    /// cut (the outgoing clip's last look) and just after it.
    var outgoingTime: Double { time - 0.0005 }
    var incomingTime: Double { time + 0.0005 }
}

enum VideoTransitionTiming {
    /// Transitions at every cut, sized so each fits inside both clips
    /// (half of it plays on either side of the cut).
    static func spans(settings: VideoTransitionSettings, segments: [VideoDemoTimelineSegment]) -> [VideoTransitionSpan] {
        guard segments.count > 1 else { return [] }
        var spans: [VideoTransitionSpan] = []
        for index in 1..<segments.count {
            let before = segments[index - 1]
            let after = segments[index]
            let chosen = settings.transition(into: after.id)
            guard chosen.kind != .none else { continue }
            let room = min(before.duration, after.duration)
            let duration = min(max(chosen.duration, VideoTransitionSettings.durationRange.lowerBound), VideoTransitionSettings.durationRange.upperBound, room)
            guard duration >= 0.05 else { continue }
            // One frame inside each clip, so the held frame is the clip's own.
            let outgoing = max(before.clip.sourceEnd - 1.0 / 60, before.clip.sourceStart)
            spans.append(VideoTransitionSpan(
                time: after.timelineStart,
                kind: chosen.kind,
                duration: duration,
                outgoingSource: outgoing,
                incomingSource: after.clip.sourceStart,
                index: index
            ))
        }
        return spans
    }

    /// How dark the frame is (0 clear → 1 black) at `time` from the fades
    /// at the video's start and end.
    static func edgeFade(time: Double, duration: Double, fadeIn: Double, fadeOut: Double) -> Double {
        var black = 0.0
        if fadeIn > 0.001 {
            black = max(black, 1 - min(max(time / fadeIn, 0), 1))
        }
        if fadeOut > 0.001, duration > 0 {
            black = max(black, 1 - min(max((duration - time) / fadeOut, 0), 1))
        }
        return VideoCameraEasing.glide(black)
    }

    /// Darkness of a dip-to-black at `time`: 1 exactly on the cut.
    static func dip(_ span: VideoTransitionSpan, at time: Double) -> Double {
        let half = max(span.duration / 2, 0.0001)
        return VideoCameraEasing.glide(1 - min(abs(time - span.time) / half, 1))
    }
}

/// A frame the renderer needs from the caller (the held side of a dissolve).
struct VideoHeldFrameRequest: Equatable {
    /// Source-axis seconds of the frame.
    let sourceTime: Double
}

extension VideoRenderPlan {
    func transition(at time: Double) -> VideoTransitionSpan? {
        transitions.first { time >= $0.start && time <= $0.end }
    }

    /// The source frame a dissolve at `time` holds on its other side (nil
    /// when nothing is needed). Preview and export fetch it the same way.
    func heldFrameRequest(at time: Double) -> VideoHeldFrameRequest? {
        guard let span = transition(at: time), span.kind == .dissolve else { return nil }
        return VideoHeldFrameRequest(sourceTime: time < span.time ? span.incomingSource : span.outgoingSource)
    }
}

// MARK: - Editor

extension VideoEditorModel {
    func setTransition(into clipID: UUID, kind: VideoTransitionKind?, duration: Double? = nil) {
        mutate(coalesce: duration == nil ? nil : "transition-\(clipID)") { project in
            var overrides = project.transitions.overrides
            let current = project.transitions.transition(into: clipID)
            overrides.removeAll { $0.clipID == clipID }
            let newKind = kind ?? current.kind
            let newDuration = duration ?? current.duration
            // Matching the default for every cut needs no entry.
            if newKind != project.transitions.betweenClips || abs(newDuration - project.transitions.duration) > 0.001 {
                overrides.append(VideoClipTransition(clipID: clipID, kind: newKind, duration: newDuration))
            }
            // Drop entries for clips that are gone.
            let ids = Set(project.timelineClips.map(\.id))
            project.transitions.overrides = overrides.filter { ids.contains($0.clipID) }
        }
    }

    /// Timeline moments of every cut, with what plays there.
    var transitionCuts: [(time: Double, clipID: UUID, kind: VideoTransitionKind)] {
        guard segments.count > 1 else { return [] }
        return (1..<segments.count).map { index in
            let segment = segments[index]
            return (segment.timelineStart, segment.id, project.transitions.transition(into: segment.id).kind)
        }
    }
}

/// Fades and transitions, in the Style tab.
struct VideoTransitionsSection: View {
    @ObservedObject var model: VideoEditorModel

    private var settings: VideoTransitionSettings { model.project.transitions }

    var body: some View {
        VideoInspectorSection("Transitions") {
            VideoSliderRow(
                title: "Fade in from black",
                value: Binding(get: { settings.fadeIn }, set: { value in model.setStyle(coalesce: "fade-in-video") { $0.transitions.fadeIn = (value * 10).rounded() / 10 } }),
                range: VideoTransitionSettings.fadeRange,
                defaultValue: 0,
                format: { $0 < 0.05 ? "Off" : String(format: "%.1fs", $0) },
                onEditingEnded: { model.endGesture() }
            )
            VideoSliderRow(
                title: "Fade out to black",
                value: Binding(get: { settings.fadeOut }, set: { value in model.setStyle(coalesce: "fade-out-video") { $0.transitions.fadeOut = (value * 10).rounded() / 10 } }),
                range: VideoTransitionSettings.fadeRange,
                defaultValue: 0,
                format: { $0 < 0.05 ? "Off" : String(format: "%.1fs", $0) },
                onEditingEnded: { model.endGesture() }
            )
            HStack(spacing: 10) {
                Text("Between clips")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                    .fixedSize()
                VideoSegmented(options: VideoTransitionKind.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { settings.betweenClips },
                    set: { value in model.setStyle { $0.transitions.betweenClips = value } }
                ))
            }
            if settings.betweenClips != .none {
                VideoSliderRow(
                    title: "Length",
                    value: Binding(get: { settings.duration }, set: { value in model.setStyle(coalesce: "transition-length") { $0.transitions.duration = (value * 10).rounded() / 10 } }),
                    range: VideoTransitionSettings.durationRange,
                    defaultValue: 0.5,
                    format: { String(format: "%.1fs", $0) },
                    onEditingEnded: { model.endGesture() }
                )
            }
            Text(model.segments.count > 1
                 ? "Applies at every cut. Click a cut's marker on the timeline, or select a clip, to choose one for that cut only."
                 : "Split the video (S) to make cuts; each can dissolve or dip to black.")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The transition into the selected clip, in the clip inspector.
struct VideoClipTransitionSection: View {
    @ObservedObject var model: VideoEditorModel
    let segment: VideoDemoTimelineSegment

    var body: some View {
        if let index = model.segments.firstIndex(where: { $0.id == segment.id }), index > 0 {
            let current = model.project.transitions.transition(into: segment.id)
            VideoInspectorSection("Transition in") {
                VideoSegmented(options: VideoTransitionKind.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { current.kind },
                    set: { value in model.setTransition(into: segment.id, kind: value) }
                ))
                if current.kind != .none {
                    VideoSliderRow(
                        title: "Length",
                        value: Binding(get: { current.duration }, set: { value in model.setTransition(into: segment.id, kind: nil, duration: (value * 10).rounded() / 10) }),
                        range: VideoTransitionSettings.durationRange,
                        defaultValue: model.project.transitions.duration,
                        format: { String(format: "%.1fs", $0) },
                        onEditingEnded: { model.endGesture() }
                    )
                }
            }
        }
    }
}

/// Small markers on the cuts: click one to pick how that cut plays.
struct VideoTransitionMarkers: View {
    let model: VideoEditorModel
    let geometry: VideoTimelineGeometry
    let clipTop: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.transitionCuts, id: \.clipID) { cut in
                Menu {
                    ForEach(VideoTransitionKind.allCases) { kind in
                        Button {
                            model.setTransition(into: cut.clipID, kind: kind)
                        } label: {
                            if kind == cut.kind {
                                Label(kind.title, systemImage: "checkmark")
                            } else {
                                Text(kind.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: cut.kind == .none ? "plus" : cut.kind.symbol)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(cut.kind == .none ? Color.white.opacity(0.75) : Color.black.opacity(0.85))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(cut.kind == .none ? Color.black.opacity(0.55) : Color.white.opacity(0.92)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(cut.kind == .none ? "Add a transition at this cut" : "\(cut.kind.title) — click to change")
                .offset(x: geometry.x(cut.time) - 8, y: clipTop + VideoTimelineMetrics.clipTrackHeight - 22)
            }
        }
    }
}
