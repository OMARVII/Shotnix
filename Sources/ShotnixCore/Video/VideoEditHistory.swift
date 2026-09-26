import Foundation

/// Names an edit from what it changed, for "Undo Delete Zoom" / "Redo Cut".
enum VideoEditDescription {
    static func describe(from old: VideoDemoProject, to new: VideoDemoProject) -> String {
        // Recordings, music, cards, transitions (VideoEditorMedia.swift).
        if let framing = framing(from: old, to: new) { return framing }
        if old.timelineClips != new.timelineClips { return clips(old.timelineClips, new.timelineClips) }
        if old.zoomRegions != new.zoomRegions { return items(old.zoomRegions, new.zoomRegions, noun: "Zoom", plural: "Zooms") }
        if old.overlayEffects != new.overlayEffects { return overlays(old.overlayEffects, new.overlayEffects) }
        if old.captions != new.captions {
            if old.captions.isEmpty { return "Captions" }
            if new.captions.isEmpty { return "Remove Captions" }
            return items(old.captions, new.captions, noun: "Caption", plural: "Captions", change: "Edit Caption")
        }
        if old.cameraLayouts != new.cameraLayouts { return items(old.cameraLayouts, new.cameraLayouts, noun: "Camera Layout", plural: "Camera Layouts") }
        if old.clickEvents != new.clickEvents { return items(old.clickEvents, new.clickEvents, noun: "Click", plural: "Clicks", change: "Move Click") }
        if old.keystrokes != new.keystrokes { return new.keystrokes.count < old.keystrokes.count ? "Hide Shortcut" : "Shortcuts" }
        if old.crop != new.crop { return "Crop" }
        if old.audio != new.audio {
            if old.audio.muted != new.audio.muted { return new.audio.muted ? "Mute Video" : "Unmute Video" }
            if old.audio.enhanceVoice != new.audio.enhanceVoice { return "Enhance Voice" }
            return "Sound Change"
        }
        if old.aspectPreset != new.aspectPreset || old.reframe != new.reframe { return "Aspect Ratio" }
        if old.background != new.background || old.backgroundBlur != new.backgroundBlur { return "Background" }
        if old.cursor != new.cursor { return "Cursor Change" }
        if old.webcam != new.webcam { return "Camera Change" }
        if old.captionStyle != new.captionStyle { return "Caption Style" }
        if old.keystrokeStyle != new.keystrokeStyle { return "Shortcut Style" }
        return "Style Change"
    }

    private static func clips(_ old: [VideoDemoTimelineClip], _ new: [VideoDemoTimelineClip]) -> String {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        if Set(oldIDs) == Set(newIDs) {
            if oldIDs != newIDs { return "Move Clip" }
            let pairs = zip(old, new)
            if pairs.contains(where: { $0.speed != $1.speed }) { return "Speed Change" }
            if pairs.contains(where: { $0.muted != $1.muted }) { return pairs.contains(where: { !$0.muted && $1.muted }) ? "Mute Clip" : "Unmute Clip" }
            if pairs.contains(where: { $0.fadeIn != $1.fadeIn || $0.fadeOut != $1.fadeOut }) { return "Fade" }
            return "Trim"
        }
        if new.count == old.count + 1, Set(oldIDs).isSubset(of: Set(newIDs)) { return "Split" }
        if new.count < old.count, Set(newIDs).isSubset(of: Set(oldIDs)) { return old.count - new.count == 1 ? "Delete Clip" : "Delete Clips" }
        let oldLength = old.reduce(0) { $0 + $1.sourceDuration }
        let newLength = new.reduce(0) { $0 + $1.sourceDuration }
        return newLength < oldLength ? "Cut" : "Restore"
    }

    private static func items<Item: Identifiable & Equatable>(_ old: [Item], _ new: [Item], noun: String, plural: String, change: String? = nil) -> String {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        let added = newIDs.subtracting(oldIDs).count
        let removed = oldIDs.subtracting(newIDs).count
        if added > 0, removed == 0 { return added == 1 ? "Add \(noun)" : "Add \(plural)" }
        if removed > 0, added == 0 { return removed == 1 ? "Delete \(noun)" : "Delete \(plural)" }
        if added > 0 { return plural }
        return change ?? "\(noun) Change"
    }

    private static func overlays(_ old: [VideoDemoOverlayEffect], _ new: [VideoDemoOverlayEffect]) -> String {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = new.filter { oldByID[$0.id] == nil }
        let removed = old.filter { newByID[$0.id] == nil }
        if added.count == 1, removed.isEmpty { return "Add \(added[0].kind.title)" }
        if removed.count == 1, added.isEmpty { return "Delete \(removed[0].kind.title)" }
        if !added.isEmpty || !removed.isEmpty { return removed.count > 1 ? "Delete Annotations" : "Annotations" }
        guard let changed = new.first(where: { oldByID[$0.id] != $0 }), let before = oldByID[changed.id] else { return "Annotation Change" }
        if before.text != changed.text { return "Edit Text" }
        if before.time != changed.time || before.duration != changed.duration || before.layer != changed.layer { return "Move \(changed.kind.title)" }
        if before.x != changed.x || before.y != changed.y || before.width != changed.width || before.height != changed.height || before.arrowEnds != changed.arrowEnds {
            return "Move \(changed.kind.title)"
        }
        return "\(changed.kind.title) Style"
    }
}
