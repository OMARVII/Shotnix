import AppKit
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
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
    // Presented as "Redact" — the case name / rawValue stays "blur" so existing saved drafts keep decoding.
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .highlight: return "Highlight"
        case .blur: return "Redact"
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
    /// Timeline lane. Stored explicitly so horizontal drags never re-layer
    /// the pill under the cursor; vertical drags change it deliberately.
    var layer: Int

    init(
        id: UUID = UUID(),
        kind: VideoDemoOverlayEffectKind,
        time: Double,
        duration: Double = 2,
        x: Double = 0.5,
        y: Double = 0.5,
        width: Double = 0.28,
        height: Double = 0.14,
        text: String = "Callout",
        layer: Int = 0
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
        self.layer = layer
    }

    // Custom decode so drafts saved before `layer` existed keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(VideoDemoOverlayEffectKind.self, forKey: .kind)
        time = try container.decode(Double.self, forKey: .time)
        duration = try container.decode(Double.self, forKey: .duration)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        text = try container.decode(String.self, forKey: .text)
        layer = try container.decodeIfPresent(Int.self, forKey: .layer) ?? 0
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

    /// Makes effect layers consistent: each effect keeps its chosen layer
    /// unless it overlaps an earlier effect on that layer (then it takes the
    /// next free one), and empty layers are compacted away. Returns the
    /// effects sorted by time. Runs at load (drafts saved before layers
    /// existed decode as all-zero) and when a drag ends — never mid-drag,
    /// which is what kept re-layering pills under the cursor.
    static func normalizedEffectLayers(_ effects: [VideoDemoOverlayEffect]) -> [VideoDemoOverlayEffect] {
        var placed: [VideoDemoOverlayEffect] = []
        let ordered = effects.sorted {
            $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString
        }
        for var effect in ordered {
            let start = effect.time
            let end = effect.time + max(effect.duration, 0.05)
            func conflicts(_ layer: Int) -> Bool {
                placed.contains {
                    $0.layer == layer && $0.time < end - 0.0001 && ($0.time + max($0.duration, 0.05)) > start + 0.0001
                }
            }
            var layer = max(effect.layer, 0)
            while conflicts(layer) { layer += 1 }
            effect.layer = layer
            placed.append(effect)
        }

        // Compact: remap the used layers onto 0...n with no gaps.
        let usedLayers = Set(placed.map(\.layer)).sorted()
        let remap = Dictionary(uniqueKeysWithValues: usedLayers.enumerated().map { ($0.element, $0.offset) })
        return placed.map { effect in
            var updated = effect
            updated.layer = remap[effect.layer] ?? 0
            return updated
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
        let base = aspectPreset.canvasSize(sourceSize: sourceSize)
        guard !usesRawSourceFrame, sourceWidth > 0, sourceHeight > 0 else { return base }

        // NEVER upscale the recording. A small area capture stretched to fill
        // a fixed 1920x1080 stage — then zoomed on top — is what made
        // recordings look mushy in both preview and export. When the source
        // has fewer pixels than the stage would give it, shrink the whole
        // canvas proportionally so the video renders 1:1 at native pixels:
        // identical composition, sharp output.
        let stage = stageRect(in: base)
        guard stage.width > 0, stage.height > 0 else { return base }
        let factor = sourceSize.width / stage.width
        guard factor < 1 else { return base }

        func even(_ value: CGFloat) -> CGFloat {
            let rounded = max(2, Int(value.rounded()))
            return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
        }
        return CGSize(width: even(base.width * factor), height: even(base.height * factor))
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

    /// THE single source of truth for how zoom renders, shared verbatim by the
    /// preview and the export (they used to disagree — anchor-zoom in preview,
    /// center-the-focus in export).
    ///
    /// Model: the camera looks at the whole composed CANVAS (background +
    /// video). At scale s the visible window is a
    /// canvas/s crop centered on the focus point (mapped through the stage),
    /// clamped inside the canvas. Because the canvas extends past the video,
    /// a focus near the video's corner still centers — the background fills
    /// the slack — and nothing beyond the canvas can ever appear, so black
    /// regions are impossible by construction.
    ///
    /// Returned in TOP-LEFT canvas coordinates; the export converts to
    /// CALayer's bottom-left space at its boundary.
    func zoomWindow(in canvasSize: CGSize, at time: Double) -> CGRect {
        let full = CGRect(origin: .zero, size: canvasSize)
        let zoom = zoomState(at: time)
        guard zoom.scale > 1.001, canvasSize.width > 0, canvasSize.height > 0 else { return full }

        let stageBL = stageRect(in: canvasSize)
        let stageTop = CGRect(
            x: stageBL.minX,
            y: canvasSize.height - stageBL.maxY,
            width: stageBL.width,
            height: stageBL.height
        )
        // focusX/focusY are video-normalized with y pointing DOWN (same
        // convention as recorded clicks and the preview overlays).
        let focus = CGPoint(
            x: stageTop.minX + stageTop.width * min(max(zoom.focusX, 0), 1),
            y: stageTop.minY + stageTop.height * min(max(zoom.focusY, 0), 1)
        )
        let width = canvasSize.width / zoom.scale
        let height = canvasSize.height / zoom.scale
        return CGRect(
            x: min(max(focus.x - width / 2, 0), canvasSize.width - width),
            y: min(max(focus.y - height / 2, 0), canvasSize.height - height),
            width: width,
            height: height
        )
    }

    /// Static (unzoomed) canvas position for a video-normalized point, in
    /// CALayer bottom-left coordinates. Export overlays live inside the scene
    /// layer, whose animated transform applies the zoom — so their own
    /// coordinates must stay unzoomed.
    func canvasPoint(for normalizedPoint: CGPoint, in canvasSize: CGSize, at time: Double) -> CGPoint {
        let stage = stageRect(in: canvasSize)
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
        overlayEffects = Self.normalizedEffectLayers(
            try container.decodeIfPresent([VideoDemoOverlayEffect].self, forKey: .overlayEffects) ?? []
        )
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
    let fps: Double
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
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        return VideoDemoMetadata(
            duration: seconds(try await asset.load(.duration)),
            sourceSize: try await orientedSize(for: videoTrack),
            fps: nominalFrameRate > 1 ? nominalFrameRate : 30
        )
    }

    /// Returns user-facing warnings for non-fatal problems (currently audio segments
    /// that could not be added to the composition).
    @discardableResult
    static func export(
        project: VideoDemoProject,
        destinationURL: URL,
        options: VideoDemoExportOptions = VideoDemoExportOptions(),
        progress: @escaping @Sendable (Double) async -> Void = { _ in },
        shouldCancel: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> [String] {
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
        var audioWarnings: [String] = []
        for sourceAudioTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                audioWarnings.append("Could not prepare an audio track, so the export may be missing audio.")
                continue
            }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            for segment in timelineSegments {
                guard !segment.clip.muted else { continue }
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: segment.clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.clip.sourceDuration, preferredTimescale: 600)
                )
                let timelineStart = CMTime(seconds: segment.timelineStart, preferredTimescale: 600)
                do {
                    try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timelineStart)
                } catch {
                    // A silently dropped insert would export without this clip's audio and
                    // desync everything after it — surface the problem instead.
                    audioWarnings.append(String(
                        format: "Audio for the clip at %.1fs could not be included (%@).",
                        segment.timelineStart,
                        error.localizedDescription
                    ))
                    continue
                }
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

        var renderSize = exportProject.canvasSize()
        if options.halfResolution {
            renderSize = CGSize(width: evenPixels(renderSize.width / 2), height: evenPixels(renderSize.height / 2))
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))

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
            duration: compositionDuration.secondsValue,
            sourceTotalDuration: totalDuration,
            endCard: options.endCard && options.format == .mp4
        )
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: layers.videoLayer,
            in: layers.parentLayer
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // GIF goes through a temp MP4 first: the Core Animation overlay tool
        // (background, zooms, cursor, callouts) only renders through an export
        // session, so the GIF pass transcodes the finished MP4 frames.
        let isGIF = options.format == .gif
        let mp4URL = isGIF
            ? FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-gif-\(UUID().uuidString).mp4")
            : destinationURL
        let mp4ProgressShare = isGIF ? 0.62 : 1.0

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoDemoExportError.cannotCreateExportSession
        }
        exportSession.outputURL = mp4URL
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
                await progress(Double(exportBox.session.progress) * mp4ProgressShare)
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
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportBox.session.error?.localizedDescription ?? "Video export failed."
                    continuation.resume(throwing: VideoDemoExportError.exportFailed(message))
                default:
                    continuation.resume(throwing: VideoDemoExportError.exportFailed("Video export ended unexpectedly."))
                }
            }
        }

        if isGIF {
            defer { try? FileManager.default.removeItem(at: mp4URL) }
            try await transcodeToGIF(
                from: mp4URL,
                to: destinationURL,
                fps: 15,
                maxWidth: 1280,
                progress: { value in
                    await progress(mp4ProgressShare + value * (1 - mp4ProgressShare))
                },
                shouldCancel: shouldCancel
            )
        }

        await progress(1)
        return audioWarnings
    }

    /// Reads the rendered MP4 back frame by frame and writes an infinitely
    /// looping GIF — sampled at `fps`, downscaled to at most `maxWidth`.
    /// READMEs and pull requests can't embed MP4s; this is the export they need.
    private static func transcodeToGIF(
        from sourceURL: URL,
        to destinationURL: URL,
        fps: Double,
        maxWidth: CGFloat,
        progress: @escaping @Sendable (Double) async -> Void,
        shouldCancel: @escaping @Sendable () async -> Bool
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDemoExportError.missingVideoTrack
        }
        let duration = seconds(try await asset.load(.duration))
        let naturalSize = try await track.load(.naturalSize)
        guard naturalSize.width > 0, naturalSize.height > 0, duration > 0 else {
            throw VideoDemoExportError.exportFailed("Nothing to write into the GIF.")
        }
        let scale = min(1, maxWidth / naturalSize.width)
        let outputSize = CGSize(
            width: max((naturalSize.width * scale).rounded(), 2),
            height: max((naturalSize.height * scale).rounded(), 2)
        )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoDemoExportError.exportFailed("Could not read frames for the GIF.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Could not read frames for the GIF.")
        }

        let estimatedFrames = max(Int(duration * fps), 1)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            estimatedFrames,
            nil
        ) else {
            throw VideoDemoExportError.exportFailed("Could not create the GIF file.")
        }
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)
        let frameDelay = 1.0 / fps
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                kCGImagePropertyGIFDelayTime: frameDelay,
            ]
        ] as CFDictionary

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let downscale = CGAffineTransform(
            scaleX: outputSize.width / naturalSize.width,
            y: outputSize.height / naturalSize.height
        )
        var nextFrameTime = 0.0
        var written = 0

        while let sample = output.copyNextSampleBuffer() {
            if await shouldCancel() {
                reader.cancelReading()
                throw VideoDemoExportError.exportFailed("Export cancelled.")
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample).secondsValue
            guard presentationTime + 0.0001 >= nextFrameTime,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let frame = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: downscale)
            guard let cgImage = ciContext.createCGImage(frame, from: CGRect(origin: .zero, size: outputSize)) else {
                continue
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
            written += 1
            nextFrameTime += frameDelay
            if written.isMultiple(of: 8) {
                await progress(min(Double(written) / Double(estimatedFrames), 1))
                await Task.yield()
            }
        }

        if reader.status == .failed {
            throw VideoDemoExportError.exportFailed(reader.error?.localizedDescription ?? "Could not read frames for the GIF.")
        }
        guard written > 0, CGImageDestinationFinalize(destination) else {
            throw VideoDemoExportError.exportFailed("Could not write the GIF.")
        }
    }

    private static func evenPixels(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded()))
        return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
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

    /// The video track gets ONE static transform: fit into the (unzoomed)
    /// stage. Zoom is no longer applied per-track — the whole scene layer
    /// (background + video + overlays) animates together through the shared
    /// `zoomWindow` model, so the export moves exactly like the preview.
    private static func applyZoomTransforms(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        track: AVAssetTrack,
        project: VideoDemoProject,
        sourceSize: CGSize,
        renderSize: CGSize,
        timelineSegments: [VideoDemoTimelineSegment]
    ) async throws {
        let rect = project.stageRect(in: renderSize)
        layerInstruction.setTransform(
            try await exportTransform(for: track, project: project, sourceSize: sourceSize, renderSize: renderSize, targetRect: rect),
            at: .zero
        )
    }

    /// Samples `zoomWindow` at 30Hz across the timeline (mapping timeline →
    /// source time through cuts and speed changes) and drives the scene
    /// layer's transform with one keyframe animation — the same eased values
    /// the preview reads, so what you scrub is what exports.
    private static func addSceneZoomAnimation(
        to scene: CALayer,
        project: VideoDemoProject,
        renderSize: CGSize,
        duration: Double,
        sourceTotalDuration: Double
    ) {
        guard !project.zoomKeyframes.isEmpty, duration > 0 else { return }

        let sampleRate = 30.0
        let count = max(Int(duration * sampleRate) + 1, 2)
        var values: [NSValue] = []
        var keyTimes: [NSNumber] = []
        values.reserveCapacity(count)
        keyTimes.reserveCapacity(count)

        for index in 0..<count {
            let timelineTime = min(Double(index) / sampleRate, duration)
            let sourceTime = project.sourceTime(forTimelineTime: timelineTime, totalDuration: sourceTotalDuration)
            let window = project.zoomWindow(in: renderSize, at: sourceTime)
            let scale = renderSize.width / max(window.width, 1)
            // zoomWindow is top-left; CALayer space is bottom-left.
            let windowBottomY = renderSize.height - window.maxY
            var transform = CATransform3DMakeTranslation(-window.minX * scale, -windowBottomY * scale, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            values.append(NSValue(caTransform3D: transform))
            keyTimes.append(NSNumber(value: timelineTime / duration))
        }

        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = duration
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        scene.add(animation, forKey: "sceneZoom")
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
        duration: Double,
        sourceTotalDuration: Double,
        endCard: Bool = false
    ) -> (videoLayer: CALayer, parentLayer: CALayer) {
        let bounds = CGRect(origin: .zero, size: renderSize)
        let stage = project.stageRect(in: renderSize)

        let parent = CALayer()
        parent.frame = bounds
        parent.backgroundColor = project.backgroundPreset.exportColor.cgColor
        parent.masksToBounds = true

        // Everything that zooms lives on the scene layer — background, video,
        // border, callouts, cursor — and one animated transform (driven by the
        // shared zoomWindow model) moves it all in lockstep with the preview.
        // Only the end card sits outside, so it never zooms.
        let scene = CALayer()
        scene.bounds = bounds
        scene.anchorPoint = .zero
        scene.position = .zero
        parent.addSublayer(scene)

        // WYSIWYG: the preview paints a gradient (or a blur-able custom image);
        // the export used to paint a flat color and ignore the blur slider.
        let background: CALayer
        if !project.usesRawSourceFrame,
           let url = project.customBackgroundURL,
           let image = NSImage(contentsOf: url),
           let cgImage = image.bestCGImage {
            let imageLayer = CALayer()
            imageLayer.contents = blurredBackground(cgImage, blur: project.backgroundBlur, renderWidth: renderSize.width) ?? cgImage
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.masksToBounds = true
            background = imageLayer
        } else {
            let gradient = CAGradientLayer()
            gradient.colors = project.backgroundPreset.previewColors.map { NSColor($0).cgColor }
            // Preview is topLeading → bottomTrailing; CALayer unit space has
            // its origin at the bottom-left on macOS.
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            background = gradient
        }
        background.frame = bounds
        background.backgroundColor = project.backgroundPreset.exportColor.cgColor
        scene.addSublayer(background)

        if !project.usesRawSourceFrame {
            let shadow = CALayer()
            shadow.frame = stage
            shadow.cornerRadius = max(project.effectiveCornerRadius, 0)
            shadow.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = Float(max(0, min(project.effectiveShadowStrength, 0.85)))
            shadow.shadowRadius = 34
            shadow.shadowOffset = CGSize(width: 0, height: -20)
            scene.addSublayer(shadow)
        }

        // The video renders into videoLayer at full canvas coordinates; a
        // rounded-rect mask on its container clips overflow to the stage —
        // replacing the old flat rectangular cover layers, which both broke
        // gradient backgrounds and left the video's corners square while the
        // preview showed them rounded.
        let videoLayer = CALayer()
        videoLayer.frame = bounds
        let videoContainer = CALayer()
        videoContainer.frame = bounds
        videoContainer.addSublayer(videoLayer)
        if !project.usesRawSourceFrame {
            let radius = max(project.effectiveCornerRadius, 0)
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = CGPath(
                roundedRect: stage,
                cornerWidth: min(radius, stage.width / 2),
                cornerHeight: min(radius, stage.height / 2),
                transform: nil
            )
            mask.fillColor = NSColor.black.cgColor
            videoContainer.mask = mask
        }
        scene.addSublayer(videoContainer)

        if !project.usesRawSourceFrame {
            let border = CALayer()
            border.frame = stage
            border.cornerRadius = max(project.effectiveCornerRadius, 0)
            border.borderWidth = 2
            border.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            scene.addSublayer(border)
        }

        addOverlayEffectLayers(
            to: scene,
            project: project,
            renderSize: renderSize,
            timelineSegments: timelineSegments,
            duration: duration
        )

        if project.clickSpotlight {
            addClickSpotlightLayers(
                to: scene,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }
        if project.showClickRipple {
            addClickLayers(
                to: scene,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }
        if project.showCursorOverlay {
            addCursorLayer(
                to: scene,
                project: project,
                renderSize: renderSize,
                timelineSegments: timelineSegments,
                duration: duration
            )
        }

        addSceneZoomAnimation(
            to: scene,
            project: project,
            renderSize: renderSize,
            duration: duration,
            sourceTotalDuration: sourceTotalDuration
        )

        if endCard {
            addEndCardLayer(to: parent, bounds: bounds, duration: duration)
        }

        return (videoLayer, parent)
    }

    /// Pre-blurs the custom background image so the export matches the
    /// preview's blur slider. The radius scales with the render width because
    /// the slider was tuned against the on-screen preview size.
    private static func blurredBackground(_ cgImage: CGImage, blur: Double, renderWidth: CGFloat) -> CGImage? {
        guard blur > 0.5 else { return nil }
        let radius = blur * Double(max(renderWidth, 1)) / 900.0
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(output, from: input.extent)
    }

    /// Short "Made with Shotnix" outro over the last moments of the export.
    /// Skipped for clips too short to carry it.
    private static func addEndCardLayer(to parent: CALayer, bounds: CGRect, duration: Double) {
        let cardDuration = 1.6
        guard duration > cardDuration + 2.5 else { return }

        let card = CALayer()
        card.frame = bounds
        card.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.06, alpha: 1).cgColor
        card.opacity = 0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = AVCoreAnimationBeginTimeAtZero + duration - cardDuration
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        card.add(fade, forKey: "endCardFade")

        let iconSize = bounds.width * 0.085
        if let icon = NSImage(named: NSImage.applicationIconName)?.bestCGImage {
            let iconLayer = CALayer()
            iconLayer.contents = icon
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.frame = CGRect(
                x: bounds.midX - iconSize / 2,
                y: bounds.midY + bounds.height * 0.015,
                width: iconSize,
                height: iconSize
            )
            card.addSublayer(iconLayer)
        }

        let title = CATextLayer()
        title.string = "Made with Shotnix"
        let titleSize = bounds.width * 0.030
        title.font = NSFont.systemFont(ofSize: titleSize, weight: .bold)
        title.fontSize = titleSize
        title.foregroundColor = NSColor.white.cgColor
        title.alignmentMode = .center
        title.contentsScale = 2
        title.frame = CGRect(
            x: 0,
            y: bounds.midY - bounds.height * 0.045 - titleSize,
            width: bounds.width,
            height: titleSize * 1.4
        )
        card.addSublayer(title)

        let link = CATextLayer()
        link.string = "shotnix.com — free & open source"
        let linkSize = bounds.width * 0.017
        link.font = NSFont.systemFont(ofSize: linkSize, weight: .semibold)
        link.fontSize = linkSize
        link.foregroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        link.alignmentMode = .center
        link.contentsScale = 2
        link.frame = CGRect(
            x: 0,
            y: title.frame.minY - linkSize * 2.0,
            width: bounds.width,
            height: linkSize * 1.4
        )
        card.addSublayer(link)

        parent.addSublayer(card)
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
            // Static stage coords: the scene transform applies the zoom.
            let stage = project.stageRect(in: renderSize)
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
                // Redact: an opaque cover so the content underneath stays fully hidden.
                let redact = CALayer()
                redact.frame = frame
                redact.cornerRadius = 16
                redact.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
                redact.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
                redact.borderWidth = 1
                redact.masksToBounds = true
                layer = redact
            }

            if effect.kind == .blur {
                // Redact must never be semi-transparent: hold opacity at 1 for the
                // whole window, with a hard on/off matching the preview. fillMode
                // defaults to .removed, so the layer shows its model opacity (0)
                // outside the window. Do not add fillMode = .both here, or the
                // cover would persist outside the redaction window.
                let visibility = CAKeyframeAnimation(keyPath: "opacity")
                visibility.calculationMode = .discrete
                visibility.values = [1]
                visibility.keyTimes = [0, 1]
                visibility.beginTime = AVCoreAnimationBeginTimeAtZero + entry.timelineTime
                visibility.duration = entry.duration
                visibility.isRemovedOnCompletion = false
                layer.opacity = 0
                layer.add(visibility, forKey: "visibility")
            } else {
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
            }
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
        // NEVER .paced here: paced mode discards keyTimes and re-times the
        // whole path for constant velocity, so the exported cursor drifted
        // uniformly across the clip — desynced from clicks, zooms, and the
        // preview whenever the real cursor paused. .cubic smooths the path
        // while honoring the recorded timestamps.
        animation.calculationMode = project.smoothCursor ? .cubic : .linear
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

/// Carries the 30Hz playhead signal separately from the editor model so only
/// the views that actually draw the playhead re-render on every tick.
@MainActor
final class VideoDemoPlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class VideoDemoEditorViewModel: ObservableObject {
    @Published var project: VideoDemoProject {
        didSet {
            cachedSnapPoints = nil
            scheduleAutosave()
        }
    }
    @Published var duration: Double = 0 {
        didSet { cachedSnapPoints = nil }
    }

    /// Views that track the playhead observe this instead of the model — the
    /// 30Hz playback tick must not re-render the entire editor.
    let playbackClock = VideoDemoPlaybackClock()

    /// Source-time of the playhead. Deliberately NOT @Published: per-tick
    /// invalidation of the whole editor is what made playback and scrubbing
    /// feel heavy. The clock above carries the per-tick signal.
    var currentTime: Double = 0 {
        didSet { playbackClock.time = currentTime }
    }
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
    @Published var selectedClickID: UUID?
    @Published var timelineThumbnails: [VideoTimelineThumbnail] = []
    @Published var selectedTimelineRange: VideoDemoTimelineRange?
    @Published var timelineEditFlash: VideoDemoTimelineRange?
    @Published var timelineZoom: Double = 1

    /// Preview-only mute: silences the editor player while reviewing.
    /// Uses `isMuted` so the continuous fade-ramp volume writes don't fight
    /// it, and the export audio mix is never affected.
    @Published var previewMuted = false {
        didSet { player.isMuted = previewMuted }
    }

    let player: AVPlayer
    private var didLoadMetadata = false
    private var timeObserver: Any?
    private var sourceFPS: Double = 30
    private var shuttleRate: Double = 1
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
            sourceFPS = metadata.fps

            var isFreshRecording = false
            if let draft = VideoDemoDraftStore.load(for: project.sourceURL),
               draft.sourcePath == project.sourceURL.standardizedFileURL.path {
                project = draft.project
                restoredDraftNotice = "Draft restored"
                status = "Draft restored"
            } else if let sidecar = VideoDemoSidecarStore.load(for: project.sourceURL) {
                project.apply(metadata: sidecar)
                isFreshRecording = true
            }
            project.sourceWidth = Double(metadata.sourceSize.width)
            project.sourceHeight = Double(metadata.sourceSize.height)
            if project.trimEnd <= 0 || project.trimEnd > metadata.duration {
                project.trimEnd = metadata.duration
            }
            project.ensureTimeline(totalDuration: metadata.duration)
            selectedClipID = project.timelineClips.first?.id

            // Auto-polish: a fresh recording opens already "produced" — zooms
            // follow the recorded clicks with zero editing. Undoable (the
            // generator pushes an undo snapshot), clearable in the Zoom panel,
            // and off-switchable in Preferences → Recording.
            if isFreshRecording,
               Settings.autoZoomNewRecordings,
               project.zoomKeyframes.isEmpty,
               !project.clickEvents.isEmpty {
                addAutoZoomPreset()
                selectedZoomID = nil
                status = "Auto-zoom applied — tweak or clear it in the Zoom panel"
            }
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

    /// True while a scrub drag is active — seeks run with loose tolerance so
    /// AVPlayer can land on nearby keyframes fast. Ending a scrub re-issues
    /// the final position exactly.
    var isScrubbing = false {
        didSet {
            if oldValue && !isScrubbing {
                requestSeek(to: currentTime)
            }
        }
    }

    private var seekInFlight = false
    private var pendingSeekSeconds: Double?

    func seek(to seconds: Double) {
        let safe = min(max(seconds, 0), max(duration, 0))
        currentTime = safe
        requestSeek(to: safe)
    }

    /// Chained seeking: at most one AVPlayer seek in flight. While one runs,
    /// only the LATEST requested time is kept; the completion issues it. The
    /// old per-drag-tick zero-tolerance seeks piled up inside AVPlayer and made
    /// scrubbing long recordings feel like a slideshow.
    private func requestSeek(to seconds: Double) {
        guard !seekInFlight else {
            pendingSeekSeconds = seconds
            return
        }
        seekInFlight = true
        let tolerance: CMTime = isScrubbing ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                if let pending = self.pendingSeekSeconds {
                    self.pendingSeekSeconds = nil
                    self.requestSeek(to: pending)
                }
            }
        }
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
        shuttleRate = 1
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
        shuttleRate = 1
        player.pause()
    }

    func stepFrame(by frames: Int) {
        shuttleRate = 1
        player.pause()
        seekToTimeline(timelineTime + Double(frames) / max(sourceFPS, 1))
    }

    /// J in the J/K/L shuttle. Reverse playback is approximated by pausing and jumping back one second.
    func shuttleReverse() {
        shuttleRate = 1
        player.pause()
        seekToTimeline(timelineTime - 1)
    }

    /// K in the J/K/L shuttle.
    func shuttlePause() {
        shuttleRate = 1
        player.pause()
    }

    /// L in the J/K/L shuttle: play, and speed up to 2x on repeated presses.
    func shuttlePlay() {
        if player.timeControlStatus == .playing {
            shuttleRate = min(shuttleRate + 0.5, 2)
            updatePlaybackRate()
            status = String(format: "Shuttle %.1fx", shuttleRate)
        } else {
            playPause()
        }
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
        selectedClickID = nil
        selectedTimelineRange = nil
    }

    func selectZoom(_ id: UUID) {
        selectedZoomID = id
        selectedEffectID = nil
        selectedClickID = nil
        selectedTimelineRange = nil
    }

    func selectEffect(_ id: UUID) {
        selectedEffectID = id
        selectedZoomID = nil
        selectedClickID = nil
        selectedTimelineRange = nil
    }

    // MARK: - Stage editing of overlay effects

    // Coalesced undo for continuous drags (stage callouts, timeline pills,
    // zoom blocks, click dots): one whole gesture is a single undo step.
    private var effectStageEditUndoPushed = false

    private func beginEffectStageEditIfNeeded() {
        guard !effectStageEditUndoPushed else { return }
        pushUndo()
        effectStageEditUndoPushed = true
    }

    func endEffectStageEdit() {
        effectStageEditUndoPushed = false
        // Settle layers only when the gesture ends — normalizing mid-drag is
        // what made pills re-layer under the cursor.
        project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
    }

    /// Moves a callout to another timeline lane (vertical pill drag). The
    /// value is applied raw during the drag; conflicts and gaps settle in
    /// `endEffectStageEdit`.
    func setEffectLayer(id: UUID, layer: Int) {
        guard let index = project.overlayEffects.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(layer, 0), 7)
        guard project.overlayEffects[index].layer != clamped else { return }
        beginEffectStageEditIfNeeded()
        project.overlayEffects[index].layer = clamped
        selectedEffectID = id
    }

    /// Pill editing on the Effects lane: sets when a
    /// callout appears and disappears. Inputs are timeline seconds; storage
    /// stays in source seconds so cuts and clip speeds keep working.
    func setEffectWindow(id: UUID, timelineStart: Double, timelineEnd: Double) {
        guard let index = project.overlayEffects.firstIndex(where: { $0.id == id }) else { return }
        beginEffectStageEditIfNeeded()
        let start = min(max(timelineStart, 0), max(timelineDuration - 0.2, 0))
        let end = min(max(timelineEnd, start + 0.2), max(timelineDuration, 0.2))
        let startSource = project.sourceTime(forTimelineTime: start, totalDuration: duration)
        let endSource = project.sourceTime(forTimelineTime: end, totalDuration: duration)
        project.overlayEffects[index].time = startSource
        project.overlayEffects[index].duration = max(endSource - startSource, 0.2)
        selectedEffectID = id
    }

    /// Moves a callout's center to normalized stage coordinates.
    func moveEffect(id: UUID, toX x: Double, y: Double) {
        guard let index = project.overlayEffects.firstIndex(where: { $0.id == id }) else { return }
        beginEffectStageEditIfNeeded()
        project.overlayEffects[index].x = min(max(x, 0.02), 0.98)
        project.overlayEffects[index].y = min(max(y, 0.02), 0.98)
        selectedEffectID = id
    }

    /// Sets a callout's normalized center and size in one shot (corner resize).
    func resizeEffect(id: UUID, x: Double, y: Double, width: Double, height: Double) {
        guard let index = project.overlayEffects.firstIndex(where: { $0.id == id }) else { return }
        beginEffectStageEditIfNeeded()
        project.overlayEffects[index].x = min(max(x, 0.02), 0.98)
        project.overlayEffects[index].y = min(max(y, 0.02), 0.98)
        project.overlayEffects[index].width = min(max(width, 0.04), 0.9)
        project.overlayEffects[index].height = min(max(height, 0.04), 0.6)
        selectedEffectID = id
    }

    func selectClick(_ id: UUID) {
        selectedClickID = id
        selectedZoomID = nil
        selectedEffectID = nil
        selectedTimelineRange = nil
        status = "Click selected — drag to retime, Delete to remove"
    }

    /// Recorded clicks drive ripples, spotlights, and Auto Zoom planning —
    /// a stray click used to be uneditable. Retiming keeps the click's screen
    /// position; re-run Auto Zoom afterwards to re-plan the camera.
    func moveClick(id: UUID, toTimelineTime timelineTime: Double) {
        guard let index = project.clickEvents.firstIndex(where: { $0.id == id }) else { return }
        beginEffectStageEditIfNeeded()
        let safeTimeline = min(max(timelineTime, 0), max(timelineDuration, 0))
        let sourceTime = project.sourceTime(forTimelineTime: safeTimeline, totalDuration: duration)
        project.clickEvents[index].time = sourceTime
        project.clickEvents.sort { $0.time < $1.time }
        selectedClickID = id
        seekToTimeline(safeTimeline)
        status = "Click moved — run Auto Zoom to re-plan the camera"
    }

    func deleteSelectedClick() {
        guard let selectedClickID else { return }
        pushUndo()
        project.clickEvents.removeAll { $0.id == selectedClickID }
        self.selectedClickID = nil
        status = "Click removed"
        ToastWindow.show(message: "Click removed. Press Cmd-Z to undo.", duration: 2.4)
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
        selectedEffectID = nil
        selectedClickID = nil
        selectedZoomID = nil
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

    /// Tuning for the auto-zoom shot planner. Times are seconds of edited
    /// timeline; distances are in video-normalized focus space.
    private enum AutoZoomTuning {
        static let clusterGap = 1.35        // clicks within this gap form one cluster
        static let mergeDistance = 0.15     // clusters this close in focus space share one shot
        static let mergeWindow = 3.5        // ...if the next cluster starts within this many seconds
        static let zoomInDuration = 0.65
        static let zoomOutDuration = 0.9
        static let minimumHold = 0.6
        static let holdTail = 0.85          // keep holding this long after the shot's last click
        static let leadBeforeClick = 0.06   // camera settles just before the click lands
        static let minimumPan = 0.55
        static let maximumPan = 1.2
        static let panDistanceFactor = 1.4  // pan duration grows with focus distance
        static let outInBreather = 1.6      // unzoomed time required to prefer zoom-out/in over a pan
        static let maximumShots = 8
    }

    func addAutoZoomPreset() {
        let segments = timelineSegments
        guard !segments.isEmpty else { return }
        let editedDuration = max(timelineDuration, 0.1)
        let targets = Array(autoZoomTargets().prefix(AutoZoomTuning.maximumShots))

        pushUndo()
        project.zoomKeyframes.removeAll()
        var generated: [VideoDemoZoomKeyframe] = []
        appendAutoZoomKeyframe(&generated, timelineTime: 0, scale: 1, focusX: 0.5, focusY: 0.5)

        if targets.isEmpty {
            let midpoint = editedDuration * 0.45
            appendAutoZoomKeyframe(&generated, timelineTime: max(midpoint - AutoZoomTuning.zoomInDuration, 0), scale: 1, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: midpoint, scale: 1.42, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: min(midpoint + 1.6, editedDuration), scale: 1.42, focusX: 0.5, focusY: 0.5)
            appendAutoZoomKeyframe(&generated, timelineTime: min(midpoint + 1.6 + AutoZoomTuning.zoomOutDuration, editedDuration), scale: 1, focusX: 0.5, focusY: 0.5)
        } else {
            // Shot planner. Every camera move gets a real duration — a move is
            // never compressed below its minimum, even if that means settling
            // on a click a beat late; smooth beats punctual. Shots close in
            // time pan directly at hold scale (no zoom-out dip in between);
            // shots far apart zoom out, breathe at 1x, and zoom back in.
            var previousExit = 0.0
            var chainedArrival: Double?
            for index in targets.indices {
                let target = targets[index]
                let next = targets.indices.contains(index + 1) ? targets[index + 1] : nil

                let arrival: Double
                if let chained = chainedArrival {
                    // The previous shot's hold-end keyframe starts this pan.
                    arrival = chained
                } else {
                    let ideal = max(target.startTime - AutoZoomTuning.leadBeforeClick, 0)
                    let approach = max(previousExit, ideal - AutoZoomTuning.zoomInDuration)
                    arrival = approach + AutoZoomTuning.zoomInDuration
                    appendAutoZoomKeyframe(&generated, timelineTime: approach, scale: 1, focusX: target.focusX, focusY: target.focusY)
                }
                appendAutoZoomKeyframe(&generated, timelineTime: arrival, scale: target.scale, focusX: target.focusX, focusY: target.focusY)

                var holdEnd = max(arrival + AutoZoomTuning.minimumHold, target.endTime + AutoZoomTuning.holdTail)

                if let next {
                    let idealNextArrival = max(next.startTime - AutoZoomTuning.leadBeforeClick, 0)
                    let distance = ((next.focusX - target.focusX) * (next.focusX - target.focusX)
                        + (next.focusY - target.focusY) * (next.focusY - target.focusY)).squareRoot()
                    let panDuration = min(
                        max(AutoZoomTuning.minimumPan + distance * AutoZoomTuning.panDistanceFactor, AutoZoomTuning.minimumPan),
                        AutoZoomTuning.maximumPan
                    )
                    let roomToBreathe = AutoZoomTuning.zoomOutDuration + AutoZoomTuning.outInBreather + AutoZoomTuning.zoomInDuration

                    if idealNextArrival - holdEnd >= roomToBreathe {
                        appendAutoZoomKeyframe(&generated, timelineTime: holdEnd, scale: target.scale, focusX: target.focusX, focusY: target.focusY)
                        appendAutoZoomKeyframe(&generated, timelineTime: holdEnd + AutoZoomTuning.zoomOutDuration, scale: 1, focusX: target.focusX, focusY: target.focusY)
                        previousExit = holdEnd + AutoZoomTuning.zoomOutDuration
                        chainedArrival = nil
                    } else {
                        holdEnd = max(arrival + 0.4, min(holdEnd, idealNextArrival - panDuration))
                        appendAutoZoomKeyframe(&generated, timelineTime: holdEnd, scale: target.scale, focusX: target.focusX, focusY: target.focusY)
                        chainedArrival = max(idealNextArrival, holdEnd + panDuration)
                    }
                } else {
                    appendAutoZoomKeyframe(&generated, timelineTime: holdEnd, scale: target.scale, focusX: target.focusX, focusY: target.focusY)
                    appendAutoZoomKeyframe(&generated, timelineTime: min(holdEnd + AutoZoomTuning.zoomOutDuration, editedDuration), scale: 1, focusX: target.focusX, focusY: target.focusY)
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
        let startTime: Double
        let endTime: Double
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
               click.timelineTime - previous.timelineTime <= AutoZoomTuning.clusterGap {
                clusters[last].append(click)
            } else {
                clusters.append([click])
            }
        }

        struct Shot {
            var start: Double
            var end: Double
            var x: Double
            var y: Double
            var count: Int
        }

        let shots = clusters.compactMap { cluster -> Shot? in
            guard let first = cluster.first, let last = cluster.last else { return nil }
            let count = Double(cluster.count)
            return Shot(
                start: first.timelineTime,
                end: last.timelineTime,
                x: cluster.map(\.x).reduce(0, +) / count,
                y: cluster.map(\.y).reduce(0, +) / count,
                count: cluster.count
            )
        }

        // Re-targeting the camera for a focus it already covers reads as
        // jitter — spatially close consecutive shots merge into one longer
        // hold instead.
        var merged: [Shot] = []
        for shot in shots {
            if var last = merged.last,
               shot.start - last.end < AutoZoomTuning.mergeWindow,
               ((shot.x - last.x) * (shot.x - last.x) + (shot.y - last.y) * (shot.y - last.y)).squareRoot() < AutoZoomTuning.mergeDistance {
                let total = Double(last.count + shot.count)
                last.x = (last.x * Double(last.count) + shot.x * Double(shot.count)) / total
                last.y = (last.y * Double(last.count) + shot.y * Double(shot.count)) / total
                last.end = shot.end
                last.count += shot.count
                merged[merged.count - 1] = last
            } else {
                merged.append(shot)
            }
        }

        return merged.map { shot in
            AutoZoomTarget(
                startTime: shot.start,
                endTime: shot.end,
                focusX: softenedFocus(shot.x),
                focusY: softenedFocus(shot.y),
                scale: shot.count > 1 ? 1.74 : 1.66
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
        beginEffectStageEditIfNeeded()
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
        // Give the newcomer a free lane if it overlaps existing callouts.
        project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        selectEffect(effect.id)
        status = "\(kind.title) added"
    }

    func deleteSelectedEffect() {
        guard let selectedEffectID else { return }
        pushUndo()
        project.overlayEffects.removeAll { $0.id == selectedEffectID }
        // Deliberately no auto-advance: Delete is routed here from the key
        // handler, and advancing would let repeated presses silently mow
        // through every callout.
        self.selectedEffectID = nil
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
                    text: updated.text,
                    layer: updated.layer
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

    /// `excluding` drops the snap points contributed by that object — while
    /// an object is being dragged, its own start/end must not be snap
    /// targets, or every tick pulls it back toward where it already is and
    /// the drag visibly shakes.
    func snappedTimelineTime(_ time: Double, threshold: Double? = nil, excluding excludedSource: UUID? = nil) -> Double {
        let safe = min(max(time, 0), max(timelineDuration, 0))
        let snapThreshold = threshold ?? max(0.045, timelineDuration * 0.008)
        guard snapThreshold > 0 else { return safe }

        let nearest = timelineSnapPoints()
            .filter { excludedSource == nil || $0.source != excludedSource }
            .map { candidate in (point: candidate.point, distance: abs(candidate.point - safe)) }
            .min { $0.distance < $1.distance }

        guard let nearest, nearest.distance <= snapThreshold else { return safe }
        return min(max(nearest.point, 0), max(timelineDuration, 0))
    }

    /// Every input to the snap points flows through `project` (segments,
    /// clicks, keyframes, effects), so its didSet is the one invalidation
    /// point. Cached because snapping runs on every drag tick. Each point
    /// carries the id of the object that contributed it (nil for structural
    /// points like clip boundaries) so drags can exclude their own object.
    private var cachedSnapPoints: [(point: Double, source: UUID?)]?

    func timelineSnapPoints() -> [(point: Double, source: UUID?)] {
        if let cachedSnapPoints { return cachedSnapPoints }
        var points: [(point: Double, source: UUID?)] = [(0, nil), (timelineDuration, nil)]
        for segment in timelineSegments {
            points.append((segment.timelineStart, nil))
            points.append((segment.timelineEnd, nil))
        }
        for click in project.clickEvents {
            if let time = project.timelineTimeIfIncluded(sourceTime: click.time, totalDuration: duration) {
                points.append((time, click.id))
            }
        }
        for keyframe in project.zoomKeyframes {
            if let time = project.timelineTimeIfIncluded(sourceTime: keyframe.time, totalDuration: duration) {
                points.append((time, keyframe.id))
            }
        }
        for effect in project.overlayEffects {
            if let start = project.timelineTimeIfIncluded(sourceTime: effect.time, totalDuration: duration) {
                points.append((start, effect.id))
            }
            if let end = project.timelineTimeIfIncluded(sourceTime: effect.time + effect.duration, totalDuration: duration) {
                points.append((end, effect.id))
            }
        }
        cachedSnapPoints = points
        return points
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

        // Cmd+Left/Right (what compact keyboards produce for Home/End) jumps to the timeline start/end.
        if modifiers == [.command], event.keyCode == 123 {
            seekToTimeline(0)
            return true
        }

        if modifiers == [.command], event.keyCode == 124 {
            seekToTimeline(timelineDuration)
            return true
        }

        // Shift+arrows make coarse one-second jumps.
        if modifiers == [.shift], event.keyCode == 123 {
            seekToTimeline(timelineTime - 1)
            return true
        }

        if modifiers == [.shift], event.keyCode == 124 {
            seekToTimeline(timelineTime + 1)
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
            } else {
                previewMuted.toggle()
            }
            return true
        case "[":
            seekToTimeline(timelineTime - 0.25)
            return true
        case "]":
            seekToTimeline(timelineTime + 0.25)
            return true
        case ",":
            stepFrame(by: -1)
            return true
        case ".":
            stepFrame(by: 1)
            return true
        case "j":
            shuttleReverse()
            return true
        case "k":
            shuttlePause()
            return true
        case "l":
            shuttlePlay()
            return true
        default:
            break
        }

        switch event.keyCode {
        case 53:
            clearTimelineSelection()
            return true
        case 51, 117:
            if selectedEffectID != nil {
                deleteSelectedEffect()
            } else if selectedClickID != nil {
                deleteSelectedClick()
            } else {
                deleteSelectedClip()
            }
            return true
        case 123:
            seekToTimeline(timelineTime - 0.25)
            return true
        case 124:
            seekToTimeline(timelineTime + 0.25)
            return true
        case 115:
            seekToTimeline(0)
            return true
        case 119:
            seekToTimeline(timelineDuration)
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
        let optionsModel = VideoDemoExportOptionsModel(options: .fromSettings)
        panel.allowedContentTypes = optionsModel.options.format == .gif ? [.gif] : [.mpeg4Movie]
        panel.canCreateDirectories = true
        // timestampedName renders the user's template, which usually starts
        // with "Shotnix " — strip it so the default isn't "Shotnix Demo Shotnix …".
        let stamp = ImageExporter.timestampedName
        let cleanedStamp = stamp.hasPrefix("Shotnix ") ? String(stamp.dropFirst("Shotnix ".count)) : stamp
        panel.nameFieldStringValue = "Shotnix Demo \(cleanedStamp).\(optionsModel.options.fileExtension)"
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)

        // Format / fps / size / end-card choices live inside the save panel.
        let accessory = NSHostingView(rootView: VideoDemoExportAccessoryView(model: optionsModel))
        accessory.frame = NSRect(x: 0, y: 0, width: 560, height: 44)
        panel.accessoryView = accessory
        optionsModel.onFormatChange = { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = format == .gif ? [.gif] : [.mpeg4Movie]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format == .gif ? "gif" : "mp4")"
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let options = optionsModel.options
        options.saveAsDefaults()

        isExporting = true
        exportCancellationRequested = false
        exportProgress = 0.02
        exportDestinationURL = destination
        exportCompletedURL = nil
        exportErrorMessage = nil
        status = options.format == .gif ? "Exporting GIF..." : "Exporting..."
        let exportBridge = VideoDemoExportBridge(self)
        do {
            let audioWarnings = try await VideoDemoExporter.export(
                project: project,
                destinationURL: destination,
                options: options,
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
            if audioWarnings.isEmpty {
                status = "Exported \(destination.lastPathComponent)"
                ToastWindow.show(message: "Video exported: \(destination.lastPathComponent)", duration: 3.0)
            } else {
                status = "Exported with audio warnings"
                ToastWindow.show(
                    message: "Video exported with audio issues: \(audioWarnings.joined(separator: " "))",
                    duration: 4.5
                )
            }
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
                self.updatePreviewVolume(sourceTime: seconds)
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
        player.rate = Float(speed * shuttleRate)
    }

    /// Mirrors the export audio mix during preview: muted clips play silent and fade
    /// ramps attenuate the volume inside their fade windows (measured in timeline time).
    private func updatePreviewVolume(sourceTime: Double) {
        guard let segment = timelineSegments.first(where: { $0.contains(sourceTime: sourceTime) }) else {
            player.volume = 1
            return
        }
        guard !segment.clip.muted else {
            player.volume = 0
            return
        }

        var volume = 1.0
        let timelineOffset = segment.timelineTime(forSourceTime: sourceTime) - segment.timelineStart
        let fadeIn = min(max(segment.clip.fadeIn, 0), segment.duration / 2)
        if fadeIn > 0, timelineOffset < fadeIn {
            volume = min(volume, timelineOffset / fadeIn)
        }
        let fadeOut = min(max(segment.clip.fadeOut, 0), segment.duration / 2)
        let remaining = segment.duration - timelineOffset
        if fadeOut > 0, remaining < fadeOut {
            volume = min(volume, remaining / fadeOut)
        }
        player.volume = Float(min(max(volume, 0), 1))
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
            VideoDemoStageView(model: model, clock: model.playbackClock)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
            transport
            VideoDemoTimelineView(model: model, clock: model.playbackClock)
                .frame(height: VideoDemoTimelineView.preferredHeight(for: model.project))
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

            VideoDemoTransportClockView(model: model, clock: model.playbackClock)

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

            Divider()
                .frame(height: 16)
                .overlay(Color.white.opacity(0.14))

            Button {
                model.previewMuted.toggle()
            } label: {
                Image(systemName: model.previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.previewMuted ? Color.orange : Color.white.opacity(0.86))
            .help(model.previewMuted ? "Unmute preview" : "Mute preview — export audio is not affected")
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
        Text((model.exportCompletedURL ?? model.exportDestinationURL)?.lastPathComponent ?? "Export Video")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportStatusTitle: String {
        if model.isExporting { return "Exporting" }
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
                Text(model.isExporting ? "Exporting" : "Export…")
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
            command("play-pause", "Play / Pause", "Transport", "playpause.fill", "Space") {
                model.playPause()
            },
            command("step-back", "Step Back One Frame", "Transport", "backward.frame", ",") {
                model.stepFrame(by: -1)
            },
            command("step-forward", "Step Forward One Frame", "Transport", "forward.frame", ".") {
                model.stepFrame(by: 1)
            },
            command("jump-start", "Jump to Start", "Transport", "backward.end", "Home") {
                model.seekToTimeline(0)
            },
            command("jump-end", "Jump to End", "Transport", "forward.end", "End") {
                model.seekToTimeline(model.timelineDuration)
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
            command("export", model.isExporting ? "Cancel Export" : "Export Video", model.isExporting ? "In progress" : "Edited composition", model.isExporting ? "xmark" : "square.and.arrow.up", "", enabled: model.duration > 0, destructive: model.isExporting) {
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

/// The transport's live time readout + scrub slider — the only part of the
/// root editor chrome that must re-render on every playback tick.
private struct VideoDemoTransportClockView: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    @ObservedObject var clock: VideoDemoPlaybackClock

    var body: some View {
        Text(timeLabel(model.timelineTime))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)

        Slider(value: Binding(get: { model.timelineTime }, set: { model.seekToTimeline($0) }), in: 0...max(model.timelineDuration, 0.1))
            .frame(maxWidth: 260)
    }

    private func timeLabel(_ value: Double) -> String {
        let safe = max(value, 0)
        return String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
    }
}

private struct VideoDemoStageView: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    // Playhead-tracking view: re-renders per playback tick via the clock.
    @ObservedObject var clock: VideoDemoPlaybackClock

    var body: some View {
        GeometryReader { proxy in
            let layout = stageLayout(in: proxy.size)
            let cornerRadius: CGFloat = model.project.usesRawSourceFrame ? 0 : 24

            ZStack {
                zoomedScene(layout: layout)
                    .frame(width: layout.canvas.width, height: layout.canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(model.project.usesRawSourceFrame ? 0 : 0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .gesture(stageSeekGesture(stageWidth: layout.canvas.width))
                    .position(x: layout.canvas.midX, y: layout.canvas.midY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The whole composed scene — background + video + overlays — zooming as
    /// ONE unit through the shared `zoomWindow` model (byte-identical math to
    /// the export's scene animation). The old preview anchor-scaled just the
    /// video, so it neither matched the export nor visibly showed where the
    /// camera was going.
    private func zoomedScene(layout: (canvas: CGRect, stage: CGRect)) -> some View {
        let canvasSize = model.project.canvasSize()
        let window = model.project.zoomWindow(in: canvasSize, at: model.currentTime)
        let zoomScale = canvasSize.width / max(window.width, 1)
        let viewScale = layout.canvas.width / max(canvasSize.width, 1)
        let stageLocal = CGRect(
            x: layout.stage.minX - layout.canvas.minX,
            y: layout.stage.minY - layout.canvas.minY,
            width: layout.stage.width,
            height: layout.stage.height
        )

        return ZStack(alignment: .topLeading) {
            if !model.project.usesRawSourceFrame {
                VideoDemoBackgroundView(project: model.project)
                    .frame(width: layout.canvas.width, height: layout.canvas.height)
            }

            stageContent(size: stageLocal.size)
                .frame(width: stageLocal.width, height: stageLocal.height)
                .clipShape(RoundedRectangle(cornerRadius: model.project.effectiveCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(model.project.effectiveShadowStrength), radius: 28, x: 0, y: 22)
                .overlay(safeAreaGuide(size: stageLocal.size))
                .offset(x: stageLocal.minX, y: stageLocal.minY)
        }
        .frame(width: layout.canvas.width, height: layout.canvas.height, alignment: .topLeading)
        .scaleEffect(zoomScale, anchor: .topLeading)
        .offset(
            x: -window.minX * viewScale * zoomScale,
            y: -window.minY * viewScale * zoomScale
        )
    }

    private func stageContent(size: CGSize) -> some View {
        ZStack {
            ShotnixVideoPlayerView(player: model.player)
            VideoDemoOverlayView(model: model, clock: clock, stageSize: size)
        }
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
    // Playhead-tracking view: re-renders per playback tick via the clock.
    @ObservedObject var clock: VideoDemoPlaybackClock
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

    // MARK: - Direct manipulation of callouts on the stage

    /// Geometry snapshot taken when a stage drag starts, so translations
    /// apply against the gesture's origin instead of compounding.
    private struct EffectGestureOrigin: Equatable {
        let id: UUID
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ effect: VideoDemoOverlayEffect) {
            id = effect.id
            x = effect.x
            y = effect.y
            width = effect.width
            height = effect.height
        }
    }

    @State private var moveOrigin: EffectGestureOrigin?
    @State private var resizeOrigin: EffectGestureOrigin?

    private func effectView(_ effect: VideoDemoOverlayEffect) -> some View {
        let size = CGSize(
            width: stageSize.width * min(max(effect.width, 0.04), 0.9),
            height: stageSize.height * min(max(effect.height, 0.04), 0.6)
        )
        let isSelected = model.selectedEffectID == effect.id

        return ZStack {
            effectContent(effect, size: size)
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: size.width + 10, height: size.height + 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle().inset(by: -6))
        .onHover { inside in
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .gesture(moveGesture(effect))
        .overlay {
            if isSelected {
                cornerHandles(effect, size: size)
            }
        }
        .help("Drag to move · drag a corner to resize · Delete removes")
        .position(point(for: effect.x, effect.y))
    }

    @ViewBuilder
    private func effectContent(_ effect: VideoDemoOverlayEffect, size: CGSize) -> some View {
        switch effect.kind {
        case .text:
            // WYSIWYG: match the export's width-proportional type size
            // (export uses renderWidth * 0.026) instead of a fixed 16pt.
            Text(effect.text)
                .font(.system(size: max(stageSize.width * 0.026, 11), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .highlight:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.yellow.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.yellow.opacity(0.9), lineWidth: 3)
                )
                .frame(width: size.width, height: size.height)
        case .arrow:
            TimelineArrowShape()
                .stroke(.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
        case .blur:
            // Redact: opaque in preview to match the export cover.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )
                .frame(width: size.width, height: size.height)
        }
    }

    /// Body drag: select on click, move the callout on drag. Consumes the
    /// event so the stage's seek-on-click gesture never fires through it.
    private func moveGesture(_ effect: VideoDemoOverlayEffect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moveOrigin?.id != effect.id {
                    moveOrigin = EffectGestureOrigin(effect)
                    model.selectEffect(effect.id)
                }
                guard let origin = moveOrigin,
                      abs(value.translation.width) > 2 || abs(value.translation.height) > 2 else { return }
                NSCursor.closedHand.set()
                model.moveEffect(
                    id: effect.id,
                    toX: origin.x + Double(value.translation.width / max(stageSize.width, 1)),
                    y: origin.y + Double(value.translation.height / max(stageSize.height, 1))
                )
            }
            .onEnded { _ in
                moveOrigin = nil
                model.endEffectStageEdit()
                NSCursor.openHand.set()
            }
    }

    private func cornerHandles(_ effect: VideoDemoOverlayEffect, size: CGSize) -> some View {
        ForEach(Corner.allCases, id: \.self) { corner in
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .contentShape(Circle().inset(by: -7))
                .position(
                    x: corner.sx > 0 ? size.width + 5 : -5,
                    y: corner.sy > 0 ? size.height + 5 : -5
                )
                .onHover { inside in
                    (inside ? NSCursor.crosshair : NSCursor.openHand).set()
                }
                .gesture(resizeGesture(effect, corner: corner))
        }
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var sx: Double { self == .topRight || self == .bottomRight ? 1 : -1 }
        var sy: Double { self == .bottomLeft || self == .bottomRight ? 1 : -1 }
    }

    /// Corner drag: resizes keeping the opposite corner anchored.
    private func resizeGesture(_ effect: VideoDemoOverlayEffect, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeOrigin?.id != effect.id {
                    resizeOrigin = EffectGestureOrigin(effect)
                    model.selectEffect(effect.id)
                }
                guard let origin = resizeOrigin else { return }

                let fixedX = origin.x - corner.sx * origin.width / 2
                let fixedY = origin.y - corner.sy * origin.height / 2
                var movingX = origin.x + corner.sx * origin.width / 2 + Double(value.translation.width / max(stageSize.width, 1))
                var movingY = origin.y + corner.sy * origin.height / 2 + Double(value.translation.height / max(stageSize.height, 1))
                // The dragged corner stays on its own side of the anchor.
                movingX = corner.sx > 0 ? max(movingX, fixedX + 0.04) : min(movingX, fixedX - 0.04)
                movingY = corner.sy > 0 ? max(movingY, fixedY + 0.04) : min(movingY, fixedY - 0.04)

                model.resizeEffect(
                    id: effect.id,
                    x: (fixedX + movingX) / 2,
                    y: (fixedY + movingY) / 2,
                    width: abs(movingX - fixedX),
                    height: abs(movingY - fixedY)
                )
            }
            .onEnded { _ in
                resizeOrigin = nil
                model.endEffectStageEdit()
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

struct VideoDemoTimelineView: View {
    @ObservedObject var model: VideoDemoEditorViewModel
    // Playhead-tracking view: re-renders per playback tick via the clock.
    @ObservedObject var clock: VideoDemoPlaybackClock
    @State private var hoveredClipID: UUID?
    @State private var activeTrim: ActiveTimelineTrim?
    @State private var hoverTimelineTime: Double?
    @State private var isSelectingRange = false
    @State private var effectPillOrigin: EffectPillOrigin?

    // Pro-editor layout: no lane boxes, no label column — the ruler
    // on top, self-describing blocks (camera moves, effect pills, click dots)
    // floating on the flat surface, and the big clip strip at the bottom.
    // Rows only exist when they have content.
    private static let rulerHeight: CGFloat = 20
    private static let cameraRowHeight: CGFloat = 30
    private static let effectRowHeight: CGFloat = 28
    private static let effectRowGap: CGFloat = 4
    private static let clickRowHeight: CGFloat = 16
    private static let videoRowHeight: CGFloat = 72
    private static let rowSpacing: CGFloat = 8

    /// Lanes come straight from each effect's stored `layer` — assignment
    /// happens in `VideoDemoProject.normalizedEffectLayers` (on load, add,
    /// and drag end), never during rendering, so pills hold still mid-drag.
    static func effectRowAssignments(for project: VideoDemoProject) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: project.overlayEffects.map { ($0.id, max($0.layer, 0)) })
    }

    static func effectAreaHeight(for project: VideoDemoProject) -> CGFloat {
        guard !project.overlayEffects.isEmpty else { return 0 }
        let rows = (project.overlayEffects.map { max($0.layer, 0) }.max() ?? 0) + 1
        return CGFloat(rows) * effectRowHeight + CGFloat(rows - 1) * effectRowGap
    }

    /// The exact height this timeline wants for a given project, so the
    /// editor never clips a row and never reserves dead space.
    static func preferredHeight(for project: VideoDemoProject) -> CGFloat {
        var height = rulerHeight + cameraRowHeight + videoRowHeight + rowSpacing * 2 + 6
        if !project.overlayEffects.isEmpty { height += effectAreaHeight(for: project) + rowSpacing }
        if !project.clickEvents.isEmpty { height += clickRowHeight + rowSpacing }
        return height
    }

    private var videoRowTop: CGFloat {
        var top = Self.rulerHeight + Self.rowSpacing + Self.cameraRowHeight + Self.rowSpacing
        if !model.project.overlayEffects.isEmpty { top += Self.effectAreaHeight(for: model.project) + Self.rowSpacing }
        if !model.project.clickEvents.isEmpty { top += Self.clickRowHeight + Self.rowSpacing }
        return top
    }

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
            // Every lane gets an explicit full-width, leading-aligned frame:
            // the block rows position children by offset, which doesn't grow
            // layout bounds — without this the VStack would center each lane.
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ruler(width: width, duration: duration)
                    .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
                zoomTrack(width: width, duration: duration)
                    .frame(width: width, height: Self.cameraRowHeight, alignment: .topLeading)
                if !model.project.overlayEffects.isEmpty {
                    effectTrack(width: width, duration: duration)
                        .frame(width: width, height: Self.effectAreaHeight(for: model.project), alignment: .topLeading)
                }
                if !model.project.clickEvents.isEmpty {
                    clickTrack(width: width, duration: duration)
                        .frame(width: width, height: Self.clickRowHeight, alignment: .topLeading)
                }
                videoTrack(width: width, duration: duration)
                    .frame(width: width, height: Self.videoRowHeight, alignment: .leading)
            }

            if let hoverTimelineTime {
                hoverScrubber(time: hoverTimelineTime, width: width, height: height, duration: duration)
            }

            playhead(height: height - 2)
                .offset(x: playheadX - 3, y: 1)

            splitBladeMarker
                .offset(x: min(max(playheadX - 11, 0), max(width - 22, 0)), y: videoRowTop + 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard activeTrim == nil, !isSelectingRange else { return }
                    model.clearTimelineSelection()
                    // Tolerant chained seeks while dragging; the exact seek
                    // lands when isScrubbing flips off in onEnded.
                    model.isScrubbing = true
                    model.seekToTimeline(
                        timelineTime(at: gesture.location.x, width: width, duration: duration),
                        snapping: true,
                        snapThreshold: snapThreshold(duration: duration, width: width)
                    )
                }
                .onEnded { _ in
                    model.isScrubbing = false
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
            ForEach(Array(model.timelineSegments.enumerated()), id: \.element.id) { index, segment in
                let segmentX = CGFloat(segment.timelineStart / duration) * width
                let segmentWidth = max(CGFloat(segment.duration / duration) * width - 4, 64)
                videoClip(segment: segment, index: index, timelineWidth: width, timelineDuration: duration)
                    .frame(width: segmentWidth, height: Self.videoRowHeight)
                    .offset(x: segmentX + 2)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .highPriorityGesture(clipSeekGesture(segment: segment, clipWidth: segmentWidth))
                    .onHover { hovering in
                        hoveredClipID = hovering ? segment.id : (hoveredClipID == segment.id ? nil : hoveredClipID)
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
                        .offset(x: min(segmentX + segmentWidth - 130, max(width - 132, 2)), y: 5)
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
                    model.isScrubbing = true
                    model.seekToTimeline(current, snapping: true, snapThreshold: threshold)
                }
            }
            .onEnded { value in
                defer { model.isScrubbing = false }
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
            .frame(width: max(endX - startX, 4), height: Self.videoRowHeight)
            .offset(x: startX + 2)
            .allowsHitTesting(false)
    }

    /// Camera row: every zoom move is a labeled block ("1.8×") spanning
    /// until the next move — the block itself is the draggable object.
    /// A scale-1 keyframe (camera reset) renders as a compact "1×" chip.
    private func zoomTrack(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .topLeading) {
            if model.project.zoomKeyframes.isEmpty {
                Text("Auto zoom — camera follows your clicks")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .frame(height: Self.cameraRowHeight)
                    .padding(.horizontal, 2)
                    .allowsHitTesting(false)
            }

            ForEach(zoomMoveRanges(duration: duration), id: \.id) { move in
                let isReset = move.scale <= 1.02
                let blockWidth = isReset ? 34 : max(CGFloat(move.duration / duration) * width, 42)

                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.blue.opacity(move.selected ? 0.52 : (isReset ? 0.12 : 0.26)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(move.selected ? Color.accentColor : Color.blue.opacity(isReset ? 0.35 : 0.55), lineWidth: move.selected ? 1.5 : 1)
                        )
                    Text(isReset ? "1×" : String(format: "%.1f×", move.scale))
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(isReset ? 0.6 : 0.94))
                        .lineLimit(1)
                }
                .frame(width: blockWidth, height: Self.cameraRowHeight)
                .contentShape(Rectangle())
                .help(isReset ? "Camera reset — drag to retime" : "Zoom move — drag to retime, click to select")
                .gesture(markerDragGesture(
                    id: move.id,
                    startTime: move.start,
                    width: width,
                    duration: duration,
                    onMove: { model.moveZoom(id: move.id, toTimelineTime: $0) },
                    onTap: {
                        model.selectZoom(move.id)
                        model.seekToTimeline(move.start)
                    }
                ))
                .offset(x: CGFloat(move.start / duration) * width)
            }
        }
    }

    /// Origin captured when a marker drag starts — translations always apply
    /// against it, so mid-drag view rebuilds can't compound the movement.
    @State private var markerDragOrigin: (id: UUID, start: Double)?

    private func markerDragGesture(
        id: UUID,
        startTime: Double,
        width: CGFloat,
        duration: Double,
        onMove: @escaping (Double) -> Void,
        onTap: @escaping () -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if markerDragOrigin?.id != id {
                    markerDragOrigin = (id, startTime)
                }
                guard let origin = markerDragOrigin, abs(value.translation.width) > 2 else { return }
                let next = origin.start + Double(value.translation.width / max(width, 1)) * duration
                onMove(model.snappedTimelineTime(next, threshold: snapThreshold(duration: duration, width: width), excluding: id))
            }
            .onEnded { value in
                markerDragOrigin = nil
                model.endEffectStageEdit()
                if abs(value.translation.width) <= 2 {
                    onTap()
                }
            }
    }

    /// Clicks row: a thin strip of dots on a hairline — tap to select (and
    /// seek there), drag to retime, Delete to remove. Ripples, spotlights,
    /// and the next Auto Zoom run all follow the edited list.
    private func clickTrack(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: width, height: 2)
                .offset(y: Self.clickRowHeight / 2 - 1)
                .allowsHitTesting(false)

            ForEach(model.project.clickEvents) { click in
                if let markerTime = model.project.timelineTimeIfIncluded(sourceTime: click.time, totalDuration: model.duration) {
                    Circle()
                        .strokeBorder(model.selectedClickID == click.id ? Color.accentColor : Color.white.opacity(0.7), lineWidth: 1.5)
                        .background(Circle().fill(Color.blue.opacity(model.selectedClickID == click.id ? 0.6 : 0.25)))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle().inset(by: -5))
                        .help("Click — drag to retime, Delete removes")
                        .gesture(markerDragGesture(
                            id: click.id,
                            startTime: markerTime,
                            width: width,
                            duration: duration,
                            onMove: { model.moveClick(id: click.id, toTimelineTime: $0) },
                            onTap: {
                                model.selectClick(click.id)
                                model.seekToTimeline(markerTime)
                            }
                        ))
                        .offset(x: CGFloat(markerTime / duration) * width - 6, y: Self.clickRowHeight / 2 - 6)
                }
            }
        }
    }

    private func effectTrack(width: CGFloat, duration: Double) -> some View {
        let rows = Self.effectRowAssignments(for: model.project)
        return ZStack(alignment: .topLeading) {
            ForEach(model.project.overlayEffects) { effect in
                if let start = model.project.timelineTimeIfIncluded(sourceTime: effect.time, totalDuration: model.duration) {
                    let rawEnd = model.project.timelineTimeIfIncluded(sourceTime: effect.time + effect.duration, totalDuration: model.duration)
                    let end = min(max(rawEnd ?? start + effect.duration, start + 0.1), duration)
                    effectPill(effect, start: start, end: end, width: width, duration: duration, row: rows[effect.id] ?? 0)
                }
            }
        }
    }

    // MARK: - Effect pills (duration blocks)

    /// The effect window captured when a pill gesture starts, so drags apply
    /// against the origin instead of compounding.
    private struct EffectPillOrigin {
        let id: UUID
        let start: Double
        let end: Double
        let layer: Int
    }

    private enum PillEdge {
        case leading
        case trailing
    }

    /// A callout on the Effects lane is a pill spanning its visible window:
    /// drag the body to move it in time, drag an edge grip to set when it
    /// appears or disappears, click to select and jump there.
    private func effectPill(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, width: CGFloat, duration: Double, row: Int) -> some View {
        let isSelected = model.selectedEffectID == effect.id
        let x = CGFloat(start / duration) * width
        let pillWidth = max(CGFloat((end - start) / duration) * width, 30)
        let tint = pillTint(for: effect.kind)

        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(isSelected ? 0.5 : 0.26))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : tint.opacity(0.6), lineWidth: isSelected ? 1.5 : 1)
                )

            HStack(spacing: 4) {
                Image(systemName: effect.kind.icon)
                    .font(.system(size: 9, weight: .heavy))
                if pillWidth > 76 {
                    Text(effect.kind.title)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)

            HStack {
                pillEdgeGrip()
                    .gesture(pillTrimGesture(effect, edge: .leading, start: start, end: end, width: width, duration: duration))
                Spacer(minLength: 0)
                pillEdgeGrip()
                    .gesture(pillTrimGesture(effect, edge: .trailing, start: start, end: end, width: width, duration: duration))
            }
        }
        .frame(width: pillWidth, height: Self.effectRowHeight)
        .contentShape(Rectangle())
        .help("Drag to move · drag up/down to change lane · edges set when it appears and disappears")
        .gesture(pillMoveGesture(effect, start: start, end: end, width: width, duration: duration))
        .offset(x: x, y: CGFloat(row) * (Self.effectRowHeight + Self.effectRowGap))
    }

    private func pillTint(for kind: VideoDemoOverlayEffectKind) -> Color {
        switch kind {
        case .highlight, .arrow: return .yellow
        case .text: return .purple
        case .blur: return .gray
        }
    }

    private func pillEdgeGrip() -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(0.6))
            .frame(width: 3, height: 12)
            .padding(.horizontal, 3)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
    }

    private func pillMoveGesture(_ effect: VideoDemoOverlayEffect, start: Double, end: Double, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if effectPillOrigin?.id != effect.id {
                    effectPillOrigin = EffectPillOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                    model.selectEffect(effect.id)
                }
                guard let origin = effectPillOrigin else { return }

                if abs(value.translation.width) > 2 {
                    let delta = Double(value.translation.width / max(width, 1)) * duration
                    let length = origin.end - origin.start
                    let newStart = model.snappedTimelineTime(
                        min(max(origin.start + delta, 0), max(duration - length, 0)),
                        threshold: snapThreshold(duration: duration, width: width),
                        excluding: effect.id
                    )
                    model.setEffectWindow(id: effect.id, timelineStart: newStart, timelineEnd: newStart + length)
                }

                // Vertical drag moves the pill between lanes: one row of
                // travel per lane height, applied live.
                let rowStride = Self.effectRowHeight + Self.effectRowGap
                let rowDelta = Int((value.translation.height / rowStride).rounded())
                model.setEffectLayer(id: effect.id, layer: origin.layer + rowDelta)
            }
            .onEnded { value in
                let origin = effectPillOrigin
                effectPillOrigin = nil
                model.endEffectStageEdit()
                if abs(value.translation.width) <= 2, abs(value.translation.height) <= 2, let origin {
                    model.selectEffect(effect.id)
                    model.seekToTimeline(origin.start)
                }
            }
    }

    private func pillTrimGesture(_ effect: VideoDemoOverlayEffect, edge: PillEdge, start: Double, end: Double, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if effectPillOrigin?.id != effect.id {
                    effectPillOrigin = EffectPillOrigin(id: effect.id, start: start, end: end, layer: effect.layer)
                    model.selectEffect(effect.id)
                }
                guard let origin = effectPillOrigin else { return }
                let delta = Double(value.translation.width / max(width, 1)) * duration
                let threshold = snapThreshold(duration: duration, width: width)
                switch edge {
                case .leading:
                    let newStart = model.snappedTimelineTime(origin.start + delta, threshold: threshold, excluding: effect.id)
                    model.setEffectWindow(id: effect.id, timelineStart: min(newStart, origin.end - 0.2), timelineEnd: origin.end)
                case .trailing:
                    let newEnd = model.snappedTimelineTime(origin.end + delta, threshold: threshold, excluding: effect.id)
                    model.setEffectWindow(id: effect.id, timelineStart: origin.start, timelineEnd: max(newEnd, origin.start + 0.2))
                }
            }
            .onEnded { _ in
                effectPillOrigin = nil
                model.endEffectStageEdit()
            }
    }

    private func zoomMoveRanges(duration: Double) -> [(id: UUID, start: Double, duration: Double, scale: Double, selected: Bool)] {
        let sorted = model.project.zoomKeyframes.sorted { $0.time < $1.time }
        return sorted.compactMap { keyframe in
            guard let start = model.project.timelineTimeIfIncluded(sourceTime: keyframe.time, totalDuration: model.duration) else { return nil }
            let next = sorted
                .filter { $0.time > keyframe.time + 0.001 }
                .compactMap { model.project.timelineTimeIfIncluded(sourceTime: $0.time, totalDuration: model.duration) }
                .first
            let end = min(next ?? start + 1.2, duration)
            return (keyframe.id, start, max(end - start, 0.25), keyframe.scale, model.selectedZoomID == keyframe.id)
        }
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
            // Grabber: a rounded knob at the ruler
            // feeding a hairline that spans every row.
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.purple)
                .frame(width: 7, height: 14)
            Rectangle()
                .fill(Color.purple.opacity(0.92))
                .frame(width: 2, height: max(height - 14, 0))
        }
        .shadow(color: Color.purple.opacity(0.42), radius: 4, x: 0, y: 0)
        .allowsHitTesting(false)
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
