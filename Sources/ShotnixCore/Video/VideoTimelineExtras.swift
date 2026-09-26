import AppKit
import SwiftUI

// MARK: - VoiceOver

extension VideoEditorModel {
    /// What VoiceOver says for an intro or outro card on the timeline.
    func cardAccessibilityLabel(isIntro: Bool) -> String {
        let card = isIntro ? project.cards.intro : project.cards.outro
        let span = isIntro ? 0...(segments.first?.timelineStart ?? 0) : (segments.last?.timelineEnd ?? 0)...timelineDuration
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(isIntro ? "Intro" : "Outro") card\(title.isEmpty ? "" : " “\(title)”"), \(Self.timecode(span.lowerBound)) to \(Self.timecode(span.upperBound))"
    }

    /// Opens a card's settings (Style), with the playhead on it.
    func showCardSettings(isIntro: Bool) {
        let span = isIntro ? 0...(segments.first?.timelineStart ?? 0) : (segments.last?.timelineEnd ?? 0)...timelineDuration
        selection = .none
        inspectorTab = .background
        seek(to: span.lowerBound + min(1, (span.upperBound - span.lowerBound) / 2))
    }

    /// What VoiceOver says for the music lane.
    var musicAccessibilityLabel: String {
        guard let music = project.music else { return "No music" }
        var parts = ["Music “\(music.name)”", "\(Int((music.volume * 100).rounded()))% volume"]
        if music.ducking { parts.append("dips under your voice") }
        if music.loops { parts.append("loops") }
        return parts.joined(separator: ", ") + ", \(Self.timecode(0)) to \(Self.timecode(timelineDuration))"
    }

    /// Opens the music's settings (Audio).
    func showMusicSettings() {
        selection = .none
        inspectorTab = .audio
    }
}

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
        .onTapGesture { model.showCardSettings(isIntro: label == "Intro") }
        .help("\(label) card — click to edit it in Style")
        // VoiceOver: what it is, and what can be done with it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.cardAccessibilityLabel(isIntro: label == "Intro"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens its title and length in Style")
        .accessibilityAction { model.showCardSettings(isIntro: label == "Intro") }
        .accessibilityAction(named: "Remove \(label) Card") {
            if label == "Intro" { model.setIntroEnabled(false) } else { model.setOutroEnabled(false) }
        }
        .offset(x: geometry.x(start) + 1, y: clipTop)
    }
}
