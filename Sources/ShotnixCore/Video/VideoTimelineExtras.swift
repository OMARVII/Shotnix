import AppKit
import SwiftUI

extension VideoTimelineMetrics {
    /// Lanes under the clips (music) — 0 when there are none.
    static func bottomLanesHeight(_ project: VideoDemoProject) -> CGFloat {
        project.music == nil ? 0 : gap + musicLaneHeight
    }
}

/// What the timeline shows beyond the recording's own lanes: the intro
/// and outro cards on the clip track, a marker on every cut (click to pick
/// its transition), where one recording hands over to the next, and the
/// music lane under the clips.
struct VideoTimelineExtrasLayer: View {
    let model: VideoEditorModel
    let geometry: VideoTimelineGeometry
    let clipTop: CGFloat

    private typealias M = VideoTimelineMetrics

    var body: some View {
        let project = model.project
        ZStack(alignment: .topLeading) {
            if project.cards.intro.enabled, let first = model.segments.first {
                cardBlock(project.cards.intro, label: "Intro", start: 0, end: first.timelineStart)
            }
            if project.cards.outro.enabled, let last = model.segments.last {
                cardBlock(project.cards.outro, label: "Outro", start: last.timelineEnd, end: model.timelineDuration)
            }
            let boundaries = project.sourceBoundaries(segments: model.segments)
            if !boundaries.isEmpty {
                VideoSourceBoundaryMarkers(boundaries: boundaries, geometry: geometry, clipTop: clipTop)
            }
            VideoTransitionMarkers(model: model, geometry: geometry, clipTop: clipTop)
            if let music = project.music {
                VideoMusicLane(
                    music: music,
                    waveform: model.media.musicWaveform?.path == music.path ? model.media.musicWaveform?.waveform : nil,
                    duration: model.timelineDuration,
                    voice: music.ducking ? model.voiceTimelineRanges : [],
                    geometry: geometry,
                    model: model
                )
                .equatable()
                .offset(y: clipTop + M.clipTrackHeight + M.gap)
            }
        }
    }

    private func cardBlock(_ card: VideoTitleCard, label: String, start: Double, end: Double) -> some View {
        let width = max(CGFloat(end - start) * geometry.pointsPerSecond - 2, 8)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [VideoEditorTheme.card.opacity(1), Color.white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if width > 46 {
                VStack(alignment: .leading, spacing: 2) {
                    Label(label, systemImage: "textformat.size")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    if width > 90, !card.title.isEmpty {
                        Text(card.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 8)
            }
        }
        .frame(width: width, height: M.clipTrackHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = .none
            model.inspectorTab = .background
            model.seek(to: start + min(1, (end - start) / 2))
        }
        .help("\(label) card — click to edit it in Style")
        .offset(x: geometry.x(start) + 1, y: clipTop)
    }
}
