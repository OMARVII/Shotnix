import AppKit
import SwiftUI

// MARK: - Dips under the voice

/// A place where the computer sound dips while you talk.
struct VideoSoundDip: Equatable {
    /// Timeline seconds.
    var range: ClosedRange<Double>
    /// The computer sound's level here, as a fraction of its own (1: not
    /// lowered).
    var level: Double
    /// The talking it sits under, on the source axis: what a change by
    /// hand is kept against, so it survives cuts.
    var talk: ClosedRange<Double>
    /// Its level was set by hand.
    var custom: Bool

    var lowered: Bool { level < 0.999 }
}

/// The computer sound dips under your voice: found from where you talk,
/// eased down just before and back up after, with pauses inside a
/// sentence bridged so it doesn't pump.
enum VideoComputerSoundDucking {
    /// Pauses shorter than this keep the dip.
    static let bridge = 1.5

    /// Where you talk, on the source axis, stretches close together joined.
    static func talk(project: VideoDemoProject, primaryKinds: [VideoAudioKind], speech: [String: [ClosedRange<Double>]]) -> [ClosedRange<Double>] {
        VideoMusicMix.mergedVoice(VideoMusicDucking.voiceOnAxis(project: project, primaryKinds: primaryKinds, speech: speech), within: bridge)
    }

    /// The dips on the timeline: each stretch of talking where your voice
    /// is still heard (cut, muted, and silenced parts drop out).
    static func dips(project: VideoDemoProject, primaryKinds: [VideoAudioKind], speech: [String: [ClosedRange<Double>]], segments: [VideoDemoTimelineSegment]) -> [VideoSoundDip] {
        guard project.audio.duckSystem else { return [] }
        let heard = segments.filter { !$0.clip.muted && $0.clip.volume(for: .microphone) > 0.01 }
        var dips: [VideoSoundDip] = []
        for talk in talk(project: project, primaryKinds: primaryKinds, speech: speech) {
            let spot = project.audio.systemDuckSpots.last { $0.matches(talk) }
            let level = min(max(spot?.level ?? project.audio.systemDuckLevel, 0), 1)
            for range in VideoDemoProject.timelineRanges(sourceStart: talk.lowerBound, sourceEnd: talk.upperBound, segments: heard) {
                dips.append(VideoSoundDip(range: range, level: level, talk: talk, custom: spot != nil))
            }
        }
        return dips
    }

    /// The computer sound's share at a timeline moment: down to a dip's
    /// level while you talk, easing in just before and back out after.
    static func duck(at time: Double, dips: [VideoSoundDip]) -> Double {
        let attack = VideoMusicMix.duckAttack, release = VideoMusicMix.duckRelease
        var duck = 1.0
        for dip in dips where dip.lowered {
            guard time >= dip.range.lowerBound - attack, time <= dip.range.upperBound + release else { continue }
            let into: Double
            if time < dip.range.lowerBound {
                into = 1 - (dip.range.lowerBound - time) / attack
            } else if time > dip.range.upperBound {
                into = 1 - (time - dip.range.upperBound) / release
            } else {
                into = 1
            }
            duck = min(duck, 1 - (1 - dip.level) * min(max(into, 0), 1))
        }
        return duck
    }

    /// Where the dips bend: their level line is straight between these.
    static func corners(of dips: [VideoSoundDip]) -> [Double] {
        dips.filter(\.lowered).flatMap { dip in
            [dip.range.lowerBound - VideoMusicMix.duckAttack, dip.range.lowerBound, dip.range.upperBound, dip.range.upperBound + VideoMusicMix.duckRelease]
        }
    }
}

/// A track's loudness, `VideoVoiceActivity.rate` values a second from
/// its own start.
struct VideoLoudness {
    let values: [Float]
    /// The track's own start, seconds.
    let start: Double
    /// What counts as full for drawing: near the loudest, so a stray peak
    /// doesn't flatten the rest.
    let top: Float

    static func load(url: URL, trackIndex: Int) async -> VideoLoudness? {
        guard let levels = await VideoVoiceActivity.loudness(url: url, trackIndex: trackIndex), !levels.values.isEmpty else { return nil }
        let sorted = levels.values.sorted()
        let top = max(sorted[Int(Double(sorted.count - 1) * 0.99)], 0.02)
        return VideoLoudness(values: levels.values, start: levels.start, top: top)
    }
}

// MARK: - Editor

extension VideoEditorModel {
    /// The computer sound dips under your voice here (the mix and the lane).
    var computerSoundDips: [VideoSoundDip] {
        guard hasSeparateVoiceAndSystem else { return [] }
        return VideoComputerSoundDucking.dips(project: project, primaryKinds: audioKinds, speech: media.speech, segments: segments)
    }

    /// The lane under the clips that draws the computer sound and its dips:
    /// there while it dips under the voice, or a part has its own level.
    var showsComputerSoundLane: Bool {
        hasSeparateVoiceAndSystem && (project.audio.duckSystem || project.timelineClips.contains { !$0.muted && $0.volume(for: .system) < 0.995 })
    }

    /// Places it dips (one per stretch of talking, however many cuts it
    /// spans), and how many were set by hand.
    var computerSoundDipCounts: (places: Int, custom: Int) {
        var talks: [ClosedRange<Double>: Bool] = [:]
        for dip in computerSoundDips { talks[dip.talk] = dip.custom }
        return (talks.count, talks.values.filter { $0 }.count)
    }

    /// The computer sound under one stretch of talking at its own level
    /// (1: not lowered there).
    func setComputerSoundDip(_ talk: ClosedRange<Double>, level: Double, coalesce: Bool = false) {
        mutate(coalesce: coalesce ? "duck-\(talk.lowerBound)" : nil, label: "Sound Change") { project in
            project.audio.systemDuckSpots.removeAll { $0.matches(talk) }
            project.audio.systemDuckSpots.append(VideoDuckSpot(start: talk.lowerBound, end: talk.upperBound, level: min(max(level, 0), 1)))
        }
    }

    /// That stretch dips like the rest again.
    func resetComputerSoundDip(_ talk: ClosedRange<Double>) {
        mutate(label: "Sound Change") { project in
            project.audio.systemDuckSpots.removeAll { $0.matches(talk) }
        }
    }

    /// Every dip at this level (places left alone stay that way).
    func useComputerSoundDipEverywhere(_ level: Double) {
        mutate(label: "Sound Change") { project in
            project.audio.systemDuckLevel = min(max(level, 0), 1)
            project.audio.systemDuckSpots.removeAll { $0.level < 0.999 }
        }
    }

    /// Every dip back to the level in Audio.
    func resetComputerSoundDips() {
        mutate(label: "Sound Change") { project in
            project.audio.systemDuckSpots = []
        }
    }

    /// The computer sound's loudness (0…1, for its lane) around a moment
    /// on the source axis (nil: not known there).
    func computerSoundLoudness(atSource time: Double, span: Double) -> Float? {
        var key = ""
        var local = time - project.primaryOffset
        if project.hasAppendedSources, let source = project.source(at: time), !source.isPrimary {
            key = source.id.uuidString
            local = time - source.offset
        }
        guard let levels = media.computerLoudness[key], !levels.values.isEmpty else { return nil }
        let rate = VideoVoiceActivity.rate
        let a = Int(((local - levels.start) * rate).rounded(.down))
        let b = Int(((local + span - levels.start) * rate).rounded(.up))
        guard b > 0, a < levels.values.count else { return nil }
        var peak: Float = 0
        for index in max(a, 0)..<min(max(b, a + 1), levels.values.count) { peak = max(peak, levels.values[index]) }
        return min(peak / max(levels.top, 0.0001), 1)
    }

    /// The level line through one clip: the clip's level times the whole
    /// video's, its fades, glides, and the dips under your voice.
    func computerSoundLevels(for index: Int, dips: [VideoSoundDip]) -> [VideoMusicMix.Keyframe] {
        guard segments.indices.contains(index) else { return [] }
        let segment = segments[index]
        let clip = segment.clip
        let level = clip.muted ? 0 : project.audio.effectiveVolume(for: .system) * Float(clip.volume(for: .system))
        var glideFrom: Float?
        if index > 0 {
            let previous = segments[index - 1].clip
            let before = previous.muted ? 0 : project.audio.effectiveVolume(for: .system) * Float(previous.volume(for: .system))
            glideFrom = VideoCompositionBuilder.glide(from: previous, level: before, to: clip, level: level)
        }
        return VideoCompositionBuilder.levelKeyframes(level: level, clip: clip, start: segment.timelineStart, end: segment.timelineEnd, glideFrom: glideFrom, dips: dips)
    }

    /// Opens the computer sound's settings (Audio).
    func showComputerSoundSettings() {
        selection = .none
        inspectorTab = .audio
    }

    /// What VoiceOver says for the computer sound's lane.
    var computerSoundAccessibilityLabel: String {
        let places = computerSoundDipCounts.places
        guard project.audio.duckSystem, places > 0 else { return L("Computer sound") }
        return L("Computer sound, lowered in \(places) places while you talk")
    }
}

extension VideoEditorTheme {
    static let computerSound = Color(red: 0.33, green: 0.78, blue: 0.95)
}

extension VideoTimelineMetrics {
    static let computerSoundLaneHeight: CGFloat = 30
}

// MARK: - Lane

/// The computer sound under the clips: what it played (faint), what's
/// heard (solid), and its level line, dipping where you talk. Drag a dip
/// to change how far it goes; right-click it to leave that place alone.
struct VideoComputerSoundLane: View, Equatable {
    let model: VideoEditorModel
    let segments: [VideoDemoTimelineSegment]
    let audio: VideoAudioSettings
    let dips: [VideoSoundDip]
    /// The loudness is loaded (redraw when it arrives).
    let loudnessReady: Bool
    let geometry: VideoTimelineGeometry

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.segments == b.segments && a.audio == b.audio && a.dips == b.dips && a.loudnessReady == b.loudnessReady && a.geometry == b.geometry
    }

    @State private var hovered: Int?
    @State private var dragging: Int?
    /// The dip's level when the drag began: it moves from there, wherever
    /// it was grabbed.
    @State private var dragStart: Double?

    private typealias M = VideoTimelineMetrics
    private var height: CGFloat { M.computerSoundLaneHeight }

    /// Level 0…1 → y (full volume at the top).
    private func y(_ level: Double) -> CGFloat { height - 4 - CGFloat(min(max(level, 0), 1)) * (height - 8) }

    var body: some View {
        let lines = segments.indices.map { model.computerSoundLevels(for: $0, dips: dips) }
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(in: &context, size: size, lines: lines)
            }
            .allowsHitTesting(false)
            ForEach(Array(dips.enumerated()), id: \.offset) { index, dip in
                dipHandle(dip, index: index)
            }
        }
        .frame(width: geometry.width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { location in
            model.seek(to: geometry.time(location.x))
            model.showComputerSoundSettings()
        }
        .help(L("Computer sound — drag a dip to change it, or click for its settings in Audio"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.computerSoundAccessibilityLabel)
        .accessibilityAction(named: L("Open in Audio")) { model.showComputerSoundSettings() }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, lines: [[VideoMusicMix.Keyframe]]) {
        let color = VideoEditorTheme.computerSound
        for (index, segment) in segments.enumerated() {
            let frame = CGRect(x: geometry.x(segment.timelineStart) + 1, y: 0, width: max(CGFloat(segment.duration) * geometry.pointsPerSecond - 2, 4), height: size.height)
            let shape = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)
            context.fill(shape, with: .color(color.opacity(0.13)))
            context.stroke(shape, with: .color(color.opacity(0.38)), lineWidth: 1)
            var inner = context
            inner.clip(to: shape)
            let line = lines.indices.contains(index) ? lines[index] : []
            // What played (faint), and what's heard of it (solid).
            var played = Path()
            var heard = Path()
            var x = frame.minX + 2
            let step: CGFloat = 3
            while x < frame.maxX - 1 {
                let t = geometry.time(x)
                let span = Double(step / geometry.pointsPerSecond)
                if let loud = model.computerSoundLoudness(atSource: segment.sourceTime(forTimelineTime: t), span: span * segment.clip.normalizedSpeed) {
                    let full = max(CGFloat(loud) * (size.height - 6), 1)
                    played.addRect(CGRect(x: x, y: (size.height - full) / 2, width: 2, height: full))
                    let gain = CGFloat(Self.value(at: t, in: line))
                    let h = max(full * gain, gain > 0.005 ? 1 : 0)
                    if h > 0 { heard.addRect(CGRect(x: x, y: (size.height - h) / 2, width: 2, height: h)) }
                }
                x += step
            }
            inner.fill(played, with: .color(color.opacity(0.22)))
            inner.fill(heard, with: .color(color.opacity(0.7)))
            // The level line.
            if line.count > 1 {
                var path = Path()
                for (n, keyframe) in line.enumerated() {
                    let point = CGPoint(x: geometry.x(keyframe.time), y: y(keyframe.volume))
                    if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                inner.stroke(path, with: .color(.white.opacity(0.88)), lineWidth: 1.3)
            }
            // Its name on a pill, like the clips'.
            if index == 0, frame.width > 150 {
                let label = inner.resolve(
                    Text("\(Image(systemName: "desktopcomputer")) \(L("Computer sound"))") // l10n-ignore: a symbol and a translated name
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white)
                )
                let measured = label.measure(in: CGSize(width: 400, height: size.height))
                let pill = CGRect(x: frame.minX + 4, y: 4, width: measured.width + 12, height: 15)
                inner.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2, style: .continuous), with: .color(.black.opacity(0.62)))
                inner.draw(label, at: CGPoint(x: pill.minX + 6, y: pill.midY), anchor: .leading)
            }
        }
        // A place left alone: where its dip would be, dashed.
        for dip in dips where !dip.lowered {
            var ghost = Path()
            let floor = y(audio.systemDuckLevel * Double(audio.effectiveVolume(for: .system)))
            let top = y(Double(audio.effectiveVolume(for: .system)))
            ghost.move(to: CGPoint(x: geometry.x(dip.range.lowerBound - VideoMusicMix.duckAttack), y: top))
            ghost.addLine(to: CGPoint(x: geometry.x(dip.range.lowerBound), y: floor))
            ghost.addLine(to: CGPoint(x: geometry.x(dip.range.upperBound), y: floor))
            ghost.addLine(to: CGPoint(x: geometry.x(dip.range.upperBound + VideoMusicMix.duckRelease), y: top))
            context.stroke(ghost, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    /// The line's value at a moment (straight between its points).
    static func value(at time: Double, in line: [VideoMusicMix.Keyframe]) -> Double {
        guard let first = line.first else { return 1 }
        if time <= first.time { return first.volume }
        for (a, b) in zip(line, line.dropFirst()) where time <= b.time {
            let span = b.time - a.time
            return span > 0.000001 ? a.volume + (b.volume - a.volume) * (time - a.time) / span : b.volume
        }
        return line.last?.volume ?? 1
    }

    /// The computer sound's level just outside the dip (what its level is
    /// a fraction of).
    private func base(_ dip: VideoSoundDip) -> Double {
        let middle = (dip.range.lowerBound + dip.range.upperBound) / 2
        guard let segment = segments.first(where: { $0.contains(timelineTime: middle) }) else { return 1 }
        return segment.clip.muted ? 0 : Double(audio.effectiveVolume(for: .system)) * segment.clip.volume(for: .system)
    }

    private func dipHandle(_ dip: VideoSoundDip, index: Int) -> some View {
        let x0 = geometry.x(dip.range.lowerBound)
        let width = max(geometry.x(dip.range.upperBound) - x0, 6)
        let base = base(dip)
        let active = hovered == index || dragging == index
        let percent = VideoEditorFormat.percent(dip.level)
        return ZStack {
            Color.clear
            if active {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                if width > 30 || dragging == index {
                    Text(dip.lowered ? percent : L("Not lowered"))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Color.white))
                        .fixedSize()
                        .position(x: width / 2, y: dip.lowered && dip.level * base > 0.5 ? height - 9 : 9)
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = index
                NSCursor.resizeUpDown.set()
            } else if hovered == index {
                hovered = nil
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard base > 0.001 else { return }
                    if dragging != index {
                        dragging = index
                        dragStart = dip.lowered ? dip.level : model.project.audio.systemDuckLevel
                        model.pause()
                    }
                    // The line's full height is the whole range.
                    let moved = -Double(value.translation.height / (height - 8)) / base
                    model.setComputerSoundDip(dip.talk, level: min(max((dragStart ?? dip.level) + moved, 0), 1), coalesce: true)
                }
                .onEnded { _ in
                    dragging = nil
                    dragStart = nil
                    model.endGesture()
                }
        )
        .contextMenu {
            if dip.lowered {
                Button(L("Don't Lower Here")) { model.setComputerSoundDip(dip.talk, level: 1) }
            } else {
                Button(L("Lower Here Again")) { model.resetComputerSoundDip(dip.talk) }
            }
            if dip.custom, dip.lowered {
                Button(L("Use \(percent) Everywhere")) { model.useComputerSoundDipEverywhere(dip.level) }
            }
            if dip.custom, dip.lowered {
                Button(L("Reset This Place")) { model.resetComputerSoundDip(dip.talk) }
            }
            Divider()
            Button(L("Lowering Settings…")) { model.showComputerSoundSettings() }
        }
        .help(dip.lowered ? L("Computer sound at \(percent) while you talk — drag to change, right-click for more") : L("Not lowered here — right-click to lower it again"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dip.lowered
            ? L("Computer sound at \(percent) while you talk, \(VideoEditorModel.timecode(dip.range.lowerBound)) to \(VideoEditorModel.timecode(dip.range.upperBound))")
            : L("Computer sound not lowered, \(VideoEditorModel.timecode(dip.range.lowerBound)) to \(VideoEditorModel.timecode(dip.range.upperBound))"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            model.setComputerSoundDip(dip.talk, level: ((dip.level + step) * 10).rounded() / 10)
        }
        .accessibilityAction(named: dip.lowered ? L("Don't Lower Here") : L("Lower Here Again")) {
            if dip.lowered { model.setComputerSoundDip(dip.talk, level: 1) } else { model.resetComputerSoundDip(dip.talk) }
        }
        .offset(x: x0)
    }
}
