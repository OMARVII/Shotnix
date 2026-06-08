import AppKit
import AVFoundation
import AVKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct VideoDemoTimelineClip: Codable, Equatable, Identifiable {
    var id: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double
    var muted: Bool
    var fadeIn: Double
    var fadeOut: Double

    init(
        id: UUID = UUID(),
        sourceStart: Double,
        sourceEnd: Double,
        speed: Double = 1,
        muted: Bool = false,
        fadeIn: Double = 0,
        fadeOut: Double = 0
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
        self.muted = muted
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    var sourceDuration: Double {
        max(sourceEnd - sourceStart, 0)
    }

    var normalizedSpeed: Double {
        min(max(speed, 0.25), 4)
    }

    var outputDuration: Double {
        sourceDuration / normalizedSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceStart
        case sourceEnd
        case speed
        case muted
        case fadeIn
        case fadeOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceStart = try container.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try container.decode(Double.self, forKey: .sourceEnd)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fadeIn = try container.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try container.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    }
}

struct VideoDemoTimelineSegment: Equatable, Identifiable {
    var id: UUID { clip.id }
    let clip: VideoDemoTimelineClip
    let timelineStart: Double

    var timelineEnd: Double {
        timelineStart + duration
    }

    var duration: Double {
        clip.outputDuration
    }

    func contains(sourceTime: Double) -> Bool {
        sourceTime >= clip.sourceStart && sourceTime <= clip.sourceEnd
    }

    func contains(timelineTime: Double) -> Bool {
        timelineTime >= timelineStart && timelineTime <= timelineEnd
    }

    func sourceTime(forTimelineTime timelineTime: Double) -> Double {
        let timelineOffset = min(max(timelineTime - timelineStart, 0), duration)
        return clip.sourceStart + timelineOffset * clip.normalizedSpeed
    }

    func timelineTime(forSourceTime sourceTime: Double) -> Double {
        timelineStart + min(max(sourceTime - clip.sourceStart, 0), clip.sourceDuration) / clip.normalizedSpeed
    }
}

enum VideoDemoOverlayEffectKind: String, Codable, CaseIterable, Identifiable {
    case text
    case arrow
    case highlight
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        }
    }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .highlight: return "rectangle.roundedtop"
        case .blur: return "eye.slash"
        }
    }
}

struct VideoDemoOverlayEffect: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: VideoDemoOverlayEffectKind
    var time: Double
    var duration: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String

    init(
        id: UUID = UUID(),
        kind: VideoDemoOverlayEffectKind,
        time: Double,
        duration: Double = 2,
        x: Double = 0.5,
        y: Double = 0.5,
        width: Double = 0.28,
        height: Double = 0.14,
        text: String = "Callout"
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.duration = duration
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
    }
}

struct VideoDemoProject: Codable, Equatable, Identifiable {
    enum AspectPreset: String, Codable, CaseIterable, Identifiable {
        case source
        case widescreen
        case vertical
        case square

        var id: String { rawValue }

        var title: String {
            switch self {
            case .source: return "Source"
            case .widescreen: return "16:9"
            case .vertical: return "9:16"
            case .square: return "1:1"
            }
        }

        func canvasSize(sourceSize: CGSize) -> CGSize {
            switch self {
            case .source:
                let fallback = CGSize(width: 1920, height: 1080)
                let size = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize : fallback
                return CGSize(width: Self.even(size.width), height: Self.even(size.height))
            case .widescreen:
                return CGSize(width: 1920, height: 1080)
            case .vertical:
                return CGSize(width: 1080, height: 1920)
            case .square:
                return CGSize(width: 1440, height: 1440)
            }
        }

        func previewAspectRatio(sourceSize: CGSize) -> CGFloat {
            let size = canvasSize(sourceSize: sourceSize)
            guard size.height > 0 else { return 16 / 9 }
            return size.width / size.height
        }

        private static func even(_ value: CGFloat) -> CGFloat {
            let rounded = max(2, Int(value.rounded()))
            return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
        }
    }

    enum BackgroundPreset: String, Codable, CaseIterable, Identifiable {
        case graphite
        case ocean
        case plum
        case linen
        case pure
        case mint

        var id: String { rawValue }

        var title: String {
            switch self {
            case .graphite: return "Graphite"
            case .ocean: return "Ocean"
            case .plum: return "Plum"
            case .linen: return "Linen"
            case .pure: return "Pure"
            case .mint: return "Mint"
            }
        }

        var exportColor: NSColor {
            switch self {
            case .graphite: return NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.055, alpha: 1)
            case .ocean: return NSColor(calibratedRed: 0.035, green: 0.11, blue: 0.15, alpha: 1)
            case .plum: return NSColor(calibratedRed: 0.12, green: 0.075, blue: 0.15, alpha: 1)
            case .linen: return NSColor(calibratedRed: 0.90, green: 0.86, blue: 0.78, alpha: 1)
            case .pure: return NSColor(calibratedWhite: 0.97, alpha: 1)
            case .mint: return NSColor(calibratedRed: 0.68, green: 0.88, blue: 0.80, alpha: 1)
            }
        }

        var previewColors: [Color] {
            switch self {
            case .graphite:
                return [Color(red: 0.05, green: 0.052, blue: 0.06), Color(red: 0.12, green: 0.12, blue: 0.14)]
            case .ocean:
                return [Color(red: 0.02, green: 0.10, blue: 0.16), Color(red: 0.00, green: 0.24, blue: 0.30)]
            case .plum:
                return [Color(red: 0.14, green: 0.08, blue: 0.18), Color(red: 0.24, green: 0.12, blue: 0.24)]
            case .linen:
                return [Color(red: 0.91, green: 0.86, blue: 0.76), Color(red: 0.80, green: 0.76, blue: 0.67)]
            case .pure:
                return [Color.white, Color(red: 0.90, green: 0.91, blue: 0.93)]
            case .mint:
                return [Color(red: 0.72, green: 0.92, blue: 0.84), Color(red: 0.32, green: 0.62, blue: 0.72)]
            }
        }
    }

    var id: UUID
    var sourcePath: String
    var createdAt: Date
    var sourceWidth: Double
    var sourceHeight: Double
    var trimStart: Double
    var trimEnd: Double
    var timelineClips: [VideoDemoTimelineClip]
    var aspectPreset: AspectPreset
    var backgroundPreset: BackgroundPreset
    var customBackgroundPath: String
    var backgroundBlur: Double
    var stageInset: Double
    var shadowStrength: Double
    var cornerRadius: Double
    var zoomKeyframes: [VideoDemoZoomKeyframe]
    var overlayEffects: [VideoDemoOverlayEffect]
    var cursorSamples: [VideoDemoCursorSample]
    var clickEvents: [VideoDemoClickEvent]
    var nativeCursorVisible: Bool
    var showCursorOverlay: Bool
    var enlargeCursor: Bool
    var showClickRipple: Bool
    var smoothCursor: Bool
    var cursorScale: Double
    var clickSpotlight: Bool
    var cursorMotionBlur: Bool

    static let minimumClipDuration = 0.1
    static let cursorScaleRange: ClosedRange<Double> = 1.0...2.5

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var sourceSize: CGSize { CGSize(width: sourceWidth, height: sourceHeight) }
    var customBackgroundURL: URL? {
        customBackgroundPath.isEmpty ? nil : URL(fileURLWithPath: customBackgroundPath)
    }
    var usesRawSourceFrame: Bool { aspectPreset == .source }
    var effectiveCornerRadius: Double { usesRawSourceFrame ? 0 : cornerRadius }
    var effectiveShadowStrength: Double { usesRawSourceFrame ? 0 : shadowStrength }

    static func make(sourceURL: URL, duration: Double = 0, sourceSize: CGSize = .zero) -> VideoDemoProject {
        VideoDemoProject(
            id: UUID(),
            sourcePath: sourceURL.path,
            createdAt: Date(),
            sourceWidth: Double(sourceSize.width),
            sourceHeight: Double(sourceSize.height),
            trimStart: 0,
            trimEnd: max(duration, 0),
            timelineClips: duration > 0 ? [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: max(duration, 0))] : [],
            aspectPreset: .widescreen,
            backgroundPreset: .graphite,
            customBackgroundPath: "",
            backgroundBlur: 0,
            stageInset: 0.085,
            shadowStrength: 0.42,
            cornerRadius: 24,
            zoomKeyframes: [],
            overlayEffects: [],
            cursorSamples: [],
            clickEvents: [],
            nativeCursorVisible: true,
            showCursorOverlay: false,
            enlargeCursor: true,
            showClickRipple: true,
            smoothCursor: true,
            cursorScale: 1.4,
            clickSpotlight: false,
            cursorMotionBlur: false
        )
    }

    mutating func apply(metadata: VideoDemoRecordingMetadata) {
        sourceWidth = metadata.sourceWidth
        sourceHeight = metadata.sourceHeight
        nativeCursorVisible = metadata.nativeCursorVisible
        cursorSamples = metadata.cursorSamples
        clickEvents = metadata.clickEvents
        showCursorOverlay = !metadata.nativeCursorVisible
        showClickRipple = true
        enlargeCursor = true
        smoothCursor = true
        cursorScale = 1.4
        if trimEnd <= 0 {
            trimEnd = metadata.duration
        }
        ensureTimeline(totalDuration: metadata.duration)
    }

    mutating func apply(preset: VideoDemoExportPreset) {
        switch preset {
        case .youtube:
            aspectPreset = .widescreen
            backgroundPreset = .graphite
            stageInset = 0.085
            shadowStrength = 0.44
            cornerRadius = 24
        case .twitter:
            aspectPreset = .widescreen
            backgroundPreset = .ocean
            stageInset = 0.075
            shadowStrength = 0.36
            cornerRadius = 20
        case .reels:
            aspectPreset = .vertical
            backgroundPreset = .plum
            stageInset = 0.105
            shadowStrength = 0.42
            cornerRadius = 26
        case .square:
            aspectPreset = .square
            backgroundPreset = .mint
            stageInset = 0.09
            shadowStrength = 0.34
            cornerRadius = 24
        }
    }

    mutating func apply(aspectPreset preset: AspectPreset) {
        aspectPreset = preset
        if preset == .source {
            stageInset = 0
            backgroundBlur = 0
            shadowStrength = 0
            cornerRadius = 0
        } else if stageInset <= 0.001 && shadowStrength <= 0.001 && cornerRadius <= 0.001 {
            stageInset = 0.085
            shadowStrength = 0.42
            cornerRadius = 24
        }
    }

    func normalizedTrim(totalDuration: Double) -> (start: Double, end: Double) {
        let total = max(totalDuration, 0)
        guard total > 0 else { return (0, 0) }
        let start = min(max(trimStart, 0), max(total - 0.1, 0))
        let end = min(max(trimEnd, start + 0.1), total)
        return (start, end)
    }

    mutating func ensureTimeline(totalDuration: Double) {
        let clips = normalizedTimelineClips(totalDuration: totalDuration)
        if clips.isEmpty, totalDuration > 0 {
            timelineClips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: totalDuration)]
        } else {
            timelineClips = clips
        }
        syncTrimToTimeline(totalDuration: totalDuration)
    }

    func normalizedTimelineClips(totalDuration: Double) -> [VideoDemoTimelineClip] {
        let total = max(totalDuration, 0)
        guard total > 0 else { return [] }

        let fallbackTrim = normalizedTrim(totalDuration: total)
        let sourceClips = timelineClips.isEmpty
            ? [VideoDemoTimelineClip(sourceStart: fallbackTrim.start, sourceEnd: fallbackTrim.end)]
            : timelineClips

        return sourceClips.compactMap { clip in
            let start = min(max(clip.sourceStart, 0), max(total - Self.minimumClipDuration, 0))
            let end = min(max(clip.sourceEnd, start + Self.minimumClipDuration), total)
            guard end - start >= Self.minimumClipDuration else { return nil }
            return VideoDemoTimelineClip(
                id: clip.id,
                sourceStart: start,
                sourceEnd: end,
                speed: clip.speed,
                muted: clip.muted,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut
            )
        }
    }

    func timelineSegments(totalDuration: Double) -> [VideoDemoTimelineSegment] {
        var timelineStart = 0.0
        return normalizedTimelineClips(totalDuration: totalDuration).map { clip in
            let segment = VideoDemoTimelineSegment(clip: clip, timelineStart: timelineStart)
            timelineStart += clip.outputDuration
            return segment
        }
    }

    func timelineDuration(totalDuration: Double) -> Double {
        timelineSegments(totalDuration: totalDuration).last?.timelineEnd ?? 0
    }

    func sourceTime(forTimelineTime timelineTime: Double, totalDuration: Double) -> Double {
        let segments = timelineSegments(totalDuration: totalDuration)
        guard let first = segments.first else { return 0 }
        let safeTimeline = min(max(timelineTime, 0), max(segments.last?.timelineEnd ?? 0, 0))

        for segment in segments where safeTimeline <= segment.timelineEnd {
            return segment.sourceTime(forTimelineTime: safeTimeline)
        }

        return segments.last?.clip.sourceEnd ?? first.clip.sourceStart
    }

    func timelineTime(forSourceTime sourceTime: Double, totalDuration: Double) -> Double {
        let segments = timelineSegments(totalDuration: totalDuration)
        guard let first = segments.first else { return 0 }

        if let included = timelineTimeIfIncluded(sourceTime: sourceTime, segments: segments) {
            return included
        }

        var nearest = (distance: abs(sourceTime - first.clip.sourceStart), timelineTime: first.timelineStart)
        for segment in segments {
            let startDistance = abs(sourceTime - segment.clip.sourceStart)
            if startDistance < nearest.distance {
                nearest = (startDistance, segment.timelineStart)
            }
            let endDistance = abs(sourceTime - segment.clip.sourceEnd)
            if endDistance < nearest.distance {
                nearest = (endDistance, segment.timelineEnd)
            }
        }
        return nearest.timelineTime
    }

    func timelineTimeIfIncluded(sourceTime: Double, totalDuration: Double) -> Double? {
        timelineTimeIfIncluded(sourceTime: sourceTime, segments: timelineSegments(totalDuration: totalDuration))
    }

    func timelineTimeIfIncluded(sourceTime: Double, segments: [VideoDemoTimelineSegment]) -> Double? {
        for segment in segments where segment.contains(sourceTime: sourceTime) {
            return segment.timelineTime(forSourceTime: sourceTime)
        }
        return nil
    }

    mutating func splitClip(atSourceTime sourceTime: Double, totalDuration: Double) -> UUID? {
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard let index = clips.firstIndex(where: {
            sourceTime > $0.sourceStart + Self.minimumClipDuration &&
            sourceTime < $0.sourceEnd - Self.minimumClipDuration
        }) else {
            return nil
        }

        let original = clips[index]
        let first = VideoDemoTimelineClip(
            id: original.id,
            sourceStart: original.sourceStart,
            sourceEnd: sourceTime,
            speed: original.speed,
            muted: original.muted,
            fadeIn: original.fadeIn,
            fadeOut: 0
        )
        let second = VideoDemoTimelineClip(
            sourceStart: sourceTime,
            sourceEnd: original.sourceEnd,
            speed: original.speed,
            muted: original.muted,
            fadeIn: 0,
            fadeOut: original.fadeOut
        )
        clips.replaceSubrange(index...index, with: [first, second])
        timelineClips = clips
        syncTrimToTimeline(totalDuration: totalDuration)
        return second.id
    }

    mutating func deleteClip(id: UUID, totalDuration: Double) -> UUID? {
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard clips.count > 1, let index = clips.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        clips.remove(at: index)
        timelineClips = clips
        syncTrimToTimeline(totalDuration: totalDuration)
        return clips[min(index, clips.count - 1)].id
    }

    mutating func deleteTimelineRange(start: Double, end: Double, totalDuration: Double) -> UUID? {
        let duration = timelineDuration(totalDuration: totalDuration)
        guard duration > Self.minimumClipDuration else { return nil }

        let rangeStart = min(max(min(start, end), 0), max(duration - Self.minimumClipDuration, 0))
        let rangeEnd = min(max(max(start, end), rangeStart + Self.minimumClipDuration), duration)
        guard rangeEnd - rangeStart >= Self.minimumClipDuration else { return nil }

        var remaining: [VideoDemoTimelineClip] = []
        for segment in timelineSegments(totalDuration: totalDuration) {
            if segment.timelineEnd <= rangeStart || segment.timelineStart >= rangeEnd {
                remaining.append(segment.clip)
                continue
            }

            if rangeStart > segment.timelineStart + Self.minimumClipDuration {
                let sourceEnd = segment.sourceTime(forTimelineTime: min(rangeStart, segment.timelineEnd))
                if sourceEnd - segment.clip.sourceStart >= Self.minimumClipDuration {
                    remaining.append(VideoDemoTimelineClip(
                        id: segment.clip.id,
                        sourceStart: segment.clip.sourceStart,
                        sourceEnd: sourceEnd,
                        speed: segment.clip.speed,
                        muted: segment.clip.muted,
                        fadeIn: segment.clip.fadeIn,
                        fadeOut: 0
                    ))
                }
            }

            if rangeEnd < segment.timelineEnd - Self.minimumClipDuration {
                let sourceStart = segment.sourceTime(forTimelineTime: max(rangeEnd, segment.timelineStart))
                if segment.clip.sourceEnd - sourceStart >= Self.minimumClipDuration {
                    remaining.append(VideoDemoTimelineClip(
                        sourceStart: sourceStart,
                        sourceEnd: segment.clip.sourceEnd,
                        speed: segment.clip.speed,
                        muted: segment.clip.muted,
                        fadeIn: 0,
                        fadeOut: segment.clip.fadeOut
                    ))
                }
            }
        }

        guard !remaining.isEmpty else { return nil }
        timelineClips = remaining
        syncTrimToTimeline(totalDuration: totalDuration)

        let nextTimeline = min(rangeStart, max(timelineDuration(totalDuration: totalDuration) - 0.001, 0))
        return timelineSegments(totalDuration: totalDuration).first(where: { $0.contains(timelineTime: nextTimeline) })?.id
            ?? timelineClips.last?.id
    }

    mutating func trimClip(id: UUID, sourceStart: Double? = nil, sourceEnd: Double? = nil, totalDuration: Double) -> Bool {
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }

        var clip = clips[index]
        if let sourceStart {
            clip.sourceStart = min(max(sourceStart, 0), clip.sourceEnd - Self.minimumClipDuration)
        }
        if let sourceEnd {
            clip.sourceEnd = min(max(sourceEnd, clip.sourceStart + Self.minimumClipDuration), totalDuration)
        }

        guard clip.sourceDuration >= Self.minimumClipDuration else { return false }
        clip.speed = min(max(clip.speed, 0.25), 4)
        clip.fadeIn = min(max(clip.fadeIn, 0), max(clip.outputDuration / 2, 0))
        clip.fadeOut = min(max(clip.fadeOut, 0), max(clip.outputDuration / 2, 0))
        clips[index] = clip
        timelineClips = clips
        syncTrimToTimeline(totalDuration: totalDuration)
        return true
    }

    mutating func updateClip(id: UUID, totalDuration: Double, update: (inout VideoDemoTimelineClip) -> Void) -> Bool {
        var clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
        update(&clips[index])
        clips[index].speed = min(max(clips[index].speed, 0.25), 4)
        clips[index].fadeIn = min(max(clips[index].fadeIn, 0), max(clips[index].outputDuration / 2, 0))
        clips[index].fadeOut = min(max(clips[index].fadeOut, 0), max(clips[index].outputDuration / 2, 0))
        timelineClips = clips
        syncTrimToTimeline(totalDuration: totalDuration)
        return true
    }

    func overlayEffectsActive(at sourceTime: Double) -> [VideoDemoOverlayEffect] {
        overlayEffects.filter { effect in
            sourceTime >= effect.time && sourceTime <= effect.time + max(effect.duration, 0.1)
        }
    }

    mutating func setSingleTrim(start: Double, end: Double, totalDuration: Double) {
        let total = max(totalDuration, 0)
        guard total > 0 else {
            trimStart = 0
            trimEnd = 0
            timelineClips = []
            return
        }

        let safeStart = min(max(start, 0), max(total - Self.minimumClipDuration, 0))
        let safeEnd = min(max(end, safeStart + Self.minimumClipDuration), total)
        timelineClips = [VideoDemoTimelineClip(sourceStart: safeStart, sourceEnd: safeEnd)]
        syncTrimToTimeline(totalDuration: total)
    }

    private mutating func syncTrimToTimeline(totalDuration: Double) {
        let clips = normalizedTimelineClips(totalDuration: totalDuration)
        guard let first = clips.first, let last = clips.last else {
            trimStart = 0
            trimEnd = 0
            return
        }
        trimStart = first.sourceStart
        trimEnd = last.sourceEnd
    }

    func canvasSize() -> CGSize {
        aspectPreset.canvasSize(sourceSize: sourceSize)
    }

    func stageRect(in canvasSize: CGSize) -> CGRect {
        if usesRawSourceFrame {
            return CGRect(origin: .zero, size: canvasSize)
        }

        let inset = max(0.02, min(stageInset, 0.22))
        let available = CGRect(origin: .zero, size: canvasSize).insetBy(
            dx: canvasSize.width * inset,
            dy: canvasSize.height * inset
        )
        let sourceRatio = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16 / 9
        let availableRatio = available.width / max(available.height, 1)

        let fittedSize: CGSize
        if sourceRatio > availableRatio {
            fittedSize = CGSize(width: available.width, height: available.width / sourceRatio)
        } else {
            fittedSize = CGSize(width: available.height * sourceRatio, height: available.height)
        }

        return CGRect(
            x: available.midX - fittedSize.width / 2,
            y: available.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    func zoomState(at time: Double) -> VideoDemoZoomState {
        let sorted = zoomKeyframes.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return .identity }
        guard time >= first.time else { return .identity }

        var previous = VideoDemoZoomState(
            scale: first.scale,
            focusX: first.focusX,
            focusY: first.focusY
        )
        var previousTime = first.time

        if sorted.count == 1 || time <= first.time {
            return previous
        }

        for keyframe in sorted.dropFirst() {
            let current = VideoDemoZoomState(scale: keyframe.scale, focusX: keyframe.focusX, focusY: keyframe.focusY)
            if time <= keyframe.time {
                let distance = max(keyframe.time - previousTime, 0.001)
                let progress = smoothCameraProgress(min(max((time - previousTime) / distance, 0), 1))
                return VideoDemoZoomState(
                    scale: lerp(previous.scale, current.scale, progress),
                    focusX: lerp(previous.focusX, current.focusX, progress),
                    focusY: lerp(previous.focusY, current.focusY, progress)
                )
            }
            previous = current
            previousTime = keyframe.time
        }

        return previous
    }

    func zoomedStageRect(in canvasSize: CGSize, at time: Double) -> CGRect {
        let stage = stageRect(in: canvasSize)
        let zoom = zoomState(at: time)
        guard zoom.scale > 1.001 else { return stage }

        let scaledWidth = stage.width * zoom.scale
        let scaledHeight = stage.height * zoom.scale
        let focusX = min(max(zoom.focusX, 0), 1)
        let focusYBottom = 1 - min(max(zoom.focusY, 0), 1)

        return CGRect(
            x: stage.midX - scaledWidth * focusX,
            y: stage.midY - scaledHeight * focusYBottom,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    func canvasPoint(for normalizedPoint: CGPoint, in canvasSize: CGSize, at time: Double) -> CGPoint {
        let stage = zoomedStageRect(in: canvasSize, at: time)
        let x = stage.minX + stage.width * min(max(normalizedPoint.x, 0), 1)
        let y = stage.minY + stage.height * (1 - min(max(normalizedPoint.y, 0), 1))
        return CGPoint(x: x, y: y)
    }

    private func lerp(_ a: Double, _ b: Double, _ progress: Double) -> Double {
        a + (b - a) * progress
    }

    private func smoothCameraProgress(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

extension VideoDemoProject {
    private enum CodingKeys: String, CodingKey {
        case id
        case sourcePath
        case createdAt
        case sourceWidth
        case sourceHeight
        case trimStart
        case trimEnd
        case timelineClips
        case aspectPreset
        case backgroundPreset
        case customBackgroundPath
        case backgroundBlur
        case stageInset
        case shadowStrength
        case cornerRadius
        case zoomKeyframes
        case overlayEffects
        case cursorSamples
        case clickEvents
        case nativeCursorVisible
        case showCursorOverlay
        case enlargeCursor
        case showClickRipple
        case smoothCursor
        case cursorScale
        case clickSpotlight
        case cursorMotionBlur
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceWidth = try container.decode(Double.self, forKey: .sourceWidth)
        sourceHeight = try container.decode(Double.self, forKey: .sourceHeight)
        trimStart = try container.decode(Double.self, forKey: .trimStart)
        trimEnd = try container.decode(Double.self, forKey: .trimEnd)
        timelineClips = try container.decodeIfPresent([VideoDemoTimelineClip].self, forKey: .timelineClips) ?? []
        aspectPreset = try container.decode(VideoDemoProject.AspectPreset.self, forKey: .aspectPreset)
        backgroundPreset = try container.decode(VideoDemoProject.BackgroundPreset.self, forKey: .backgroundPreset)
        customBackgroundPath = try container.decode(String.self, forKey: .customBackgroundPath)
        backgroundBlur = try container.decode(Double.self, forKey: .backgroundBlur)
        stageInset = try container.decode(Double.self, forKey: .stageInset)
        shadowStrength = try container.decode(Double.self, forKey: .shadowStrength)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        zoomKeyframes = try container.decode([VideoDemoZoomKeyframe].self, forKey: .zoomKeyframes)
        overlayEffects = try container.decodeIfPresent([VideoDemoOverlayEffect].self, forKey: .overlayEffects) ?? []
        cursorSamples = try container.decode([VideoDemoCursorSample].self, forKey: .cursorSamples)
        clickEvents = try container.decode([VideoDemoClickEvent].self, forKey: .clickEvents)
        nativeCursorVisible = try container.decode(Bool.self, forKey: .nativeCursorVisible)
        showCursorOverlay = try container.decode(Bool.self, forKey: .showCursorOverlay)
        enlargeCursor = try container.decode(Bool.self, forKey: .enlargeCursor)
        showClickRipple = try container.decode(Bool.self, forKey: .showClickRipple)
        smoothCursor = try container.decode(Bool.self, forKey: .smoothCursor)
        // Drafts predating the cursor polish pack migrate from the old binary `enlargeCursor`.
        cursorScale = try container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? (enlargeCursor ? 1.4 : 1.0)
        clickSpotlight = try container.decodeIfPresent(Bool.self, forKey: .clickSpotlight) ?? false
        cursorMotionBlur = try container.decodeIfPresent(Bool.self, forKey: .cursorMotionBlur) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourcePath, forKey: .sourcePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(sourceWidth, forKey: .sourceWidth)
        try container.encode(sourceHeight, forKey: .sourceHeight)
        try container.encode(trimStart, forKey: .trimStart)
        try container.encode(trimEnd, forKey: .trimEnd)
        try container.encode(timelineClips, forKey: .timelineClips)
        try container.encode(aspectPreset, forKey: .aspectPreset)
        try container.encode(backgroundPreset, forKey: .backgroundPreset)
        try container.encode(customBackgroundPath, forKey: .customBackgroundPath)
        try container.encode(backgroundBlur, forKey: .backgroundBlur)
        try container.encode(stageInset, forKey: .stageInset)
        try container.encode(shadowStrength, forKey: .shadowStrength)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(zoomKeyframes, forKey: .zoomKeyframes)
        try container.encode(overlayEffects, forKey: .overlayEffects)
        try container.encode(cursorSamples, forKey: .cursorSamples)
        try container.encode(clickEvents, forKey: .clickEvents)
        try container.encode(nativeCursorVisible, forKey: .nativeCursorVisible)
        try container.encode(showCursorOverlay, forKey: .showCursorOverlay)
        try container.encode(enlargeCursor, forKey: .enlargeCursor)
        try container.encode(showClickRipple, forKey: .showClickRipple)
        try container.encode(smoothCursor, forKey: .smoothCursor)
        try container.encode(cursorScale, forKey: .cursorScale)
        try container.encode(clickSpotlight, forKey: .clickSpotlight)
        try container.encode(cursorMotionBlur, forKey: .cursorMotionBlur)
    }
}

enum VideoDemoExportPreset: String, CaseIterable, Identifiable {
    case youtube
    case twitter
    case reels
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitter: return "X / Twitter"
        case .reels: return "Reels"
        case .square: return "Square"
        }
    }

    var subtitle: String {
        switch self {
        case .youtube: return "16:9"
        case .twitter: return "16:9"
        case .reels: return "9:16"
        case .square: return "1:1"
        }
    }
}

struct VideoDemoMetadata: Equatable {
    let duration: Double
    let sourceSize: CGSize
}

struct VideoTimelineThumbnail: Identifiable {
    let id = UUID()
    let time: Double
    let image: NSImage
}

struct VideoDemoTimelineRange: Equatable, Identifiable {
    var id: String { "\(start)-\(end)" }
    var start: Double
    var end: Double

    var normalized: VideoDemoTimelineRange {
        VideoDemoTimelineRange(start: min(start, end), end: max(start, end))
    }

    var duration: Double {
        max(end - start, 0)
    }
}

enum VideoDemoExportError: LocalizedError {
    case missingVideoTrack
    case invalidTrim
    case cannotCreateCompositionTrack
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The selected file has no video track."
        case .invalidTrim:
            return "The trim range is invalid."
        case .cannotCreateCompositionTrack:
            return "Could not prepare the video composition."
        case .cannotCreateExportSession:
            return "Could not start the export session."
        case .exportFailed(let message):
            return message
        }
    }
}

enum VideoDemoExporter {
    private static let exportTimescale: CMTimeScale = 600
    private static let minimumZoomExportRampDuration = 1.0 / 30.0

    static func metadata(for sourceURL: URL) async throws -> VideoDemoMetadata {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDemoExportError.missingVideoTrack
        }
        return VideoDemoMetadata(
            duration: seconds(try await asset.load(.duration)),
            sourceSize: try await orientedSize(for: videoTrack)
        )
    }

    static func export(
        project: VideoDemoProject,
        destinationURL: URL,
        progress: @escaping @Sendable (Double) async -> Void = { _ in },
        shouldCancel: @escaping @Sendable () async -> Bool = { false }
    ) async throws {
        let asset = AVURLAsset(url: project.sourceURL)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDemoExportError.missingVideoTrack
        }

        let totalDuration = seconds(try await asset.load(.duration))
        let timelineSegments = project.timelineSegments(totalDuration: totalDuration)
        guard !timelineSegments.isEmpty else { throw VideoDemoExportError.invalidTrim }

        let compositionDuration = CMTime(
            seconds: timelineSegments.last?.timelineEnd ?? 0,
            preferredTimescale: 600
        )
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoDemoExportError.cannotCreateCompositionTrack
        }

        for segment in timelineSegments {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.clip.sourceDuration, preferredTimescale: 600)
            )
            let timelineStart = CMTime(seconds: segment.timelineStart, preferredTimescale: 600)
            try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: timelineStart)
            scaleIfNeeded(
                track: compositionVideoTrack,
                at: timelineStart,
                sourceDuration: sourceRange.duration,
                outputDuration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
        }

        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudioTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            for segment in timelineSegments {
                guard !segment.clip.muted else { continue }
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: segment.clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.clip.sourceDuration, preferredTimescale: 600)
                )
                let timelineStart = CMTime(seconds: segment.timelineStart, preferredTimescale: 600)
                try? compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timelineStart)
                scaleIfNeeded(
                    track: compositionAudioTrack,
                    at: timelineStart,
                    sourceDuration: sourceRange.duration,
                    outputDuration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                )
                applyAudioFades(to: parameters, segment: segment)
            }
            audioMixParameters.append(parameters)
        }

        var exportProject = project
        let sourceSize = try await orientedSize(for: sourceVideoTrack)
        exportProject.sourceWidth = Double(sourceSize.width)
        exportProject.sourceHeight = Double(sourceSize.height)

        let renderSize = exportProject.canvasSize()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: compositionDuration)
        instruction.backgroundColor = NSColor.clear.cgColor

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        try await applyZoomTransforms(
            to: layerInstruction,
            track: sourceVideoTrack,
            project: exportProject,
            sourceSize: sourceSize,
            renderSize: renderSize,
            timelineSegments: timelineSegments
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let layers = makeAnimationLayers(
            project: exportProject,
            renderSize: renderSize,
            timelineSegments: timelineSegments,
            duration: compositionDuration.secondsValue
        )
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: layers.videoLayer,
            in: layers.parentLayer
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoDemoExportError.cannotCreateExportSession
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition
        if !audioMixParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioMixParameters
            exportSession.audioMix = audioMix
        }

        let exportBox = AssetExportSessionBox(exportSession)
        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if await shouldCancel() {
                    exportBox.session.cancelExport()
                    return
                }
                await progress(Double(exportBox.session.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        defer {
            progressTask.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    Task { await progress(1) }
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportBox.session.error?.localizedDescription ?? "Video export failed."
                    continuation.resume(throwing: VideoDemoExportError.exportFailed(message))
                default:
                    continuation.resume(throwing: VideoDemoExportError.exportFailed("Video export ended unexpectedly."))
                }
            }
        }
    }

    private static func scaleIfNeeded(
        track: AVMutableCompositionTrack,
        at start: CMTime,
        sourceDuration: CMTime,
        outputDuration: CMTime
    ) {
        guard abs(sourceDuration.secondsValue - outputDuration.secondsValue) > 0.001 else { return }
        track.scaleTimeRange(CMTimeRange(start: start, duration: sourceDuration), toDuration: outputDuration)
    }

    private static func applyAudioFades(
        to parameters: AVMutableAudioMixInputParameters,
        segment: VideoDemoTimelineSegment
    ) {
        let start = CMTime(seconds: segment.timelineStart, preferredTimescale: exportTimescale)
        let duration = CMTime(seconds: segment.duration, preferredTimescale: exportTimescale)
        let range = CMTimeRange(start: start, duration: duration)
        parameters.setVolume(1, at: start)

        let fadeIn = min(max(segment.clip.fadeIn, 0), segment.duration / 2)
        if fadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: CMTimeRange(
                    start: start,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: exportTimescale)
                )
            )
        }

        let fadeOut = min(max(segment.clip.fadeOut, 0), segment.duration / 2)
        if fadeOut > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 1,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: max(segment.timelineEnd - fadeOut, 0), preferredTimescale: exportTimescale),
                    duration: CMTime(seconds: fadeOut, preferredTimescale: exportTimescale)
                )
            )
        } else {
            parameters.setVolume(1, at: CMTimeRangeGetEnd(range))
        }
    }

    private static func applyZoomTransforms(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        track: AVAssetTrack,
        project: VideoDemoProject,
        sourceSize: CGSize,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment]
    ) async throws {
        let timelineKeyframes = zoomTimelineKeyframes(project: project, segments: timelineSegments)

        guard let first = timelineKeyframes.first else {
            let rect = project.stageRect(in: renderSize)
            layerInstruction.setTransform(
                try await exportTransform(for: track, project: project, sourceSize: sourceSize, renderSize: renderSize, targetRect: rect),
                at: .zero
            )
            return
        }

        let firstRect = project.zoomedStageRect(in: renderSize, at: first.sourceTime)
        let firstTransform = try await exportTransform(
            for: track,
            project: project,
            sourceSize: sourceSize,
            renderSize: renderSize,
            targetRect: firstRect
        )
        layerInstruction.setTransform(firstTransform, at: .zero)

        guard timelineKeyframes.count > 1 else { return }
        for pair in zip(timelineKeyframes, timelineKeyframes.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let startTransform = try await exportTransform(
                for: track,
                project: project,
                sourceSize: sourceSize,
                renderSize: renderSize,
                targetRect: project.zoomedStageRect(in: renderSize, at: start.sourceTime)
            )
            let endTransform = try await exportTransform(
                for: track,
                project: project,
                sourceSize: sourceSize,
                renderSize: renderSize,
                targetRect: project.zoomedStageRect(in: renderSize, at: end.sourceTime)
            )
            guard let duration = zoomRampDuration(from: start.timelineTime, to: end.timelineTime) else {
                layerInstruction.setTransform(endTransform, at: CMTime(seconds: max(end.timelineTime, 0), preferredTimescale: exportTimescale))
                continue
            }
            let range = CMTimeRange(
                start: CMTime(seconds: max(start.timelineTime, 0), preferredTimescale: exportTimescale),
                duration: CMTime(seconds: duration, preferredTimescale: exportTimescale)
            )
            guard range.start.isNumeric, range.duration.isNumeric, range.duration.value > 0 else { continue }
            layerInstruction.setTransformRamp(fromStart: startTransform, toEnd: endTransform, timeRange: range)
        }
    }

    static func zoomRampDuration(from startTimelineTime: Double, to endTimelineTime: Double) -> Double? {
        guard startTimelineTime.isFinite, endTimelineTime.isFinite else { return nil }
        let duration = endTimelineTime - startTimelineTime
        guard duration >= minimumZoomExportRampDuration else { return nil }
        return duration
    }

    static func zoomTimelineKeyframes(
        project: VideoDemoProject,
        segments: [VideoDemoTimelineSegment]
    ) -> [(timelineTime: Double, sourceTime: Double)] {
        var mapped: [(timelineTime: Double, sourceTime: Double)] = []
        let zoomTimes = project.zoomKeyframes
            .map(\.time)
            .filter(\.isFinite)
            .sorted()

        for segment in segments {
            guard segment.duration > 0, segment.clip.sourceDuration > 0 else { continue }

            appendZoomSample(sourceTime: segment.clip.sourceStart, segment: segment, into: &mapped)
            appendZoomSample(sourceTime: segment.clip.sourceEnd, segment: segment, into: &mapped)

            guard !zoomTimes.isEmpty else { continue }

            let anchors = ([segment.clip.sourceStart, segment.clip.sourceEnd] + zoomTimes)
                .filter { $0 >= segment.clip.sourceStart && $0 <= segment.clip.sourceEnd }
                .sorted()

            for sourceTime in anchors {
                appendZoomSample(sourceTime: sourceTime, segment: segment, into: &mapped)
            }

            for pair in zip(anchors, anchors.dropFirst()) {
                let start = pair.0
                let end = pair.1
                let sourceDuration = end - start
                guard sourceDuration > 0.12 else { continue }
                guard project.zoomState(at: start).isMeaningfullyDifferent(from: project.zoomState(at: end)) else { continue }

                let sampleCount = min(max(Int(ceil(sourceDuration / 0.35)), 2), 6)
                for index in 1..<sampleCount {
                    let progress = Double(index) / Double(sampleCount)
                    appendZoomSample(sourceTime: start + sourceDuration * progress, segment: segment, into: &mapped)
                }
            }
        }

        let sorted = mapped.sorted { lhs, rhs in
            if lhs.timelineTime == rhs.timelineTime {
                return lhs.sourceTime < rhs.sourceTime
            }
            return lhs.timelineTime < rhs.timelineTime
        }
        var unique: [(timelineTime: Double, sourceTime: Double)] = []
        for entry in sorted {
            guard entry.timelineTime.isFinite, entry.sourceTime.isFinite else { continue }
            if let last = unique.last,
               abs(entry.timelineTime - last.timelineTime) < 0.0005,
               abs(entry.sourceTime - last.sourceTime) < 0.0005 {
                continue
            }
            unique.append(entry)
        }
        return unique
    }

    private static func appendZoomSample(
        sourceTime: Double,
        segment: VideoDemoTimelineSegment,
        into mapped: inout [(timelineTime: Double, sourceTime: Double)]
    ) {
        guard sourceTime.isFinite else { return }
        let safeSourceTime = min(max(sourceTime, segment.clip.sourceStart), segment.clip.sourceEnd)
        mapped.append((segment.timelineTime(forSourceTime: safeSourceTime), safeSourceTime))
    }

    private static func exportTransform(
        for track: AVAssetTrack,
        project: VideoDemoProject,
        sourceSize: CGSize,
        renderSize: CGSize,
        targetRect: CGRect
    ) async throws -> CGAffineTransform {
        let fallbackRect = project.stageRect(in: renderSize)
        let safeTargetRect = targetRect.hasUsableVideoGeometry ? targetRect : fallbackRect
        let candidate = try await transform(for: track, sourceSize: sourceSize, targetRect: safeTargetRect)
        if candidate.hasFiniteComponents {
            return candidate
        }

        let fallback = try await transform(for: track, sourceSize: sourceSize, targetRect: fallbackRect)
        return fallback.hasFiniteComponents ? fallback : .identity
    }

    private static func makeAnimationLayers(
        project: VideoDemoProject,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment],
        duration: Double
    ) -> (videoLayer: CALayer, parentLayer: CALayer) {
        let bounds = CGRect(origin: .zero, size: renderSize)
        let stage = project.stageRect(in: renderSize)

        let parent = CALayer()
        parent.frame = bounds
        parent.backgroundColor = project.backgroundPreset.exportColor.cgColor
        parent.masksToBounds = true

        let background = CALayer()
        background.frame = bounds
        background.backgroundColor = project.backgroundPreset.exportColor.cgColor
        if !project.usesRawSourceFrame,
           let url = project.customBackgroundURL,
           let image = NSImage(contentsOf: url),
           let cgImage = image.bestCGImage {
            background.contents = cgImage
            background.contentsGravity = .resizeAspectFill
        }
        parent.addSublayer(background)

        if !project.usesRawSourceFrame {
            let shadow = CALayer()
            shadow.frame = stage
            shadow.cornerRadius = max(project.effectiveCornerRadius, 0)
            shadow.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = Float(max(0, min(project.effectiveShadowStrength, 0.85)))
            shadow.shadowRadius = 34
            shadow.shadowOffset = CGSize(width: 0, height: -20)
            parent.addSublayer(shadow)
        }

        let videoLayer = CALayer()
        videoLayer.frame = bounds
        parent.addSublayer(videoLayer)

        addStageMaskCovers(to: parent, stage: stage, bounds: bounds, color: project.backgroundPreset.exportColor)

        if !project.usesRawSourceFrame {
            let border = CALayer()
            border.frame = stage
            border.cornerRadius = max(project.effectiveCornerRadius, 0)
            border.borderWidth = 2
            border.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            parent.addSublayer(border)
        }

        addOverlayEffectLayers(
            to: parent,
            project: project,
            renderSize: renderSize,
            timelineSegments: timelineSegments,
            duration: duration
        )

        if project.clickSpotlight {
            addClickSpotlightLayers(
                to: parent,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }
        if project.showClickRipple {
            addClickLayers(
                to: parent,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }
        if project.showCursorOverlay {
            addCursorLayer(
                to: parent,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }

        return (videoLayer, parent)
    }

    private static func addStageMaskCovers(to parent: CALayer, stage: CGRect, bounds: CGRect, color: NSColor) {
        let rects = [
            CGRect(x: 0, y: 0, width: bounds.width, height: max(stage.minY, 0)),
            CGRect(x: 0, y: stage.maxY, width: bounds.width, height: max(bounds.maxY - stage.maxY, 0)),
            CGRect(x: 0, y: stage.minY, width: max(stage.minX, 0), height: stage.height),
            CGRect(x: stage.maxX, y: stage.minY, width: max(bounds.maxX - stage.maxX, 0), height: stage.height),
        ]

        for rect in rects where rect.width > 0 && rect.height > 0 {
            let cover = CALayer()
            cover.frame = rect
            cover.backgroundColor = color.cgColor
            parent.addSublayer(cover)
        }
    }

    private static func addOverlayEffectLayers(
        to parent: CALayer,
        project: VideoDemoProject,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment],
        duration: Double
    ) {
        guard duration > 0 else { return }

        for effect in project.overlayEffects {
            guard let entry = timelineEntry(for: effect, segments: timelineSegments) else { continue }
            let stage = project.zoomedStageRect(in: renderSize, at: effect.time)
            let effectWidth = stage.width * min(max(effect.width, 0.04), 0.9)
            let effectHeight = stage.height * min(max(effect.height, 0.04), 0.6)
            let frame = CGRect(
                x: stage.minX + stage.width * min(max(effect.x, 0), 1) - effectWidth / 2,
                y: stage.minY + stage.height * (1 - min(max(effect.y, 0), 1)) - effectHeight / 2,
                width: effectWidth,
                height: effectHeight
            )

            let layer: CALayer
            switch effect.kind {
            case .text:
                let text = CATextLayer()
                text.string = effect.text
                text.font = NSFont.systemFont(ofSize: max(renderSize.width * 0.026, 26), weight: .bold)
                text.fontSize = max(renderSize.width * 0.026, 26)
                text.foregroundColor = NSColor.white.cgColor
                text.alignmentMode = .center
                text.contentsScale = 2
                text.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
                text.cornerRadius = 18
                text.masksToBounds = true
                text.frame = frame
                layer = text
            case .highlight:
                let highlight = CAShapeLayer()
                highlight.frame = frame
                highlight.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: 14, cornerHeight: 14, transform: nil)
                highlight.fillColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor
                highlight.strokeColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor
                highlight.lineWidth = 5
                layer = highlight
            case .arrow:
                let arrow = CAShapeLayer()
                arrow.frame = CGRect(origin: .zero, size: renderSize)
                let start = CGPoint(x: frame.minX, y: frame.maxY)
                let end = CGPoint(x: frame.maxX, y: frame.minY)
                let path = CGMutablePath()
                path.move(to: start)
                path.addLine(to: end)
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x - 28, y: end.y + 4))
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x - 4, y: end.y + 28))
                arrow.path = path
                arrow.strokeColor = NSColor.systemYellow.cgColor
                arrow.fillColor = NSColor.clear.cgColor
                arrow.lineWidth = 8
                arrow.lineCap = .round
                arrow.lineJoin = .round
                layer = arrow
            case .blur:
                let blur = CALayer()
                blur.frame = frame
                blur.cornerRadius = 16
                blur.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.72).cgColor
                blur.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
                blur.borderWidth = 1
                blur.masksToBounds = true
                layer = blur
            }

            let fade = CAAnimationGroup()
            let opacityIn = CABasicAnimation(keyPath: "opacity")
            opacityIn.fromValue = 0
            opacityIn.toValue = 1
            opacityIn.duration = min(0.18, entry.duration / 3)

            let opacityOut = CABasicAnimation(keyPath: "opacity")
            opacityOut.fromValue = 1
            opacityOut.toValue = 0
            opacityOut.beginTime = max(entry.duration - min(0.18, entry.duration / 3), 0)
            opacityOut.duration = min(0.18, entry.duration / 3)

            fade.animations = [opacityIn, opacityOut]
            fade.duration = entry.duration
            fade.beginTime = AVCoreAnimationBeginTimeAtZero + entry.timelineTime
            fade.isRemovedOnCompletion = false
            fade.fillMode = .both
            layer.opacity = 0
            layer.add(fade, forKey: "visibility")
            parent.addSublayer(layer)
        }
    }

    private static func timelineEntry(
        for effect: VideoDemoOverlayEffect,
        segments: [VideoDemoTimelineSegment]
    ) -> (timelineTime: Double, duration: Double)? {
        guard let segment = segments.first(where: { $0.contains(sourceTime: effect.time) }) else { return nil }
        let timelineTime = segment.timelineTime(forSourceTime: effect.time)
        let maxSourceDuration = max(segment.clip.sourceEnd - effect.time, 0)
        let sourceDuration = min(max(effect.duration, 0.1), maxSourceDuration)
        return (timelineTime, max(sourceDuration / segment.clip.normalizedSpeed, 0.1))
    }

    private static func addCursorLayer(
        to parent: CALayer,
        project: VideoDemoProject,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment],
        duration: Double
    ) {
        let samples = project.cursorSamples.compactMap { sample -> (timelineTime: Double, sample: VideoDemoCursorSample)? in
            guard let timelineTime = project.timelineTimeIfIncluded(sourceTime: sample.time, segments: timelineSegments) else {
                return nil
            }
            return (timelineTime, sample)
        }
        .sorted { $0.timelineTime < $1.timelineTime }
        guard samples.count >= 2, duration > 0 else { return }

        let size = CGFloat(30 * min(max(project.cursorScale, VideoDemoProject.cursorScaleRange.lowerBound), VideoDemoProject.cursorScaleRange.upperBound))
        let values = samples.map {
            project.canvasPoint(for: CGPoint(x: $0.sample.x, y: $0.sample.y), in: renderSize, at: $0.sample.time)
        }
        let keyTimes = samples.map { max(0, min($0.timelineTime / duration, 1)) }

        // Motion-blur trail: faint echoes lag the live cursor, so fast moves smear and slow moves stay crisp.
        if project.cursorMotionBlur {
            let echoes: [(lag: Double, opacity: Float)] = [(0.05, 0.28), (0.10, 0.16)]
            for echo in echoes {
                let layer = makeCursorShapeLayer(size: size)
                layer.opacity = echo.opacity
                let trail = laggedTrail(values: values, keyTimes: keyTimes, lagFraction: echo.lag / max(duration, 0.001))
                guard trail.values.count >= 2 else { continue }
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.values = trail.values.map { NSValue(point: $0) }
                anim.keyTimes = trail.keyTimes.map { NSNumber(value: $0) }
                anim.duration = duration
                anim.beginTime = AVCoreAnimationBeginTimeAtZero
                anim.calculationMode = .linear
                anim.isRemovedOnCompletion = false
                anim.fillMode = .forwards
                layer.position = trail.values.first ?? .zero
                layer.add(anim, forKey: "position")
                parent.addSublayer(layer)
            }
        }

        let cursor = makeCursorShapeLayer(size: size)
        cursor.position = values.first ?? .zero
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = values.map { NSValue(point: $0) }
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = project.smoothCursor ? .paced : .linear
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        cursor.add(animation, forKey: "position")
        parent.addSublayer(cursor)
    }

    private static func makeCursorShapeLayer(size: CGFloat) -> CAShapeLayer {
        let cursor = CAShapeLayer()
        cursor.path = cursorPath(size: size)
        cursor.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        cursor.fillColor = NSColor.white.cgColor
        cursor.strokeColor = NSColor.black.withAlphaComponent(0.65).cgColor
        cursor.lineWidth = 2
        cursor.shadowColor = NSColor.black.cgColor
        cursor.shadowOpacity = 0.28
        cursor.shadowRadius = 8
        cursor.shadowOffset = CGSize(width: 0, height: -4)
        return cursor
    }

    /// Shifts cursor keyframes later in time so an echo layer trails the live cursor by `lagFraction` of the timeline.
    private static func laggedTrail(values: [CGPoint], keyTimes: [Double], lagFraction: Double) -> (values: [CGPoint], keyTimes: [Double]) {
        guard let first = values.first, lagFraction > 0 else { return (values, keyTimes) }
        var outValues: [CGPoint] = [first]
        var outKeyTimes: [Double] = [0]
        for (value, keyTime) in zip(values, keyTimes) {
            let shifted = keyTime + lagFraction
            outValues.append(value)
            if shifted >= 1 {
                outKeyTimes.append(1)
                break
            }
            outKeyTimes.append(shifted)
        }
        return (outValues, outKeyTimes)
    }

    private static func addClickSpotlightLayers(
        to parent: CALayer,
        project: VideoDemoProject,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment],
        duration: Double
    ) {
        guard duration > 0 else { return }
        let radius = max(min(renderSize.width, renderSize.height) * 0.16, 80)
        let hold = 0.7
        for click in project.clickEvents {
            guard let timelineTime = project.timelineTimeIfIncluded(sourceTime: click.time, segments: timelineSegments) else {
                continue
            }
            let point = project.canvasPoint(for: CGPoint(x: click.x, y: click.y), in: renderSize, at: click.time)
            let dim = CAShapeLayer()
            dim.frame = CGRect(origin: .zero, size: renderSize)
            let cover = CGMutablePath()
            cover.addRect(CGRect(origin: .zero, size: renderSize))
            cover.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            dim.path = cover
            dim.fillRule = .evenOdd
            dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.16

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = max(hold - 0.22, 0.16)
            fadeOut.duration = 0.22

            let group = CAAnimationGroup()
            group.animations = [fadeIn, fadeOut]
            group.duration = hold
            group.beginTime = AVCoreAnimationBeginTimeAtZero + max(timelineTime, 0)
            group.isRemovedOnCompletion = false
            group.fillMode = .both
            dim.opacity = 0
            dim.add(group, forKey: "spotlight")
            parent.addSublayer(dim)
        }
    }

    private static func addClickLayers(
        to parent: CALayer,
        project: VideoDemoProject,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment],
        duration: Double
    ) {
        guard duration > 0 else { return }
        for click in project.clickEvents {
            guard let timelineTime = project.timelineTimeIfIncluded(sourceTime: click.time, segments: timelineSegments) else {
                continue
            }
            let point = project.canvasPoint(for: CGPoint(x: click.x, y: click.y), in: renderSize, at: click.time)
            let ripple = CAShapeLayer()
            ripple.frame = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            ripple.path = CGPath(ellipseIn: ripple.bounds, transform: nil)
            ripple.fillColor = NSColor.clear.cgColor
            ripple.strokeColor = NSColor.systemBlue.cgColor
            ripple.lineWidth = 4

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.2
            scale.toValue = 2.2
            scale.duration = 0.55

            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.75
            opacity.toValue = 0
            opacity.duration = 0.55

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 0.55
            group.beginTime = AVCoreAnimationBeginTimeAtZero + max(timelineTime, 0)
            group.isRemovedOnCompletion = false
            group.fillMode = .both
            ripple.opacity = 0
            ripple.add(group, forKey: "click")
            parent.addSublayer(ripple)
        }
    }

    private static func cursorPath(size: CGFloat) -> CGPath {
        let scale = size / 32
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5 * scale, y: 30 * scale))
        path.addLine(to: CGPoint(x: 5 * scale, y: 3 * scale))
        path.addLine(to: CGPoint(x: 23 * scale, y: 21 * scale))
        path.addLine(to: CGPoint(x: 14 * scale, y: 22 * scale))
        path.addLine(to: CGPoint(x: 20 * scale, y: 31 * scale))
        path.addLine(to: CGPoint(x: 16 * scale, y: 33 * scale))
        path.addLine(to: CGPoint(x: 11 * scale, y: 24 * scale))
        path.closeSubpath()
        return path
    }

    private static func seconds(_ time: CMTime) -> Double {
        guard time.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private static func orientedSize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func transform(for track: AVAssetTrack, sourceSize: CGSize, targetRect: CGRect) async throws -> CGAffineTransform {
        let preferred = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: try await track.load(.naturalSize)).applying(preferred)
        let normalize = preferred.concatenating(
            CGAffineTransform(translationX: -transformed.origin.x, y: -transformed.origin.y)
        )
        let scale = min(targetRect.width / max(sourceSize.width, 1), targetRect.height / max(sourceSize.height, 1))
        return normalize
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))
    }

    private final class AssetExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }
}

@MainActor
final class VideoDemoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [VideoDemoEditorWindowController] = []
    private let model: VideoDemoEditorViewModel
    private let sourceURL: URL

    static var hasOpenEditors: Bool { !openControllers.isEmpty }

    static func open(videoURL: URL) {
        let sourceURL = canonicalVideoURL(videoURL)
        if let existing = openControllers.first(where: { $0.sourceURL == sourceURL }) {
            existing.bringEditorToFront()
            return
        }

        let controller = VideoDemoEditorWindowController(videoURL: sourceURL)
        openControllers.append(controller)
        controller.bringEditorToFront()
    }

    static func bringOpenEditorsToFront() {
        guard !openControllers.isEmpty else { return }
        openControllers.forEach { $0.bringEditorToFront() }
    }

    /// Keeps the Dock icon / ⌘-Tab entry in sync across both editors so the user can always
    /// return to this window even after switching apps. See `ShotnixEditorActivation`.
    private static func syncActivationPolicy() {
        ShotnixEditorActivation.sync()
    }

    static func splitActiveEditor() {
        frontController()?.model.splitAtPlayhead()
    }

    static func deleteActiveSelection() {
        frontController()?.model.deleteSelectedClip()
    }

    static func trimActiveInToPlayhead() {
        frontController()?.model.trimSelectedClipStartToPlayhead()
    }

    static func trimActiveOutToPlayhead() {
        frontController()?.model.trimSelectedClipEndToPlayhead()
    }

    static func muteActiveClip() {
        guard let model = frontController()?.model,
              let selectedClipID = model.selectedClipID else { return }
        model.toggleClipMuted(id: selectedClipID)
    }

    static func undoActiveTimelineEdit() {
        frontController()?.model.undoTimelineEdit()
    }

    static func redoActiveTimelineEdit() {
        frontController()?.model.redoTimelineEdit()
    }

    private static func frontController() -> VideoDemoEditorWindowController? {
        openControllers.first(where: { $0.window?.isKeyWindow == true })
            ?? openControllers.first(where: { $0.window?.isVisible == true })
            ?? openControllers.last
    }

    init(videoURL: URL) {
        let sourceURL = Self.canonicalVideoURL(videoURL)
        self.sourceURL = sourceURL
        var project = VideoDemoProject.make(sourceURL: sourceURL)
        if let sidecar = VideoDemoSidecarStore.load(for: sourceURL) {
            project.apply(metadata: sidecar)
        }
        let model = VideoDemoEditorViewModel(project: project)
        self.model = model

        let content = VideoDemoEditorView(model: model)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video Demo Editor"
        window.contentView = hostingView
        window.minSize = NSSize(width: 1060, height: 680)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ShotnixColors.editorStageTop
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenAuxiliary]
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        Task { await model.loadMetadata() }
    }

    func windowWillClose(_ notification: Notification) {
        model.flushAutosave()
        model.stop()
        Self.openControllers.removeAll { $0 === self }
        Self.syncActivationPolicy()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
        Self.openControllers.append(self)
    }

    private static func canonicalVideoURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func bringEditorToFront() {
        guard let window else { return }
        NSApp.unhide(nil)
        Self.syncActivationPolicy()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.deminiaturize(nil)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window, window.isVisible else { return }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class VideoDemoEditorViewModel: ObservableObject {
    @Published var project: VideoDemoProject {
        didSet {
            scheduleAutosave()
        }
    }
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportDestinationURL: URL?
    @Published var exportCompletedURL: URL?
    @Published var exportErrorMessage: String?
    @Published var status = "Ready"
    @Published var autosaveStatus = "Draft saved"
    @Published var restoredDraftNotice: String?
    @Published var isCommandPalettePresented = false
    @Published var recentExports: [VideoDemoRecentExport] = []
    @Published var sourceSize: CGSize = .zero
    @Published var selectedZoomID: UUID?
    @Published var selectedClipID: UUID?
    @Published var selectedEffectID: UUID?
    @Published var timelineThumbnails: [VideoTimelineThumbnail] = []
    @Published var selectedTimelineRange: VideoDemoTimelineRange?
    @Published var timelineEditFlash: VideoDemoTimelineRange?
    @Published var timelineZoom: Double = 1

    let player: AVPlayer
    private var didLoadMetadata = false
    private var timeObserver: Any?
    private var undoSnapshots: [VideoDemoProject] = []
    private var redoSnapshots: [VideoDemoProject] = []
    private var timelineTrimUndoActive = false
    private var autosaveWorkItem: DispatchWorkItem?
    private var suppressAutosave = false
    fileprivate var exportCancellationRequested = false

    init(project: VideoDemoProject) {
        self.project = project
        self.selectedClipID = project.timelineClips.first?.id
        self.player = AVPlayer(url: project.sourceURL)
        self.recentExports = VideoDemoRecentExportStore.load(for: project.sourceURL)
        addTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func loadMetadata() async {
        guard !didLoadMetadata else { return }
        didLoadMetadata = true

        do {
            suppressAutosave = true
            let metadata = try await VideoDemoExporter.metadata(for: project.sourceURL)
            duration = metadata.duration
            sourceSize = metadata.sourceSize

            if let draft = VideoDemoDraftStore.load(for: project.sourceURL),
               draft.sourcePath == project.sourceURL.standardizedFileURL.path {
                project = draft.project
                restoredDraftNotice = "Draft restored"
                status = "Draft restored"
            } else if let sidecar = VideoDemoSidecarStore.load(for: project.sourceURL) {
                project.apply(metadata: sidecar)
            }
            project.sourceWidth = Double(metadata.sourceSize.width)
            project.sourceHeight = Double(metadata.sourceSize.height)
            if project.trimEnd <= 0 || project.trimEnd > metadata.duration {
                project.trimEnd = metadata.duration
            }
            project.ensureTimeline(totalDuration: metadata.duration)
            selectedClipID = project.timelineClips.first?.id
            seekToTimeline(0)
            recentExports = VideoDemoRecentExportStore.load(for: project.sourceURL)
            suppressAutosave = false
            saveDraftNow()
            await loadTimelineThumbnails()
        } catch {
            suppressAutosave = false
            exportErrorMessage = error.localizedDescription
            status = error.localizedDescription
        }
    }

    func setTrimStart(_ value: Double) {
        project.setSingleTrim(start: value, end: project.trimEnd, totalDuration: duration)
        selectedClipID = project.timelineClips.first?.id
        seek(to: project.trimStart)
    }

    func setTrimEnd(_ value: Double) {
        project.setSingleTrim(start: project.trimStart, end: value, totalDuration: duration)
    }

    func seek(to seconds: Double) {
        let safe = min(max(seconds, 0), max(duration, 0))
        currentTime = safe
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToTimeline(_ seconds: Double, snapping: Bool = false, snapThreshold: Double? = nil) {
        let target = snapping ? snappedTimelineTime(seconds, threshold: snapThreshold) : seconds
        let safe = min(max(target, 0), max(timelineDuration, 0))
        if let segment = timelineSegments.first(where: { $0.contains(timelineTime: safe) }) {
            selectedClipID = segment.id
        }
        seek(to: project.sourceTime(forTimelineTime: safe, totalDuration: duration))
    }

    func playPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            let current = CMTimeGetSeconds(player.currentTime())
            let editedDuration = timelineDuration
            let timeline = project.timelineTime(forSourceTime: current, totalDuration: duration)
            if editedDuration <= 0 {
                return
            }
            if current >= (timelineSegments.last?.clip.sourceEnd ?? 0) || project.timelineTimeIfIncluded(sourceTime: current, totalDuration: duration) == nil {
                seekToTimeline(timeline >= editedDuration - 0.05 ? 0 : timeline)
            }
            player.play()
            updatePlaybackRate()
        }
    }

    func stop() {
        player.pause()
    }

    func applyPreset(_ preset: VideoDemoExportPreset) {
        project.apply(preset: preset)
    }

    func setAspectPreset(_ preset: VideoDemoProject.AspectPreset) {
        project.apply(aspectPreset: preset)
    }

    var timelineSegments: [VideoDemoTimelineSegment] {
        project.timelineSegments(totalDuration: duration)
    }

    var timelineDuration: Double {
        project.timelineDuration(totalDuration: duration)
    }

    var timelineTime: Double {
        project.timelineTime(forSourceTime: currentTime, totalDuration: duration)
    }

    var selectedSegment: VideoDemoTimelineSegment? {
        if let selectedClipID,
           let segment = timelineSegments.first(where: { $0.id == selectedClipID }) {
            return segment
        }
        return timelineSegments.first
    }

    var canDeleteSelectedClip: Bool {
        selectedTimelineRange != nil || (selectedClipID != nil && timelineSegments.count > 1)
    }

    var canUndoTimelineEdit: Bool {
        !undoSnapshots.isEmpty
    }

    var canRedoTimelineEdit: Bool {
        !redoSnapshots.isEmpty
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        selectedZoomID = nil
        selectedEffectID = nil
        selectedTimelineRange = nil
    }

    func selectZoom(_ id: UUID) {
        selectedZoomID = id
        selectedEffectID = nil
        selectedTimelineRange = nil
    }

    func selectEffect(_ id: UUID) {
        selectedEffectID = id
        selectedZoomID = nil
        selectedTimelineRange = nil
    }

    func setTimelineSelection(start: Double, end: Double) {
        let safeStart = snappedTimelineTime(start)
        let safeEnd = snappedTimelineTime(end)
        let range = VideoDemoTimelineRange(
            start: min(max(safeStart, 0), max(timelineDuration, 0)),
            end: min(max(safeEnd, 0), max(timelineDuration, 0))
        ).normalized
        guard range.duration >= VideoDemoProject.minimumClipDuration else {
            selectedTimelineRange = nil
            return
        }
        selectedTimelineRange = range
        if let segment = timelineSegments.first(where: { $0.contains(timelineTime: range.start) }) {
            selectedClipID = segment.id
        }
        status = "Range \(timeLabel(range.duration))"
    }

    func clearTimelineSelection() {
        selectedTimelineRange = nil
    }

    func deleteSelectedTimelineRange() {
        guard let range = selectedTimelineRange?.normalized else { return }
        pushUndo()
        guard let nextID = project.deleteTimelineRange(start: range.start, end: range.end, totalDuration: duration) else {
            undoSnapshots.removeLast()
            status = "Keep at least one clip."
            return
        }
        selectedTimelineRange = nil
        selectedClipID = nextID
        flashTimelineRange(range)
        seekToTimeline(min(range.start, max(timelineDuration - 0.001, 0)))
        status = "Range removed"
        ToastWindow.show(message: "Range removed. Press Cmd-Z to undo.", duration: 2.4)
    }

    func splitAtPlayhead() {
        selectedTimelineRange = nil
        let timelineBeforeSplit = timelineTime
        pushUndo()
        if let newClipID = project.splitClip(atSourceTime: currentTime, totalDuration: duration) {
            selectedClipID = newClipID
            flashTimelineRange(VideoDemoTimelineRange(start: max(timelineBeforeSplit - 0.08, 0), end: min(timelineBeforeSplit + 0.08, timelineDuration)))
            status = "Split at \(timeLabel(currentTime))"
        } else {
            undoSnapshots.removeLast()
            status = "Move inside a clip to split."
        }
    }

    func deleteSelectedClip() {
        if selectedTimelineRange != nil {
            deleteSelectedTimelineRange()
            return
        }
        guard let selectedClipID else { return }
        deleteClip(id: selectedClipID, timelineAnchor: timelineTime)
    }

    func deleteClip(id: UUID, timelineAnchor: Double? = nil) {
        selectedClipID = id
        let timelineBeforeDelete = timelineAnchor ?? timelineSegments.first(where: { $0.id == id })?.timelineStart ?? timelineTime
        pushUndo()
        guard let nextID = project.deleteClip(id: id, totalDuration: duration) else {
            undoSnapshots.removeLast()
            status = "Keep at least one clip."
            return
        }
        self.selectedClipID = nextID
        flashTimelineRange(VideoDemoTimelineRange(start: timelineBeforeDelete, end: min(timelineBeforeDelete + 0.22, timelineDuration)))
        seekToTimeline(min(timelineBeforeDelete, max(timelineDuration - 0.001, 0)))
        status = "Clip removed"
        ToastWindow.show(message: "Clip removed. Press Cmd-Z to undo.", duration: 2.4)
    }

    func undoTimelineEdit() {
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(project)
        project = previous
        selectedTimelineRange = nil
        selectedClipID = project.timelineClips.first?.id
        seekToTimeline(min(timelineTime, max(timelineDuration - 0.001, 0)))
        status = "Undo"
    }

    func redoTimelineEdit() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(project)
        project = next
        selectedTimelineRange = nil
        selectedClipID = project.timelineClips.first?.id
        seekToTimeline(min(timelineTime, max(timelineDuration - 0.001, 0)))
        status = "Redo"
    }

    func setSelectedClipStart(_ value: Double) {
        guard let selectedClipID else { return }
        setClipStart(id: selectedClipID, sourceStart: value, seekToBoundary: true)
    }

    func setSelectedClipEnd(_ value: Double) {
        guard let selectedClipID else { return }
        setClipEnd(id: selectedClipID, sourceEnd: value, seekToBoundary: currentTime > value)
    }

    func beginTimelineTrim() {
        guard !timelineTrimUndoActive else { return }
        pushUndo()
        timelineTrimUndoActive = true
    }

    func finishTimelineTrim() {
        guard timelineTrimUndoActive else { return }
        timelineTrimUndoActive = false
        status = "Clip trimmed"
    }

    func setClipStart(id: UUID, sourceStart: Double, seekToBoundary: Bool) {
        selectedClipID = id
        guard project.trimClip(id: id, sourceStart: sourceStart, totalDuration: duration) else { return }
        if seekToBoundary, let segment = timelineSegments.first(where: { $0.id == id }) {
            seek(to: segment.clip.sourceStart)
        }
    }

    func setClipEnd(id: UUID, sourceEnd: Double, seekToBoundary: Bool) {
        selectedClipID = id
        guard project.trimClip(id: id, sourceEnd: sourceEnd, totalDuration: duration) else { return }
        if currentTime > (selectedSegment?.clip.sourceEnd ?? currentTime) {
            seek(to: selectedSegment?.clip.sourceEnd ?? currentTime)
        } else if seekToBoundary, let segment = timelineSegments.first(where: { $0.id == id }) {
            seek(to: segment.clip.sourceEnd)
        }
    }

    func setSelectedClipSpeed(_ value: Double) {
        guard let selectedClipID else { return }
        setClipSpeed(id: selectedClipID, value: value)
    }

    func setClipSpeed(id: UUID, value: Double) {
        selectedClipID = id
        selectedTimelineRange = nil
        pushUndo()
        _ = project.updateClip(id: id, totalDuration: duration) { clip in
            clip.speed = value
        }
        updatePlaybackRate()
        status = "Speed \(String(format: "%.1fx", value))"
    }

    func setSelectedClipMuted(_ value: Bool) {
        guard let selectedClipID else { return }
        setClipMuted(id: selectedClipID, value: value)
    }

    func setClipMuted(id: UUID, value: Bool) {
        selectedClipID = id
        selectedTimelineRange = nil
        pushUndo()
        _ = project.updateClip(id: id, totalDuration: duration) { clip in
            clip.muted = value
        }
        status = value ? "Clip muted" : "Clip unmuted"
    }

    func toggleClipMuted(id: UUID) {
        guard let clip = timelineSegments.first(where: { $0.id == id })?.clip else { return }
        setClipMuted(id: id, value: !clip.muted)
    }

    func trimSelectedClipStartToPlayhead() {
        guard let selectedClipID,
              let segment = selectedSegment,
              segment.contains(timelineTime: timelineTime) else {
            status = "Move playhead inside the selected clip."
            return
        }
        pushUndo()
        setClipStart(id: selectedClipID, sourceStart: segment.sourceTime(forTimelineTime: timelineTime), seekToBoundary: true)
        status = "In point set"
    }

    func trimSelectedClipEndToPlayhead() {
        guard let selectedClipID,
              let segment = selectedSegment,
              segment.contains(timelineTime: timelineTime) else {
            status = "Move playhead inside the selected clip."
            return
        }
        pushUndo()
        setClipEnd(id: selectedClipID, sourceEnd: segment.sourceTime(forTimelineTime: timelineTime), seekToBoundary: true)
        status = "Out point set"
    }

    func setSelectedClipFadeIn(_ value: Double) {
        guard let selectedClipID else { return }
        _ = project.updateClip(id: selectedClipID, totalDuration: duration) { clip in
            clip.fadeIn = value
        }
    }

    func setSelectedClipFadeOut(_ value: Double) {
        guard let selectedClipID else { return }
        _ = project.updateClip(id: selectedClipID, totalDuration: duration) { clip in
            clip.fadeOut = value
        }
    }

    func addZoom() {
        let sourceTime = project.timelineTimeIfIncluded(sourceTime: currentTime, totalDuration: duration) == nil
            ? project.sourceTime(forTimelineTime: timelineTime, totalDuration: duration)
            : currentTime
        pushUndo()
        let keyframe = VideoDemoZoomKeyframe(time: sourceTime)
        project.zoomKeyframes.append(keyframe)
        project.zoomKeyframes.sort { $0.time < $1.time }
        selectZoom(keyframe.id)
        status = "Zoom keyframe added"
    }

    func addAutoZoomPreset() {
        let segments = timelineSegments
        guard !segments.isEmpty else { return }
        let editedDuration = max(timelineDuration, 0.1)
        let targets = Array(autoZoomTargets().prefix(6))

        pushUndo()
        project.zoomKeyframes.removeAll()
        var generated: [VideoDemoZoomKeyframe] = []
        appendAutoZoomKeyframe(&generated, timelineTime: 0, scale: 1, focusX: 0.5, focusY: 0.5)

        if targets.isEmpty {
            let midpoint = editedDuration * 0.45
            appendAutoZoomKeyframe(&generated, timelineTime: max(midpoint - 0.85, 0), scale: 1.02, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: midpoint, scale: 1.42, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: min(midpoint + 1.55, editedDuration), scale: 1.42, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: min(midpoint + 2.25, editedDuration), scale: 1, focusX: 0.5, focusY: 0.5)
        } else {
            var previousExit = 0.0
            for index in targets.indices {
                let target = targets[index]
                let nextTargetTime = targets.indices.contains(index + 1) ? targets[index + 1].timelineTime : nil
                let gapBefore = max(target.timelineTime - previousExit, 0)
                let lead = min(0.9, max(0.42, gapBefore * 0.36))
                let approachTime = max(previousExit, target.timelineTime - lead)
                let arrivalTime = max(approachTime + 0.18, target.timelineTime - 0.08)
                let nextGap = (nextTargetTime ?? editedDuration) - target.timelineTime
                let holdEnd = min(
                    target.timelineTime + (nextGap < 1.65 ? max(0.28, nextGap * 0.34) : 0.92),
                    editedDuration
                )

                appendAutoZoomKeyframe(&generated, timelineTime: approachTime, scale: index == 0 || gapBefore > 1.8 ? 1 : 1.34, focusX: target.focusX, focusY: target.focusY)
                appendAutoZoomKeyframe(&generated, timelineTime: arrivalTime, scale: target.scale, focusX: target.focusX, focusY: target.focusY)
                appendAutoZoomKeyframe(&generated, timelineTime: holdEnd, scale: target.scale, focusX: target.focusX, focusY: target.focusY)

                if nextGap > 2.05 || nextTargetTime == nil {
                    let settleTime = min(holdEnd + 0.72, editedDuration)
                    let returnTime = min(settleTime + 0.68, editedDuration)
                    appendAutoZoomKeyframe(&generated, timelineTime: settleTime, scale: 1.22, focusX: target.focusX, focusY: target.focusY)
                    appendAutoZoomKeyframe(&generated, timelineTime: returnTime, scale: 1, focusX: 0.5, focusY: 0.5)
                    previousExit = returnTime
                } else {
                    previousExit = holdEnd
                }
            }
        }

        project.zoomKeyframes = normalizedAutoZoomKeyframes(generated)
        if let id = project.zoomKeyframes.first?.id {
            selectZoom(id)
        }
        status = targets.isEmpty ? "Smooth zoom applied" : "Smooth auto zoom applied"
    }

    private struct AutoZoomTarget {
        let timelineTime: Double
        let focusX: Double
        let focusY: Double
        let scale: Double
    }

    private func autoZoomTargets() -> [AutoZoomTarget] {
        let clicks = project.clickEvents.compactMap { click -> (timelineTime: Double, x: Double, y: Double)? in
            guard let timelineTime = project.timelineTimeIfIncluded(sourceTime: click.time, totalDuration: duration) else { return nil }
            let sample = cursorSample(at: click.time)
            return (timelineTime, sample?.x ?? click.x, sample?.y ?? click.y)
        }
        .sorted { $0.timelineTime < $1.timelineTime }

        guard !clicks.isEmpty else { return [] }

        var clusters: [[(timelineTime: Double, x: Double, y: Double)]] = []
        for click in clicks {
            if let last = clusters.indices.last,
               let previous = clusters[last].last,
               click.timelineTime - previous.timelineTime <= 1.35 {
                clusters[last].append(click)
            } else {
                clusters.append([click])
            }
        }

        return clusters.compactMap { cluster in
            guard !cluster.isEmpty else { return nil }
            let count = Double(cluster.count)
            let timelineTime = cluster.map(\.timelineTime).reduce(0, +) / count
            let x = cluster.map(\.x).reduce(0, +) / count
            let y = cluster.map(\.y).reduce(0, +) / count
            return AutoZoomTarget(
                timelineTime: timelineTime,
                focusX: softenedFocus(x),
                focusY: softenedFocus(y),
                scale: cluster.count > 1 ? 1.74 : 1.66
            )
        }
    }

    private func appendAutoZoomKeyframe(
        _ keyframes: inout [VideoDemoZoomKeyframe],
        timelineTime: Double,
        scale: Double,
        focusX: Double,
        focusY: Double
    ) {
        let safeTimeline = min(max(timelineTime, 0), max(timelineDuration, 0))
        keyframes.append(VideoDemoZoomKeyframe(
            time: project.sourceTime(forTimelineTime: safeTimeline, totalDuration: duration),
            scale: scale,
            focusX: focusX,
            focusY: focusY
        ))
    }

    private func normalizedAutoZoomKeyframes(_ keyframes: [VideoDemoZoomKeyframe]) -> [VideoDemoZoomKeyframe] {
        let sorted = keyframes.sorted { $0.time < $1.time }
        var normalized: [VideoDemoZoomKeyframe] = []
        for keyframe in sorted {
            if let last = normalized.last, keyframe.time - last.time < 0.08 {
                normalized[normalized.count - 1] = keyframe
            } else {
                normalized.append(keyframe)
            }
        }
        return normalized
    }

    private func softenedFocus(_ value: Double) -> Double {
        min(max(0.5 + (value - 0.5) * 0.78, 0.16), 0.84)
    }

    func deleteSelectedZoom() {
        guard let selectedZoomID else { return }
        pushUndo()
        project.zoomKeyframes.removeAll { $0.id == selectedZoomID }
        self.selectedZoomID = project.zoomKeyframes.first?.id
        status = "Zoom removed"
        ToastWindow.show(message: "Zoom removed. Press Cmd-Z to undo.", duration: 2.4)
    }

    func moveZoom(id: UUID, toTimelineTime timelineTime: Double) {
        guard let index = project.zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let safeTimeline = min(max(timelineTime, 0), max(timelineDuration, 0))
        let sourceTime = project.sourceTime(forTimelineTime: safeTimeline, totalDuration: duration)
        project.zoomKeyframes[index] = VideoDemoZoomKeyframe(
            id: id,
            time: sourceTime,
            scale: project.zoomKeyframes[index].scale,
            focusX: project.zoomKeyframes[index].focusX,
            focusY: project.zoomKeyframes[index].focusY
        )
        project.zoomKeyframes.sort { $0.time < $1.time }
        selectZoom(id)
        seekToTimeline(safeTimeline)
        status = "Zoom moved"
    }

    func selectedZoomBinding() -> Binding<VideoDemoZoomKeyframe>? {
        guard let selectedZoomID,
              let index = project.zoomKeyframes.firstIndex(where: { $0.id == selectedZoomID }) else { return nil }
        return Binding(
            get: { self.project.zoomKeyframes[index] },
            set: { updated in
                self.project.zoomKeyframes[index] = VideoDemoZoomKeyframe(
                    id: updated.id,
                    time: min(max(updated.time, 0), max(self.duration, 0)),
                    scale: updated.scale,
                    focusX: updated.focusX,
                    focusY: updated.focusY
                )
                self.project.zoomKeyframes.sort { $0.time < $1.time }
            }
        )
    }

    func addEffect(_ kind: VideoDemoOverlayEffectKind) {
        let sourceTime = project.timelineTimeIfIncluded(sourceTime: currentTime, totalDuration: duration) == nil
            ? project.sourceTime(forTimelineTime: timelineTime, totalDuration: duration)
            : currentTime
        pushUndo()
        let effect = VideoDemoOverlayEffect(
            kind: kind,
            time: sourceTime,
            duration: kind == .blur ? 3 : 2,
            x: kind == .arrow ? 0.36 : 0.34,
            y: kind == .arrow ? 0.62 : 0.32,
            width: kind == .arrow ? 0.22 : 0.32,
            height: kind == .text ? 0.10 : 0.18,
            text: kind == .text ? "Important" : kind.title
        )
        project.overlayEffects.append(effect)
        selectEffect(effect.id)
        status = "\(kind.title) added"
    }

    func deleteSelectedEffect() {
        guard let selectedEffectID else { return }
        pushUndo()
        project.overlayEffects.removeAll { $0.id == selectedEffectID }
        self.selectedEffectID = project.overlayEffects.first?.id
        status = "Effect removed"
        ToastWindow.show(message: "Effect removed. Press Cmd-Z to undo.", duration: 2.4)
    }

    func selectedEffectBinding() -> Binding<VideoDemoOverlayEffect>? {
        guard let selectedEffectID,
              let index = project.overlayEffects.firstIndex(where: { $0.id == selectedEffectID }) else { return nil }
        return Binding(
            get: { self.project.overlayEffects[index] },
            set: { updated in
                self.project.overlayEffects[index] = VideoDemoOverlayEffect(
                    id: updated.id,
                    kind: updated.kind,
                    time: min(max(updated.time, 0), max(self.duration, 0)),
                    duration: min(max(updated.duration, 0.2), max(self.duration, 0.2)),
                    x: min(max(updated.x, 0.02), 0.92),
                    y: min(max(updated.y, 0.02), 0.92),
                    width: min(max(updated.width, 0.04), 0.9),
                    height: min(max(updated.height, 0.04), 0.6),
                    text: updated.text
                )
                self.project.overlayEffects.sort { $0.time < $1.time }
            }
        )
    }

    func cursorSample(at time: Double) -> VideoDemoCursorSample? {
        let samples = project.cursorSamples
        guard !samples.isEmpty else { return nil }
        if !project.smoothCursor {
            return samples.min { abs($0.time - time) < abs($1.time - time) }
        }
        guard let previous = samples.last(where: { $0.time <= time }) else { return samples.first }
        guard let next = samples.first(where: { $0.time >= time }) else { return previous }
        let distance = max(next.time - previous.time, 0.001)
        let linearProgress = min(max((time - previous.time) / distance, 0), 1)
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        return VideoDemoCursorSample(
            time: time,
            x: previous.x + (next.x - previous.x) * progress,
            y: previous.y + (next.y - previous.y) * progress
        )
    }

    func activeClicks(at time: Double) -> [(event: VideoDemoClickEvent, progress: Double)] {
        project.clickEvents.compactMap { event in
            let progress = (time - event.time) / 0.62
            guard progress >= 0, progress <= 1 else { return nil }
            return (event, progress)
        }
    }

    func activeEffects(at time: Double) -> [VideoDemoOverlayEffect] {
        project.overlayEffectsActive(at: time)
    }

    func setTimelineZoom(_ value: Double) {
        timelineZoom = min(max(value, 1), 6)
    }

    func nudgeTimelineZoom(_ delta: Double) {
        setTimelineZoom(timelineZoom + delta)
    }

    func snappedTimelineTime(_ time: Double, threshold: Double? = nil) -> Double {
        let safe = min(max(time, 0), max(timelineDuration, 0))
        let snapThreshold = threshold ?? max(0.045, timelineDuration * 0.008)
        guard snapThreshold > 0 else { return safe }

        let nearest = timelineSnapPoints()
            .map { point in (point: point, distance: abs(point - safe)) }
            .min { $0.distance < $1.distance }

        guard let nearest, nearest.distance <= snapThreshold else { return safe }
        return min(max(nearest.point, 0), max(timelineDuration, 0))
    }

    func timelineSnapPoints() -> [Double] {
        var points: [Double] = [0, timelineDuration]
        points.append(contentsOf: timelineSegments.flatMap { [$0.timelineStart, $0.timelineEnd] })
        points.append(contentsOf: project.clickEvents.compactMap { project.timelineTimeIfIncluded(sourceTime: $0.time, totalDuration: duration) })
        points.append(contentsOf: project.zoomKeyframes.compactMap { project.timelineTimeIfIncluded(sourceTime: $0.time, totalDuration: duration) })
        points.append(contentsOf: project.overlayEffects.flatMap { effect -> [Double] in
            let start = project.timelineTimeIfIncluded(sourceTime: effect.time, totalDuration: duration)
            let end = project.timelineTimeIfIncluded(sourceTime: effect.time + effect.duration, totalDuration: duration)
            return [start, end].compactMap { $0 }
        })
        return Array(Set(points.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }

    func handleEditorShortcut(_ event: NSEvent) -> Bool {
        guard !isExporting else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if isCommandPalettePresented, event.keyCode == 53 {
            isCommandPalettePresented = false
            return true
        }

        if modifiers == [.command], key == "z" {
            undoTimelineEdit()
            return true
        }

        if modifiers == [.command], key == "k" {
            isCommandPalettePresented = true
            return true
        }

        if modifiers == [.command, .shift], key == "z" {
            redoTimelineEdit()
            return true
        }

        guard modifiers.isEmpty else { return false }

        if event.characters == "?" {
            isCommandPalettePresented = true
            return true
        }

        switch key {
        case " ":
            playPause()
            return true
        case "s":
            splitAtPlayhead()
            return true
        case "i":
            trimSelectedClipStartToPlayhead()
            return true
        case "o":
            trimSelectedClipEndToPlayhead()
            return true
        case "m":
            if let selectedClipID {
                toggleClipMuted(id: selectedClipID)
                return true
            }
            return false
        case "[":
            seekToTimeline(timelineTime - 0.25)
            return true
        case "]":
            seekToTimeline(timelineTime + 0.25)
            return true
        default:
            break
        }

        switch event.keyCode {
        case 53:
            clearTimelineSelection()
            return true
        case 51, 117:
            deleteSelectedClip()
            return true
        case 123:
            seekToTimeline(timelineTime - 0.25)
            return true
        case 124:
            seekToTimeline(timelineTime + 0.25)
            return true
        default:
            return false
        }
    }

    private func flashTimelineRange(_ range: VideoDemoTimelineRange) {
        let normalized = range.normalized
        timelineEditFlash = normalized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.timelineEditFlash == normalized else { return }
            self.timelineEditFlash = nil
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.customBackgroundPath = url.path
    }

    func clearBackgroundImage() {
        project.customBackgroundPath = ""
    }

    func revealSource() {
        NSWorkspace.shared.activateFileViewerSelecting([project.sourceURL])
    }

    func revealExport(_ export: VideoDemoRecentExport) {
        NSWorkspace.shared.activateFileViewerSelecting([export.exportURL])
    }

    func revealCompletedExport() {
        guard let exportCompletedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportCompletedURL])
    }

    func copySourcePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.sourceURL.path, forType: .string)
        ToastWindow.show(message: "Video path copied.")
    }

    func copyCompletedExportPath() {
        guard let exportCompletedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportCompletedURL.path, forType: .string)
        ToastWindow.show(message: "Export path copied.")
    }

    func cancelExport() {
        guard isExporting else { return }
        exportCancellationRequested = true
        status = "Cancelling export..."
    }

    func export() async {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Shotnix Demo \(ImageExporter.timestampedName).mp4"
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        exportCancellationRequested = false
        exportProgress = 0.02
        exportDestinationURL = destination
        exportCompletedURL = nil
        exportErrorMessage = nil
        status = "Exporting..."
        let exportBridge = VideoDemoExportBridge(self)
        do {
            try await VideoDemoExporter.export(
                project: project,
                destinationURL: destination,
                progress: { value in
                    await exportBridge.setProgress(value)
                },
                shouldCancel: {
                    await exportBridge.shouldCancel()
                }
            )
            exportProgress = 1
            exportCompletedURL = destination
            recentExports = VideoDemoRecentExportStore.add(exportURL: destination, sourceURL: project.sourceURL)
            status = "Exported \(destination.lastPathComponent)"
            ToastWindow.show(message: "Video exported: \(destination.lastPathComponent)", duration: 3.0)
        } catch {
            let message = exportCancellationRequested ? "Export cancelled." : error.localizedDescription
            exportErrorMessage = message
            status = message
            ToastWindow.show(message: message)
        }
        isExporting = false
        exportCancellationRequested = false
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                self.skipCutSegmentsIfNeeded(sourceTime: seconds)
                self.updatePlaybackRate()
            }
        }
    }

    private func skipCutSegmentsIfNeeded(sourceTime: Double) {
        guard player.timeControlStatus == .playing else { return }
        let segments = timelineSegments
        guard !segments.isEmpty else {
            player.pause()
            return
        }

        guard let index = segments.firstIndex(where: { sourceTime >= $0.clip.sourceStart && sourceTime <= $0.clip.sourceEnd }) else {
            seekToTimeline(project.timelineTime(forSourceTime: sourceTime, totalDuration: duration))
            return
        }

        let segment = segments[index]
        guard sourceTime >= segment.clip.sourceEnd - 0.015 else { return }
        if index + 1 < segments.count {
            seek(to: segments[index + 1].clip.sourceStart)
        } else {
            player.pause()
            seek(to: segment.clip.sourceEnd)
        }
    }

    private func updatePlaybackRate() {
        guard player.timeControlStatus == .playing else { return }
        let speed = timelineSegments.first(where: { $0.contains(sourceTime: currentTime) })?.clip.normalizedSpeed ?? 1
        player.rate = Float(speed)
    }

    private func pushUndo() {
        undoSnapshots.append(project)
        redoSnapshots.removeAll()
    }

    func flushAutosave() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        saveDraftNow()
    }

    private func scheduleAutosave() {
        guard didLoadMetadata, !suppressAutosave else { return }
        autosaveWorkItem?.cancel()
        autosaveStatus = "Saving draft"

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveDraftNow()
            }
        }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
    }

    private func saveDraftNow() {
        guard didLoadMetadata, !suppressAutosave else { return }
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveStatus = VideoDemoDraftStore.save(project, for: project.sourceURL) ? "Draft saved" : "Draft save failed"
    }

    private func timeLabel(_ value: Double) -> String {
        let safe = max(value, 0)
        let minutes = Int(safe) / 60
        let seconds = Int(safe) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadTimelineThumbnails() async {
        let sourceURL = project.sourceURL
        let duration = self.duration
        guard duration > 0 else { return }

        let thumbnails = await Task.detached(priority: .utility) { () -> [VideoTimelineThumbnail] in
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 220, height: 124)
            let count = min(max(Int(duration / 3), 5), 10)
            return (0..<count).compactMap { index in
                let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
                let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                return VideoTimelineThumbnail(time: CMTimeGetSeconds(time), image: NSImage(cgImage: cgImage, size: .zero))
            }
        }.value

        timelineThumbnails = thumbnails
    }
}

private final class VideoDemoExportBridge: @unchecked Sendable {
    @MainActor private weak var model: VideoDemoEditorViewModel?

    @MainActor
    init(_ model: VideoDemoEditorViewModel) {
        self.model = model
    }

    @MainActor
    func setProgress(_ value: Double) {
        model?.exportProgress = min(max(value, 0), 1)
    }

    @MainActor
    func shouldCancel() -> Bool {
        model?.exportCancellationRequested ?? false
    }
}

private struct VideoDemoEditorView: View {
    @StateObject private var model: VideoDemoEditorViewModel

    init(model: VideoDemoEditorViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                previewPane
                inspector
            }

            if model.isCommandPalettePresented {
                VideoDemoCommandPalette(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(Color(nsColor: ShotnixColors.editorStageTop))
        .background(VideoDemoKeyboardShortcutBridge(model: model).frame(width: 0, height: 0))
        .task { await model.loadMetadata() }
    }

    private var previewPane: some View {
        VStack(spacing: 12) {
            header
            if let notice = model.restoredDraftNotice {
                draftNotice(notice)
                    .padding(.horizontal, 28)
            }
            VideoDemoStageView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
            transport
            VideoDemoTimelineView(model: model)
                .frame(height: 178)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Shotnix Video")
                    .font(.system(size: 15, weight: .bold))
                Text(model.project.sourceURL.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                model.revealSource()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Reveal video")

            Button {
                model.copySourcePath()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Copy path")

            Text(model.status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 210, alignment: .trailing)
        }
        .padding(.horizontal, 30)
    }

    private func draftNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Color.green)
            Text(message)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.88))
            Text(model.autosaveStatus)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.restoredDraftNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        )
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                model.playPause()
            } label: {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(timeLabel(model.timelineTime))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Slider(value: Binding(get: { model.timelineTime }, set: { model.seekToTimeline($0) }), in: 0...max(model.timelineDuration, 0.1))
                .frame(maxWidth: 260)

            Text(timeLabel(model.timelineDuration))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                model.nudgeTimelineZoom(-0.5)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(model.timelineZoom <= 1.01)
            .foregroundStyle(model.timelineZoom <= 1.01 ? Color.secondary.opacity(0.45) : Color.white.opacity(0.86))

            Slider(
                value: Binding(get: { model.timelineZoom }, set: { model.setTimelineZoom($0) }),
                in: 1...6
            )
            .frame(width: 74)

            Button {
                model.nudgeTimelineZoom(0.5)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(model.timelineZoom >= 5.99)
            .foregroundStyle(model.timelineZoom >= 5.99 ? Color.secondary.opacity(0.45) : Color.white.opacity(0.86))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Edit")
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button {
                        model.isCommandPalettePresented = true
                    } label: {
                        Image(systemName: "command")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Command palette")
                }

                selectionSummarySection
                exportStatusSection
                presetsSection
                frameSection
                cutsSection
                speedAudioSection
                zoomSection
                effectsSection
                cursorSection
                if !model.project.usesRawSourceFrame {
                    backgroundSection
                }
                exportChecklistSection
                recentExportsSection
                exportButton
            }
            .padding(22)
        }
        .frame(width: 332)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(width: 1)
        }
    }

    private var selectionSummarySection: some View {
        HStack(spacing: 9) {
            Image(systemName: selectionIcon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(selectionTitle)
                    .font(.system(size: 12, weight: .heavy))
                Text(selectionDetail)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var selectionIcon: String {
        if model.selectedTimelineRange != nil { return "selection.pin.in.out" }
        if model.selectedEffectID != nil { return "sparkles.rectangle.stack" }
        if model.selectedZoomID != nil { return "plus.magnifyingglass" }
        if model.selectedClipID != nil { return "film" }
        return "slider.horizontal.3"
    }

    private var selectionTitle: String {
        if let range = model.selectedTimelineRange?.normalized {
            return "Range \(timeLabel(range.duration))"
        }
        if let effectID = model.selectedEffectID,
           let effect = model.project.overlayEffects.first(where: { $0.id == effectID }) {
            return effect.kind.title
        }
        if let zoomID = model.selectedZoomID,
           let zoom = model.project.zoomKeyframes.first(where: { $0.id == zoomID }) {
            return String(format: "Zoom %.1fx", zoom.scale)
        }
        if let segment = model.selectedSegment {
            return "Clip \(clipIndex(for: segment.id) + 1)"
        }
        return "Project"
    }

    private var selectionDetail: String {
        if let range = model.selectedTimelineRange?.normalized {
            return "\(timeLabel(range.start))-\(timeLabel(range.end))"
        }
        if let effectID = model.selectedEffectID,
           let effect = model.project.overlayEffects.first(where: { $0.id == effectID }) {
            return "\(timeLabel(effect.time)) · \(timeLabel(effect.duration))"
        }
        if let zoomID = model.selectedZoomID,
           let zoom = model.project.zoomKeyframes.first(where: { $0.id == zoomID }) {
            return "\(timeLabel(zoom.time)) · \(String(format: "%.0f%%", zoom.focusX * 100)), \(String(format: "%.0f%%", zoom.focusY * 100))"
        }
        if let segment = model.selectedSegment {
            return "\(timeLabel(segment.duration)) kept · \(String(format: "%.1fx", segment.clip.normalizedSpeed))"
        }
        return model.autosaveStatus
    }

    @ViewBuilder
    private var exportStatusSection: some View {
        if model.isExporting || model.exportCompletedURL != nil || model.exportErrorMessage != nil {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(exportStatusTitle, systemImage: exportStatusIcon)
                        .font(.system(size: 12, weight: .heavy))
                    Spacer()
                    if model.isExporting {
                        Text("\(Int(model.exportProgress * 100))%")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isExporting {
                    ProgressView(value: model.exportProgress)
                        .progressViewStyle(.linear)
                    exportDestinationLabel
                    Button {
                        model.cancelExport()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if model.exportCompletedURL != nil {
                    exportDestinationLabel
                    HStack(spacing: 8) {
                        Button {
                            model.revealCompletedExport()
                        } label: {
                            Label("Reveal", systemImage: "folder")
                                .font(.system(size: 11, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            model.copyCompletedExportPath()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 34, height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                } else if let message = model.exportErrorMessage {
                    Text(message)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(exportStatusStroke, lineWidth: 1)
            )
        }
    }

    private var exportDestinationLabel: some View {
        Text((model.exportCompletedURL ?? model.exportDestinationURL)?.lastPathComponent ?? "Export MP4")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportStatusTitle: String {
        if model.isExporting { return "Exporting MP4" }
        if model.exportCompletedURL != nil { return "Export Ready" }
        return "Export Failed"
    }

    private var exportStatusIcon: String {
        if model.isExporting { return "hourglass" }
        if model.exportCompletedURL != nil { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var exportStatusStroke: Color {
        if model.isExporting { return Color.accentColor.opacity(0.25) }
        if model.exportCompletedURL != nil { return Color.green.opacity(0.26) }
        return Color.red.opacity(0.30)
    }

    private var exportChecklistSection: some View {
        controlSection("Export") {
            VStack(spacing: 7) {
                exportFact("Duration", timeLabel(model.timelineDuration), "timer")
                exportFact("Canvas", canvasLabel, "rectangle.inset.filled")
                exportFact("Clips", "\(model.timelineSegments.count)", "film.stack")
                exportFact("Effects", "\(model.project.zoomKeyframes.count + model.project.overlayEffects.count)", "sparkles")
                exportFact("Draft", model.autosaveStatus, "internaldrive")
            }
        }
    }

    private func exportFact(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var recentExportsSection: some View {
        if !model.recentExports.isEmpty {
            controlSection("Recent Exports") {
                VStack(spacing: 7) {
                    ForEach(model.recentExports.prefix(3)) { export in
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(export.exportURL.lastPathComponent)
                                    .font(.system(size: 10, weight: .heavy))
                                    .lineLimit(1)
                                Text(fileSizeLabel(export.fileSize))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.revealExport(export)
                            } label: {
                                Image(systemName: "folder")
                                    .frame(width: 26, height: 24)
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .frame(height: 34)
                    }
                }
            }
        }
    }

    private var exportButton: some View {
        Button {
            Task { await model.export() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isExporting ? "hourglass" : "square.and.arrow.up")
                Text(model.isExporting ? "Exporting" : "Export MP4")
            }
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isExporting || model.duration <= 0)
        .background(Color.accentColor.opacity(model.isExporting ? 0.25 : 0.95), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .foregroundStyle(.white)
    }

    private var canvasLabel: String {
        let size = model.project.canvasSize()
        return "\(Int(size.width)) x \(Int(size.height))"
    }

    private func fileSizeLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "Saved" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    private func clipIndex(for id: UUID) -> Int {
        model.timelineSegments.firstIndex { $0.id == id } ?? 0
    }

    private var presetsSection: some View {
        controlSection("Presets") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(VideoDemoExportPreset.allCases) { preset in
                    Button {
                        model.applyPreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(.system(size: 11, weight: .bold))
                            Text(preset.subtitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var frameSection: some View {
        controlSection("Frame") {
            Picker(
                "",
                selection: Binding(
                    get: { model.project.aspectPreset },
                    set: { model.setAspectPreset($0) }
                )
            ) {
                ForEach(VideoDemoProject.AspectPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var cutsSection: some View {
        controlSection("Timeline") {
            HStack(spacing: 8) {
                Button {
                    model.splitAtPlayhead()
                } label: {
                    Label("Split", systemImage: "scissors")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Split at playhead")

                Button {
                    model.deleteSelectedClip()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!model.canDeleteSelectedClip)
                .foregroundStyle(model.canDeleteSelectedClip ? Color.red.opacity(0.95) : Color.secondary)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Delete selected clip")

                Button {
                    model.undoTimelineEdit()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!model.canUndoTimelineEdit)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Undo timeline edit")

                Button {
                    model.redoTimelineEdit()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!model.canRedoTimelineEdit)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Redo timeline edit")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.timelineSegments.enumerated()), id: \.element.id) { index, segment in
                        Button {
                            model.selectClip(segment.id)
                            model.seekToTimeline(segment.timelineStart)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clip \(index + 1)")
                                    .font(.system(size: 10, weight: .heavy))
                                Text("\(timeLabel(segment.clip.sourceStart))-\(timeLabel(segment.clip.sourceEnd))")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 78, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .background(
                                model.selectedClipID == segment.id ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.075),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(model.selectedClipID == segment.id ? Color.accentColor.opacity(0.58) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let segment = model.selectedSegment {
                VStack(spacing: 10) {
                    HStack {
                        Text("Selected")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(timeLabel(segment.duration)) kept")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    sliderRow(
                        "In",
                        value: Binding(get: { segment.clip.sourceStart }, set: { model.setSelectedClipStart($0) }),
                        range: 0...max(model.duration, 0.1),
                        label: timeLabel(segment.clip.sourceStart)
                    )
                    sliderRow(
                        "Out",
                        value: Binding(get: { segment.clip.sourceEnd }, set: { model.setSelectedClipEnd($0) }),
                        range: 0...max(model.duration, 0.1),
                        label: timeLabel(segment.clip.sourceEnd)
                    )
                }
            }
        }
    }

    private var zoomSection: some View {
        controlSection("Zoom") {
            HStack(spacing: 8) {
                Button {
                    model.addZoom()
                } label: {
                    Label("Add", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    model.addAutoZoomPreset()
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Auto zoom")

                Button {
                    model.deleteSelectedZoom()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(model.selectedZoomID == nil)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.project.zoomKeyframes.sorted { $0.time < $1.time }) { keyframe in
                        Button {
                            model.selectedZoomID = keyframe.id
                            model.seek(to: keyframe.time)
                        } label: {
                            Text("\(timeLabel(keyframe.time))  \(String(format: "%.1fx", keyframe.scale))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(model.selectedZoomID == keyframe.id ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let binding = model.selectedZoomBinding() {
                VStack(spacing: 10) {
                    sliderRow("Time", value: binding.time, range: 0...max(model.duration, 0.1), label: timeLabel(binding.wrappedValue.time))
                    sliderRow("Scale", value: binding.scale, range: 1...3, label: String(format: "%.2fx", binding.wrappedValue.scale))
                    sliderRow("Focus X", value: binding.focusX, range: 0...1, label: String(format: "%.0f%%", binding.wrappedValue.focusX * 100))
                    sliderRow("Focus Y", value: binding.focusY, range: 0...1, label: String(format: "%.0f%%", binding.wrappedValue.focusY * 100))
                }
            }
        }
    }

    private var speedAudioSection: some View {
        controlSection("Speed + Audio") {
            if let segment = model.selectedSegment {
                HStack(spacing: 6) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                        Button {
                            model.setSelectedClipSpeed(speed)
                        } label: {
                            Text(String(format: "%.1fx", speed))
                                .font(.system(size: 10, weight: .heavy))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(
                            abs(segment.clip.normalizedSpeed - speed) < 0.01 ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.075),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                }

                toggleRow(
                    "Mute selected clip",
                    value: Binding(get: { segment.clip.muted }, set: { model.setSelectedClipMuted($0) })
                )
                sliderRow(
                    "Fade In",
                    value: Binding(get: { segment.clip.fadeIn }, set: { model.setSelectedClipFadeIn($0) }),
                    range: 0...max(segment.duration / 2, 0.1),
                    label: timeLabel(segment.clip.fadeIn)
                )
                sliderRow(
                    "Fade Out",
                    value: Binding(get: { segment.clip.fadeOut }, set: { model.setSelectedClipFadeOut($0) }),
                    range: 0...max(segment.duration / 2, 0.1),
                    label: timeLabel(segment.clip.fadeOut)
                )
            }
        }
    }

    private var effectsSection: some View {
        controlSection("Effects") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(VideoDemoOverlayEffectKind.allCases) { kind in
                    Button {
                        model.addEffect(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.icon)
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if !model.project.overlayEffects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.project.overlayEffects.sorted { $0.time < $1.time }) { effect in
                            Button {
                                model.selectedEffectID = effect.id
                                model.seek(to: effect.time)
                            } label: {
                                Label(effect.kind.title, systemImage: effect.kind.icon)
                                    .font(.system(size: 10, weight: .heavy))
                                    .padding(.horizontal, 8)
                                    .frame(height: 26)
                                    .background(model.selectedEffectID == effect.id ? Color.accentColor.opacity(0.26) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let binding = model.selectedEffectBinding() {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Text", text: binding.text)
                            .textFieldStyle(.roundedBorder)
                            .disabled(binding.wrappedValue.kind != .text)

                        Button {
                            model.deleteSelectedEffect()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    sliderRow("Time", value: binding.time, range: 0...max(model.duration, 0.1), label: timeLabel(binding.wrappedValue.time))
                    sliderRow("Length", value: binding.duration, range: 0.2...max(model.duration, 0.2), label: timeLabel(binding.wrappedValue.duration))
                    sliderRow("X", value: binding.x, range: 0.02...0.92, label: String(format: "%.0f%%", binding.wrappedValue.x * 100))
                    sliderRow("Y", value: binding.y, range: 0.02...0.92, label: String(format: "%.0f%%", binding.wrappedValue.y * 100))
                    sliderRow("Size", value: binding.width, range: 0.05...0.9, label: String(format: "%.0f%%", binding.wrappedValue.width * 100))
                }
            }
        }
    }

    private var cursorSection: some View {
        controlSection("Cursor") {
            toggleRow("Demo cursor", value: $model.project.showCursorOverlay)
            sliderRow(
                "Size",
                value: $model.project.cursorScale,
                range: VideoDemoProject.cursorScaleRange,
                label: String(format: "%.0f%%", model.project.cursorScale * 100)
            )
            toggleRow("Smooth cursor", value: $model.project.smoothCursor)
            toggleRow("Motion blur", value: $model.project.cursorMotionBlur)
            toggleRow("Click ripple", value: $model.project.showClickRipple)
            toggleRow("Click spotlight", value: $model.project.clickSpotlight)
        }
    }

    private var backgroundSection: some View {
        controlSection("Background") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(VideoDemoProject.BackgroundPreset.allCases) { preset in
                    Button {
                        model.project.backgroundPreset = preset
                    } label: {
                        HStack(spacing: 8) {
                            LinearGradient(colors: preset.previewColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: 24, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            Text(preset.title)
                                .font(.system(size: 11, weight: .bold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(
                            model.project.backgroundPreset == preset ? Color.accentColor.opacity(0.20) : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.chooseBackgroundImage()
                } label: {
                    Label("Image", systemImage: "photo")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    model.clearBackgroundImage()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(model.project.customBackgroundPath.isEmpty)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            sliderRow("Inset", value: $model.project.stageInset, range: 0.04...0.18, label: String(format: "%.0f%%", model.project.stageInset * 100))
            sliderRow("Blur", value: $model.project.backgroundBlur, range: 0...18, label: String(format: "%.0f", model.project.backgroundBlur))
            sliderRow("Shadow", value: $model.project.shadowStrength, range: 0...0.85, label: String(format: "%.0f%%", model.project.shadowStrength * 100))
            sliderRow("Corners", value: $model.project.cornerRadius, range: 0...42, label: String(format: "%.0f", model.project.cornerRadius))
        }
    }

    private var trimSection: some View {
        controlSection("Trim") {
            VStack(spacing: 10) {
                sliderRow("Start", value: Binding(get: { model.project.trimStart }, set: { model.setTrimStart($0) }), range: 0...max(model.duration, 0.1), label: timeLabel(model.project.trimStart))
                sliderRow("End", value: Binding(get: { model.project.trimEnd }, set: { model.setTrimEnd($0) }), range: 0...max(model.duration, 0.1), label: timeLabel(model.project.trimEnd))
            }
        }
    }

    private func controlSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func toggleRow(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Toggle("", isOn: value)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(height: 26)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 58, alignment: .leading)
            Slider(value: value, in: range)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func timeLabel(_ value: Double) -> String {
        let safe = max(value, 0)
        let minutes = Int(safe) / 60
        let seconds = Int(safe) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct VideoDemoEditorCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void
}

private struct VideoDemoCommandPalette: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    @State private var query = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    model.isCommandPalettePresented = false
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "command")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .bold))
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filteredCommands) { command in
                            Button {
                                guard command.isEnabled else { return }
                                model.isCommandPalettePresented = false
                                command.action()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.symbol)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(command.isDestructive ? Color.red.opacity(0.92) : Color.white.opacity(command.isEnabled ? 0.86 : 0.34))
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(command.isEnabled ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(command.title)
                                            .font(.system(size: 12, weight: .heavy))
                                            .foregroundStyle(Color.white.opacity(command.isEnabled ? 0.92 : 0.36))
                                        Text(command.detail)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.white.opacity(command.isEnabled ? 0.48 : 0.25))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if !command.shortcut.isEmpty {
                                        Text(command.shortcut)
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(command.isEnabled ? 0.44 : 0.22))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 48)
                                .background(Color.white.opacity(command.isEnabled ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!command.isEnabled)
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            .padding(14)
            .frame(width: 470)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.34), radius: 28, x: 0, y: 22)
        }
        .onExitCommand {
            model.isCommandPalettePresented = false
        }
    }

    private var filteredCommands: [VideoDemoEditorCommand] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let commands = allCommands
        guard !search.isEmpty else { return commands }
        return commands.filter {
            $0.title.lowercased().contains(search) ||
            $0.detail.lowercased().contains(search)
        }
    }

    private var allCommands: [VideoDemoEditorCommand] {
        [
            command("split", "Split at Playhead", "Current clip", "scissors", "S") {
                model.splitAtPlayhead()
            },
            command("delete", "Delete Selection", "Ripple delete", "trash", "Del", enabled: model.canDeleteSelectedClip, destructive: true) {
                model.deleteSelectedClip()
            },
            command("trim-in", "Set In to Playhead", "Selected clip", "arrow.left.to.line", "I") {
                model.trimSelectedClipStartToPlayhead()
            },
            command("trim-out", "Set Out to Playhead", "Selected clip", "arrow.right.to.line", "O") {
                model.trimSelectedClipEndToPlayhead()
            },
            command("mute", "Toggle Mute", "Selected clip", "speaker.slash", "M", enabled: model.selectedClipID != nil) {
                if let id = model.selectedClipID {
                    model.toggleClipMuted(id: id)
                }
            },
            command("undo", "Undo", "Last edit", "arrow.uturn.backward", "Cmd-Z", enabled: model.canUndoTimelineEdit) {
                model.undoTimelineEdit()
            },
            command("redo", "Redo", "Last edit", "arrow.uturn.forward", "Shift-Cmd-Z", enabled: model.canRedoTimelineEdit) {
                model.redoTimelineEdit()
            },
            command("zoom", "Add Zoom", "Camera lane", "plus.magnifyingglass", "") {
                model.addZoom()
            },
            command("auto-zoom", "Auto Zoom", "Camera lane", "sparkles", "") {
                model.addAutoZoomPreset()
            },
            command("text", "Add Text", "Effect lane", "textformat", "") {
                model.addEffect(.text)
            },
            command("highlight", "Add Highlight", "Effect lane", "rectangle.roundedtop", "") {
                model.addEffect(.highlight)
            },
            command("export", model.isExporting ? "Cancel Export" : "Export MP4", model.isExporting ? "In progress" : "Edited composition", model.isExporting ? "xmark" : "square.and.arrow.up", "", enabled: model.duration > 0, destructive: model.isExporting) {
                if model.isExporting {
                    model.cancelExport()
                } else {
                    Task { await model.export() }
                }
            },
            command("reveal-source", "Reveal Source", model.project.sourceURL.lastPathComponent, "folder", "") {
                model.revealSource()
            },
        ]
    }

    private func command(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ symbol: String,
        _ shortcut: String,
        enabled: Bool = true,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> VideoDemoEditorCommand {
        VideoDemoEditorCommand(
            id: id,
            title: title,
            detail: detail,
            symbol: symbol,
            shortcut: shortcut,
            isEnabled: enabled,
            isDestructive: destructive,
            action: action
        )
    }
}

private struct VideoDemoKeyboardShortcutBridge: NSViewRepresentable {
    let model: VideoDemoEditorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view, model: model)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(on: nsView, model: model)
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private weak var view: NSView?
        private var model: VideoDemoEditorViewModel

        init(model: VideoDemoEditorViewModel) {
            self.model = model
        }

        func install(on view: NSView, model: VideoDemoEditorViewModel) {
            self.view = view
            self.model = model
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.view?.window,
                      window.isKeyWindow,
                      !Self.isEditingText(in: window) else {
                    return event
                }
                return self.model.handleEditorShortcut(event) ? nil : event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private static func isEditingText(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField
        }
    }
}

private struct VideoDemoStageView: View {
    @ObservedObject var model: VideoDemoEditorViewModel

    var body: some View {
        GeometryReader { proxy in
            let layout = stageLayout(in: proxy.size)

            ZStack {
                if !model.project.usesRawSourceFrame {
                    VideoDemoBackgroundView(project: model.project)
                        .frame(width: layout.canvas.width, height: layout.canvas.height)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .position(x: layout.canvas.midX, y: layout.canvas.midY)
                }

                stageContent(size: layout.stage.size)
                    .frame(width: layout.stage.width, height: layout.stage.height)
                    .clipShape(RoundedRectangle(cornerRadius: model.project.effectiveCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(model.project.effectiveShadowStrength), radius: 28, x: 0, y: 22)
                    .overlay(safeAreaGuide(size: layout.stage.size))
                    .contentShape(RoundedRectangle(cornerRadius: model.project.effectiveCornerRadius, style: .continuous))
                    .gesture(stageSeekGesture(stageWidth: layout.stage.width))
                    .position(x: layout.stage.midX, y: layout.stage.midY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func stageContent(size: CGSize) -> some View {
        let zoom = model.project.zoomState(at: model.currentTime)
        let offset = CGSize(
            width: (0.5 - zoom.focusX) * size.width * max(zoom.scale - 1, 0),
            height: (0.5 - zoom.focusY) * size.height * max(zoom.scale - 1, 0)
        )

        return ZStack {
            ShotnixVideoPlayerView(player: model.player)
            VideoDemoOverlayView(model: model, stageSize: size)
        }
        .scaleEffect(zoom.scale)
        .offset(offset)
    }

    private func stageSeekGesture(stageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard abs(value.translation.width) < 4, abs(value.translation.height) < 4 else { return }
                let progress = Double(min(max(value.location.x / max(stageWidth, 1), 0), 1))
                model.seekToTimeline(model.timelineDuration * progress)
            }
    }

    private func safeAreaGuide(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [6, 7]))
                .frame(width: size.width * 0.90, height: size.height * 0.90)
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [3, 8]))
                .frame(width: size.width * 0.78, height: size.height * 0.78)
        }
        .allowsHitTesting(false)
        .opacity(model.project.usesRawSourceFrame ? 0 : 0.42)
    }

    private func stageLayout(in size: CGSize) -> (canvas: CGRect, stage: CGRect) {
        let canvasSize = model.project.canvasSize()
        let scale = min(size.width / max(canvasSize.width, 1), size.height / max(canvasSize.height, 1))
        let canvasFrame = CGRect(
            x: (size.width - canvasSize.width * scale) / 2,
            y: (size.height - canvasSize.height * scale) / 2,
            width: canvasSize.width * scale,
            height: canvasSize.height * scale
        )
        let stage = model.project.stageRect(in: canvasSize)
        let stageFrame = CGRect(
            x: canvasFrame.minX + stage.minX * scale,
            y: canvasFrame.minY + (canvasSize.height - stage.maxY) * scale,
            width: stage.width * scale,
            height: stage.height * scale
        )
        return (canvasFrame, stageFrame)
    }
}

private struct VideoDemoBackgroundView: View {
    let project: VideoDemoProject

    var body: some View {
        Group {
            if let url = project.customBackgroundURL,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: project.backgroundPreset.previewColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .blur(radius: project.backgroundBlur)
        .clipped()
    }
}

private struct VideoDemoOverlayView: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    let stageSize: CGSize

    var body: some View {
        ZStack {
            if model.project.clickSpotlight,
               let spot = model.activeClicks(at: model.currentTime).min(by: { $0.progress < $1.progress }) {
                let radius = min(stageSize.width, stageSize.height) * 0.16
                Rectangle()
                    .fill(Color.black.opacity(0.55 * (1 - spot.progress)))
                    .mask(
                        ZStack {
                            Rectangle().fill(Color.black)
                            Circle()
                                .frame(width: radius * 2, height: radius * 2)
                                .position(point(for: spot.event.x, spot.event.y))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .allowsHitTesting(false)
            }

            ForEach(model.activeEffects(at: model.currentTime)) { effect in
                effectView(effect)
            }

            if model.project.showClickRipple {
                ForEach(model.activeClicks(at: model.currentTime), id: \.event.id) { entry in
                    let point = point(for: entry.event.x, entry.event.y)
                    Circle()
                        .stroke(Color.accentColor.opacity(0.8 * (1 - entry.progress)), lineWidth: 3)
                        .frame(width: 24 + 48 * entry.progress, height: 24 + 48 * entry.progress)
                        .position(point)
                }
            }

            if model.project.showCursorOverlay, let sample = model.cursorSample(at: model.currentTime) {
                let cursorSide = 25 * min(max(model.project.cursorScale, VideoDemoProject.cursorScaleRange.lowerBound), VideoDemoProject.cursorScaleRange.upperBound)
                CursorShape()
                    .fill(.white)
                    .overlay(CursorShape().stroke(.black.opacity(0.66), lineWidth: 1.6))
                    .frame(width: cursorSide, height: cursorSide)
                    .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 3)
                    .position(point(for: sample.x, sample.y))
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
    }

    @ViewBuilder
    private func effectView(_ effect: VideoDemoOverlayEffect) -> some View {
        let size = CGSize(
            width: stageSize.width * min(max(effect.width, 0.04), 0.9),
            height: stageSize.height * min(max(effect.height, 0.04), 0.6)
        )
        let position = point(for: effect.x, effect.y)

        switch effect.kind {
        case .text:
            Text(effect.text)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .position(position)
        case .highlight:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.yellow.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.yellow.opacity(0.9), lineWidth: 3)
                )
                .frame(width: size.width, height: size.height)
                .position(position)
        case .arrow:
            TimelineArrowShape()
                .stroke(.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
                .position(position)
        case .blur:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )
                .frame(width: size.width, height: size.height)
                .position(position)
        }
    }

    private func point(for x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: stageSize.width * x, y: stageSize.height * y)
    }
}

private struct TimelineArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.18)
        let end = CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.18)
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - rect.width * 0.18, y: end.y + rect.height * 0.03))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - rect.width * 0.03, y: end.y + rect.height * 0.18))
        return path
    }
}

private struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.maxY - rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + rect.height * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.56, y: rect.minY + rect.height * 0.38))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.minY + rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.32))
        path.closeSubpath()
        return path
    }
}

private enum TimelineTrimEdge {
    case leading
    case trailing
}

private struct ActiveTimelineTrim {
    let edge: TimelineTrimEdge
    let clipID: UUID
    let sourceStart: Double
    let sourceEnd: Double
    let timelineStart: Double
    let timelineEnd: Double
    let speed: Double
}

private struct VideoDemoTimelineView: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    @State private var hoveredClipID: UUID?
    @State private var activeTrim: ActiveTimelineTrim?
    @State private var hoverTimelineTime: Double?
    @State private var isSelectingRange = false

    var body: some View {
        GeometryReader { proxy in
            let baseWidth = max(proxy.size.width, 1)
            let width = max(baseWidth, baseWidth * CGFloat(model.timelineZoom))
            let duration = max(model.timelineDuration, 0.1)

            ScrollView(.horizontal, showsIndicators: model.timelineZoom > 1.05) {
                timelineCanvas(width: width, height: proxy.size.height, duration: duration)
                    .frame(width: width, height: proxy.size.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverTimelineTime = model.snappedTimelineTime(
                                timelineTime(at: location.x, width: width, duration: duration),
                                threshold: snapThreshold(duration: duration, width: width)
                            )
                        case .ended:
                            hoverTimelineTime = nil
                        }
                    }
            }
        }
    }

    private func timelineCanvas(width: CGFloat, height: CGFloat, duration: Double) -> some View {
        let playheadX = CGFloat(model.timelineTime / duration) * width

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                ruler(width: width, duration: duration)
                    .frame(height: 22)
                videoTrack(width: width, duration: duration)
                    .frame(height: 78)
                zoomTrack(width: width, duration: duration)
                    .frame(height: 30)
                effectTrack(width: width, duration: duration)
                    .frame(height: 28)
            }

            if let hoverTimelineTime {
                hoverScrubber(time: hoverTimelineTime, width: width, height: height, duration: duration)
            }

            playhead(height: height - 2)
                .offset(x: playheadX - 1, y: 1)

            splitBladeMarker
                .offset(x: min(max(playheadX - 11, 0), max(width - 22, 0)), y: 25)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { gesture in
                guard activeTrim == nil, !isSelectingRange else { return }
                model.clearTimelineSelection()
                model.seekToTimeline(
                    timelineTime(at: gesture.location.x, width: width, duration: duration),
                    snapping: true,
                    snapThreshold: snapThreshold(duration: duration, width: width)
                )
            }
        )
    }

    private func hoverScrubber(time: Double, width: CGFloat, height: CGFloat, duration: Double) -> some View {
        let x = CGFloat(time / duration) * width
        return VStack(spacing: 3) {
            Text(timeLabel(time))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Rectangle()
                .fill(Color.white.opacity(0.46))
                .frame(width: 1, height: max(height - 21, 0))
        }
        .offset(x: min(max(x - 18, 0), max(width - 36, 0)), y: 2)
        .allowsHitTesting(false)
    }

    private var splitBladeMarker: some View {
        Image(systemName: "scissors")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 20)
            .background(Color.purple.opacity(0.86), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: Color.purple.opacity(0.30), radius: 5, x: 0, y: 0)
            .allowsHitTesting(false)
    }

    private func ruler(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)

            ForEach(tickValues(duration: duration), id: \.self) { tick in
                let x = CGFloat(tick / duration) * width
                VStack(spacing: 3) {
                    Rectangle()
                        .fill(Color.white.opacity(tick == 0 ? 0.26 : 0.16))
                        .frame(width: 1, height: tick == 0 || abs(tick - duration) < 0.001 ? 9 : 6)
                    Text(timeLabel(tick))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .fixedSize()
                }
                .offset(x: min(max(x - 14, 0), max(width - 32, 0)), y: 1)
            }
        }
    }

    private func videoTrack(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            ForEach(model.timelineSnapPoints(), id: \.self) { point in
                Rectangle()
                    .fill(Color.white.opacity(point == 0 || abs(point - duration) < 0.001 ? 0.20 : 0.10))
                    .frame(width: 1, height: 70)
                    .offset(x: CGFloat(point / duration) * width, y: 4)
                    .allowsHitTesting(false)
            }

            ForEach(Array(model.timelineSegments.enumerated()), id: \.element.id) { index, segment in
                let segmentX = CGFloat(segment.timelineStart / duration) * width
                let segmentWidth = max(CGFloat(segment.duration / duration) * width - 4, 64)
                videoClip(segment: segment, index: index, timelineWidth: width, timelineDuration: duration)
                    .frame(width: segmentWidth, height: 70)
                    .offset(x: segmentX + 2)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .highPriorityGesture(clipSeekGesture(segment: segment, clipWidth: segmentWidth))
                    .onHover { hovering in
                        hoveredClipID = hovering ? segment.id : (hoveredClipID == segment.id ? nil : hoveredClipID)
                    }
            }

            ForEach(model.project.clickEvents) { click in
                if let markerTime = model.project.timelineTimeIfIncluded(sourceTime: click.time, totalDuration: model.duration) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .offset(x: CGFloat(markerTime / duration) * width - 3, y: 58)
                }
            }

            if let range = model.selectedTimelineRange?.normalized {
                timelineRangeOverlay(range: range, width: width, duration: duration, color: Color.accentColor, opacity: 0.24, strokeOpacity: 0.80)
            }

            if let range = model.timelineEditFlash?.normalized {
                timelineRangeOverlay(range: range, width: width, duration: duration, color: Color.yellow, opacity: 0.18, strokeOpacity: 0.70)
            }

            ForEach(Array(model.timelineSegments.enumerated()), id: \.element.id) { _, segment in
                if model.selectedClipID == segment.id {
                    let segmentX = CGFloat(segment.timelineStart / duration) * width
                    let segmentWidth = max(CGFloat(segment.duration / duration) * width - 4, 64)
                    inlineClipTools(segment: segment)
                        .offset(x: min(segmentX + segmentWidth - 130, max(width - 132, 2)), y: 7)
                }
            }
        }
    }

    private func clipSeekGesture(segment: VideoDemoTimelineSegment, clipWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard activeTrim == nil else { return }
                let start = timelineTime(in: segment, x: value.startLocation.x, width: clipWidth)
                let selecting = abs(value.translation.width) > 12
                let current = timelineTime(in: segment, x: value.location.x, width: clipWidth, clamped: !selecting)
                let threshold = snapThreshold(duration: segment.duration, width: clipWidth)
                if selecting {
                    isSelectingRange = true
                    model.setTimelineSelection(
                        start: model.snappedTimelineTime(start, threshold: threshold),
                        end: model.snappedTimelineTime(current, threshold: threshold)
                    )
                } else if !isSelectingRange {
                    model.clearTimelineSelection()
                    model.selectClip(segment.id)
                    model.seekToTimeline(current, snapping: true, snapThreshold: threshold)
                }
            }
            .onEnded { value in
                guard activeTrim == nil else { return }
                let current = timelineTime(in: segment, x: value.location.x, width: clipWidth)
                let threshold = snapThreshold(duration: segment.duration, width: clipWidth)
                if abs(value.translation.width) <= 12 {
                    model.clearTimelineSelection()
                    model.selectClip(segment.id)
                    model.seekToTimeline(current, snapping: true, snapThreshold: threshold)
                }
                isSelectingRange = false
            }
    }

    private func inlineClipTools(segment: VideoDemoTimelineSegment) -> some View {
        HStack(spacing: 3) {
            timelineToolButton(symbol: "scissors") {
                model.selectClip(segment.id)
                model.splitAtPlayhead()
            }
            timelineToolButton(symbol: segment.clip.muted ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                model.toggleClipMuted(id: segment.id)
            }
            timelineToolButton(symbol: "speedometer") {
                model.setClipSpeed(id: segment.id, value: nextSpeed(after: segment.clip.normalizedSpeed))
            }
            timelineToolButton(symbol: "trash.fill", destructive: true) {
                model.deleteClip(id: segment.id, timelineAnchor: segment.timelineStart)
            }
            .disabled(model.timelineSegments.count <= 1)
            .opacity(model.timelineSegments.count <= 1 ? 0.45 : 1)
        }
        .padding(3)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
    }

    private func timelineToolButton(symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(destructive ? Color.red.opacity(0.95) : Color.white.opacity(0.92))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func timelineRangeOverlay(range: VideoDemoTimelineRange, width: CGFloat, duration: Double, color: Color, opacity: Double, strokeOpacity: Double) -> some View {
        let startX = CGFloat(range.start / duration) * width
        let endX = CGFloat(range.end / duration) * width
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(color.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(color.opacity(strokeOpacity), lineWidth: 1.4)
            )
            .frame(width: max(endX - startX, 4), height: 70)
            .offset(x: startX + 2, y: 4)
            .allowsHitTesting(false)
    }

    private func zoomTrack(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            ForEach(zoomMoveRanges(duration: duration), id: \.id) { move in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.blue.opacity(move.selected ? 0.58 : 0.34))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(move.selected ? 0.32 : 0.12), lineWidth: 1)
                    )
                    .frame(width: max(CGFloat(move.duration / duration) * width, 22), height: 22)
                    .offset(x: CGFloat(move.start / duration) * width, y: 4)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 7) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                Text("Camera")
                    .font(.system(size: 10, weight: .heavy))
                Text(model.project.zoomKeyframes.isEmpty ? "Auto" : "\(model.project.zoomKeyframes.count) moves")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: max(width - 4, 0), height: 28)
            .offset(x: 2)

            ForEach(model.project.zoomKeyframes) { keyframe in
                if let markerTime = model.project.timelineTimeIfIncluded(sourceTime: keyframe.time, totalDuration: model.duration) {
                    Capsule()
                        .fill(model.selectedZoomID == keyframe.id ? Color.accentColor : Color.white)
                        .frame(width: model.selectedZoomID == keyframe.id ? 7 : 4, height: 24)
                        .offset(x: CGFloat(markerTime / duration) * width - 2, y: 3)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let next = timelineTime(
                                        at: CGFloat(markerTime / duration) * width + value.translation.width,
                                        width: width,
                                        duration: duration
                                    )
                                    model.moveZoom(id: keyframe.id, toTimelineTime: model.snappedTimelineTime(next, threshold: snapThreshold(duration: duration, width: width)))
                                }
                                .onEnded { value in
                                    if abs(value.translation.width) <= 4 {
                                        model.selectZoom(keyframe.id)
                                        model.seekToTimeline(markerTime)
                                    }
                                }
                        )
                }
            }
        }
    }

    private func effectTrack(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 7) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 10, weight: .bold))
                Text("Effects")
                    .font(.system(size: 10, weight: .heavy))
                Text(effectLaneSummary)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: max(width - 4, 0), height: 26)
            .offset(x: 2)

            ForEach(model.project.overlayEffects) { effect in
                if let markerTime = model.project.timelineTimeIfIncluded(sourceTime: effect.time, totalDuration: model.duration) {
                    Image(systemName: effect.kind.icon)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 18, height: 18)
                        .background(model.selectedEffectID == effect.id ? Color.accentColor.opacity(0.72) : Color.black.opacity(0.34), in: Circle())
                        .offset(x: CGFloat(markerTime / duration) * width - 9, y: 5)
                        .onTapGesture {
                            model.selectEffect(effect.id)
                            model.seekToTimeline(markerTime)
                        }
                }
            }
        }
    }

    private func zoomMoveRanges(duration: Double) -> [(id: UUID, start: Double, duration: Double, selected: Bool)] {
        let sorted = model.project.zoomKeyframes.sorted { $0.time < $1.time }
        return sorted.compactMap { keyframe in
            guard let start = model.project.timelineTimeIfIncluded(sourceTime: keyframe.time, totalDuration: model.duration) else { return nil }
            let next = sorted
                .filter { $0.time > keyframe.time + 0.001 }
                .compactMap { model.project.timelineTimeIfIncluded(sourceTime: $0.time, totalDuration: model.duration) }
                .first
            let end = min(next ?? start + 1.2, duration)
            return (keyframe.id, start, max(end - start, 0.25), model.selectedZoomID == keyframe.id)
        }
    }

    private var effectLaneSummary: String {
        var parts: [String] = []
        if model.project.showCursorOverlay { parts.append("Cursor") }
        if model.project.showClickRipple { parts.append("Clicks") }
        if !model.project.overlayEffects.isEmpty { parts.append("\(model.project.overlayEffects.count) callouts") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private var thumbnailStrip: some View {
        HStack(spacing: 0) {
            if model.timelineThumbnails.isEmpty {
                LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.04)], startPoint: .leading, endPoint: .trailing)
            } else {
                ForEach(model.timelineThumbnails) { thumbnail in
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
        .background(Color.white.opacity(0.07))
    }

    private func videoClip(segment: VideoDemoTimelineSegment, index: Int, timelineWidth: CGFloat, timelineDuration: Double) -> some View {
        let selected = model.selectedClipID == segment.id
        let hovered = hoveredClipID == segment.id
        return ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                thumbnailStrip
                    .frame(height: 42)
                    .opacity(selected || hovered ? 0.86 : 0.70)
                    .clipped()

                ZStack {
                    Color(red: 0.58, green: 0.38, blue: 0.03).opacity(selected ? 0.86 : (hovered ? 0.76 : 0.64))
                    TimelineWaveformShape()
                        .stroke(Color.white.opacity(0.42), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 10, weight: .bold))
                    Text("Clip \(index + 1)")
                        .font(.system(size: 10, weight: .heavy))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if segment.clip.muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    if abs(segment.clip.normalizedSpeed - 1) > 0.01 {
                        Text(String(format: "%.1fx", segment.clip.normalizedSpeed))
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    Text(timeLabel(segment.duration))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.76))
                }

                Spacer(minLength: 0)

                Text("\(timeLabel(segment.clip.sourceStart))-\(timeLabel(segment.clip.sourceEnd))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.66))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if selected {
                HStack {
                    trimHandle(edge: .leading, segment: segment, timelineWidth: timelineWidth, timelineDuration: timelineDuration)
                    Spacer(minLength: 0)
                    trimHandle(edge: .trailing, segment: segment, timelineWidth: timelineWidth, timelineDuration: timelineDuration)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.92) : Color.white.opacity(hovered ? 0.24 : 0.14), lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: selected ? Color.accentColor.opacity(0.18) : .clear, radius: 7, x: 0, y: 0)
        .contextMenu {
            clipContextMenu(segment: segment, index: index)
        }
    }

    @ViewBuilder
    private func clipContextMenu(segment: VideoDemoTimelineSegment, index: Int) -> some View {
        Button {
            model.selectClip(segment.id)
            model.seekToTimeline(segment.timelineStart)
        } label: {
            Label("Select Clip \(index + 1)", systemImage: "cursorarrow")
        }

        Button {
            model.selectClip(segment.id)
            model.splitAtPlayhead()
        } label: {
            Label("Split at Playhead", systemImage: "scissors")
        }

        Button {
            model.selectClip(segment.id)
            model.trimSelectedClipStartToPlayhead()
        } label: {
            Label("Set In to Playhead", systemImage: "arrow.left.to.line")
        }

        Button {
            model.selectClip(segment.id)
            model.trimSelectedClipEndToPlayhead()
        } label: {
            Label("Set Out to Playhead", systemImage: "arrow.right.to.line")
        }

        Divider()

        Menu {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                Button {
                    model.setClipSpeed(id: segment.id, value: speed)
                } label: {
                    Label(String(format: "%.1fx", speed), systemImage: abs(segment.clip.normalizedSpeed - speed) < 0.01 ? "checkmark" : "speedometer")
                }
            }
        } label: {
            Label("Speed", systemImage: "speedometer")
        }

        Button {
            model.toggleClipMuted(id: segment.id)
        } label: {
            Label(segment.clip.muted ? "Unmute Clip" : "Mute Clip", systemImage: segment.clip.muted ? "speaker.wave.2" : "speaker.slash")
        }

        Divider()

        Button(role: .destructive) {
            model.deleteClip(id: segment.id, timelineAnchor: segment.timelineStart)
        } label: {
            Label("Delete Clip", systemImage: "trash")
        }
        .disabled(model.timelineSegments.count <= 1)
    }

    private func trimHandle(edge: TimelineTrimEdge, segment: VideoDemoTimelineSegment, timelineWidth: CGFloat, timelineDuration: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .frame(width: 18, height: 58)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 5, height: 46)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, x: 0, y: 0)
            Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white.opacity(0.82))
                .offset(x: edge == .leading ? -5 : 5)
        }
        .frame(width: 22, height: 68)
        .contentShape(Rectangle())
        .help(edge == .leading ? "Drag clip in point" : "Drag clip out point")
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if activeTrim == nil || activeTrim?.clipID != segment.id || activeTrim?.edge != edge {
                        activeTrim = ActiveTimelineTrim(
                            edge: edge,
                            clipID: segment.id,
                            sourceStart: segment.clip.sourceStart,
                            sourceEnd: segment.clip.sourceEnd,
                            timelineStart: segment.timelineStart,
                            timelineEnd: segment.timelineEnd,
                            speed: segment.clip.normalizedSpeed
                        )
                        model.beginTimelineTrim()
                        model.selectClip(segment.id)
                    }

                    guard let activeTrim else { return }
                    let timelineDelta = Double(value.translation.width / max(timelineWidth, 1)) * timelineDuration
                    switch edge {
                    case .leading:
                        let timeline = model.snappedTimelineTime(
                            activeTrim.timelineStart + timelineDelta,
                            threshold: snapThreshold(duration: timelineDuration, width: timelineWidth)
                        )
                        let source = activeTrim.sourceStart + (timeline - activeTrim.timelineStart) * activeTrim.speed
                        model.setClipStart(id: segment.id, sourceStart: source, seekToBoundary: true)
                    case .trailing:
                        let timeline = model.snappedTimelineTime(
                            activeTrim.timelineEnd + timelineDelta,
                            threshold: snapThreshold(duration: timelineDuration, width: timelineWidth)
                        )
                        let source = activeTrim.sourceEnd + (timeline - activeTrim.timelineEnd) * activeTrim.speed
                        model.setClipEnd(id: segment.id, sourceEnd: source, seekToBoundary: true)
                    }
                }
                .onEnded { _ in
                    activeTrim = nil
                    model.finishTimelineTrim()
                }
        )
    }

    private func playhead(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.purple)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(Color.purple)
                .frame(width: 2, height: max(height - 8, 0))
        }
        .shadow(color: Color.purple.opacity(0.38), radius: 5, x: 0, y: 0)
    }

    private func timelineTime(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(min(max(x, 0), max(width, 1)) / max(width, 1)) * duration
    }

    private func timelineTime(in segment: VideoDemoTimelineSegment, x: CGFloat, width: CGFloat, clamped: Bool = true) -> Double {
        let safeWidth = max(width, 1)
        let location = clamped ? min(max(x, 0), safeWidth) : x
        let progress = Double(location / safeWidth)
        return min(max(segment.timelineStart + segment.duration * progress, 0), max(model.timelineDuration, 0))
    }

    private func snapThreshold(duration: Double, width: CGFloat) -> Double {
        max(0.04, duration * Double(9 / max(width, 1)))
    }

    private func nextSpeed(after speed: Double) -> Double {
        let speeds = [0.5, 1.0, 1.5, 2.0]
        guard let index = speeds.firstIndex(where: { abs($0 - speed) < 0.01 }) else { return 1 }
        return speeds[(index + 1) % speeds.count]
    }

    private func rulerStep(for duration: Double) -> Double {
        switch duration {
        case 0..<8: return 1
        case 8..<20: return 2
        case 20..<60: return 5
        case 60..<180: return 15
        default: return 30
        }
    }

    private func tickValues(duration: Double) -> [Double] {
        let step = rulerStep(for: duration)
        var values = [0.0]
        var next = step
        while next < duration {
            values.append(next)
            next += step
        }
        if abs((values.last ?? 0) - duration) > 0.001 {
            values.append(duration)
        }
        return values
    }

    private func timeLabel(_ value: Double) -> String {
        let safe = max(value, 0)
        let minutes = Int(safe) / 60
        let seconds = Int(safe) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TimelineWaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let barCount = max(Int(rect.width / 5), 8)
        let step = rect.width / CGFloat(max(barCount - 1, 1))
        let midY = rect.midY

        for index in 0..<barCount {
            let phase = Double(index)
            let wave = abs(sin(phase * 0.72) + 0.42 * sin(phase * 1.87))
            let normalized = min(max(0.22 + wave * 0.48, 0.18), 0.95)
            let height = rect.height * CGFloat(normalized)
            let x = rect.minX + CGFloat(index) * step
            path.move(to: CGPoint(x: x, y: midY - height / 2))
            path.addLine(to: CGPoint(x: x, y: midY + height / 2))
        }

        return path
    }
}

private struct ShotnixVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private extension CMTime {
    var secondsValue: Double {
        let seconds = CMTimeGetSeconds(self)
        return seconds.isFinite ? max(seconds, 0) : 0
    }
}

private extension CGRect {
    var hasUsableVideoGeometry: Bool {
        origin.x.isFinite &&
        origin.y.isFinite &&
        size.width.isFinite &&
        size.height.isFinite &&
        width > 0 &&
        height > 0
    }
}

private extension CGAffineTransform {
    var hasFiniteComponents: Bool {
        a.isFinite &&
        b.isFinite &&
        c.isFinite &&
        d.isFinite &&
        tx.isFinite &&
        ty.isFinite
    }
}
