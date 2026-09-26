import AppKit
import Foundation

// MARK: - Several items at once

extension VideoEditorModel.Selection {
    /// The selected object's id (nil for nothing or a range).
    var itemID: UUID? {
        switch self {
        case .zoom(let id), .clip(let id), .overlay(let id), .click(let id), .caption(let id), .keystroke(let id), .cameraLayout(let id): return id
        case .range, .none: return nil
        }
    }
}

extension VideoEditorModel {
    /// Everything selected, the lead item first.
    var selectedItems: [Selection] {
        selection == .none ? [] : [selection] + extraSelection
    }

    func isSelected(_ item: Selection) -> Bool {
        item != .none && (selection == item || extraSelection.contains(item))
    }

    /// The ids of the selected items of one kind (`pick` returns an id for
    /// that kind, nil for others).
    func selectedIDs(_ pick: (Selection) -> UUID?) -> Set<UUID> {
        Set(selectedItems.compactMap(pick))
    }

    /// Whether a click should add to (or take from) the selection rather
    /// than replace it: ⇧ or ⌘ held.
    static var extendsSelection: Bool {
        !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
    }

    /// A plain click selects just `item`; with ⇧ or ⌘ it joins the others
    /// (or leaves them, when it was already selected).
    func click(_ item: Selection) {
        if Self.extendsSelection { toggleSelection(item) } else { selection = item }
    }

    func toggleSelection(_ item: Selection) {
        guard item != .none else { return }
        // A range works on its own.
        if case .range = item { selection = item; return }
        if case .range = selection { selection = item; return }
        if selection == .none {
            selection = item
        } else if selection == item {
            // The next one leads.
            var rest = extraSelection
            let lead = rest.isEmpty ? Selection.none : rest.removeFirst()
            keepsExtraSelection = true
            selection = lead
            keepsExtraSelection = false
            extraSelection = rest
        } else if let index = extraSelection.firstIndex(of: item) {
            extraSelection.remove(at: index)
        } else {
            extraSelection.append(item)
        }
    }

    /// Drops extra items that no longer exist (after an undo).
    func validateExtraSelection() {
        let kept = extraSelection.filter { exists($0) }
        if kept != extraSelection { extraSelection = kept }
    }

    private func exists(_ item: Selection) -> Bool {
        switch item {
        case .none, .range: return false
        case .zoom(let id): return project.zoomRegions.contains { $0.id == id }
        case .overlay(let id): return project.overlayEffects.contains { $0.id == id }
        case .click(let id): return project.clickEvents.contains { $0.id == id }
        case .caption(let id): return project.captions.contains { $0.id == id }
        case .keystroke(let id): return project.keystrokes.contains { $0.id == id }
        case .cameraLayout(let id): return project.cameraLayouts.contains { $0.id == id }
        case .clip(let id): return project.timelineClips.contains { $0.id == id }
        }
    }

    /// Where an item sits on the timeline.
    func timelineSpan(of item: Selection) -> (start: Double, end: Double)? {
        switch item {
        case .zoom(let id):
            return project.zoomRegions.first { $0.id == id }.flatMap { zoomTimelineRange($0) }.map { ($0.lowerBound, $0.upperBound) }
        case .overlay(let id):
            return plan.overlays.first { $0.effect.id == id }.map { ($0.start, $0.end) }
        case .caption(let id):
            return plan.captions.first { $0.id == id }.map { ($0.start, $0.end) }
        case .cameraLayout(let id):
            return cameraLayoutSpans.first { $0.region.id == id }.map { ($0.start, $0.end) }
        case .click(let id):
            return project.clickEvents.first { $0.id == id }.flatMap { timelineTime(forSource: $0.time) }.map { ($0, $0) }
        case .keystroke(let id):
            return project.keystrokes.first { $0.id == id }.flatMap { timelineTime(forSource: $0.time) }.map { ($0, $0) }
        case .clip(let id):
            return segments.first { $0.id == id }.map { ($0.timelineStart, $0.timelineEnd) }
        case .range(let range):
            return (range.normalized.start, range.normalized.end)
        case .none:
            return nil
        }
    }

    // MARK: Stepping through the timeline

    /// Everything on the timeline in time order (what ⌥← / ⌥→ step
    /// through): zooms, annotations, captions, camera layouts, shortcuts,
    /// clicks, and clips.
    var timelineItems: [(item: Selection, start: Double)] {
        var items: [(item: Selection, start: Double)] = []
        for region in project.zoomRegions { if let range = zoomTimelineRange(region) { items.append((.zoom(region.id), range.lowerBound)) } }
        for overlay in plan.overlays { items.append((.overlay(overlay.effect.id), overlay.start)) }
        for caption in plan.captions { items.append((.caption(caption.id), caption.start)) }
        for span in cameraLayoutSpans { items.append((.cameraLayout(span.region.id), span.start)) }
        for event in project.keystrokes { if let time = timelineTime(forSource: event.time) { items.append((.keystroke(event.id), time)) } }
        for click in project.clickEvents { if let time = timelineTime(forSource: click.time) { items.append((.click(click.id), time)) } }
        for segment in segments { items.append((.clip(segment.id), segment.timelineStart)) }
        return items.sorted { $0.start < $1.start }
    }

    /// ⌥→ (⌥←): selects the next (previous) thing on the timeline after
    /// the selected one — or after the playhead — and moves the playhead
    /// to it. No mouse needed to reach an annotation.
    func selectAdjacentItem(forward: Bool) {
        let items = timelineItems
        guard !items.isEmpty else { return }
        var index: Int?
        if let current = items.firstIndex(where: { $0.item == selection }) {
            let next = current + (forward ? 1 : -1)
            index = items.indices.contains(next) ? next : nil
        } else {
            let time = clock.time
            index = forward ? items.firstIndex { $0.start > time + 0.001 } : items.lastIndex { $0.start < time - 0.001 }
        }
        guard let index else {
            NSSound.beep()
            return
        }
        let target = items[index]
        selection = target.item
        seek(to: target.start)
        // VoiceOver says what was picked.
        if let window = NSApplication.shared.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: accessibilityDescription(of: target.item),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    /// ", 0:03.0 to 0:04.5" (or ", at 0:03.0") for spoken descriptions.
    static func spokenSpan(_ start: Double, _ end: Double) -> String {
        end - start > 0.05 ? ", \(timecode(start)) to \(timecode(end))" : ", at \(timecode(start))"
    }

    /// "Clip 2, 4.0s long, 2× speed, muted, 0:02.0 to 0:06.0".
    static func spokenClip(index: Int, segment: VideoDemoTimelineSegment) -> String {
        var parts = ["Clip \(index + 1)", "\(format(segment.duration)) long"]
        if abs(segment.clip.normalizedSpeed - 1) > 0.01 { parts.append("\(formatScale(segment.clip.normalizedSpeed)) speed") }
        if segment.clip.muted { parts.append("muted") }
        return parts.joined(separator: ", ") + spokenSpan(segment.timelineStart, segment.timelineEnd)
    }

    /// Spoken (and shown to VoiceOver) for an item: what it is and where.
    func accessibilityDescription(of item: Selection) -> String {
        func at(_ span: (start: Double, end: Double)?) -> String {
            span.map { Self.spokenSpan($0.start, $0.end) } ?? ""
        }
        let span = timelineSpan(of: item)
        switch item {
        case .zoom(let id):
            let region = project.zoomRegions.first { $0.id == id }
            return "Zoom \(region.map { Self.formatScale($0.scale) } ?? "")\(region?.followsCursor == true ? ", follows the cursor" : "")\(at(span))"
        case .overlay(let id):
            guard let effect = project.overlayEffects.first(where: { $0.id == id }) else { return "Annotation" }
            return (effect.kind == .text ? "Text “\(effect.text)”" : effect.kind.title) + at(span)
        case .caption(let id):
            return "Caption “\(plan.captions.first { $0.id == id }?.text ?? "")”\(at(span))"
        case .cameraLayout(let id):
            return "Camera layout: \(project.cameraLayouts.first { $0.id == id }?.layout.title ?? "")\(at(span))"
        case .keystroke(let id):
            return "Shortcut \(project.keystrokes.first { $0.id == id }?.keys.joined() ?? "")\(at(span))"
        case .click:
            return "Click\(at(span))"
        case .clip(let id):
            guard let index = segments.firstIndex(where: { $0.id == id }) else { return "Clip" }
            return Self.spokenClip(index: index, segment: segments[index])
        case .range(let range):
            return "Selected part\(at((range.normalized.start, range.normalized.end)))"
        case .none:
            return ""
        }
    }

    // MARK: Moving together

    /// Whether dragging `item` moves the whole selection.
    func movesAsGroup(_ item: Selection) -> Bool {
        !extraSelection.isEmpty && isSelected(item)
    }

    /// A drag on one selected item begins: remember where every selected
    /// bar was (clips and shortcuts stay put).
    func beginGroupMove() {
        groupMoveOrigins = selectedItems.compactMap { item in
            switch item {
            case .zoom, .overlay, .caption, .cameraLayout, .click:
                return timelineSpan(of: item).map { (item, $0.start, $0.end) }
            default:
                return nil
            }
        }
        pendingUndoLabel = "Move \(groupMoveOrigins.count) Items"
    }

    /// Every selected bar shifts by the same `delta` (timeline seconds),
    /// kept on the timeline — one undo step for the whole drag.
    func moveGroup(by delta: Double) {
        guard !groupMoveOrigins.isEmpty else { return }
        let earliest = groupMoveOrigins.map(\.start).min() ?? 0
        let latest = groupMoveOrigins.map(\.end).max() ?? 0
        let shift = min(max(delta, -earliest), max(timelineDuration - latest, 0))
        // Front-runners first, so neighbours in the group don't block
        // each other.
        let ordered = groupMoveOrigins.sorted { shift > 0 ? $0.start > $1.start : $0.start < $1.start }
        let key = "group-move"
        for (item, start, end) in ordered {
            switch item {
            case .zoom(let id): setZoomWindow(id, start: start + shift, end: end + shift, coalesce: key)
            case .overlay(let id): setOverlayWindow(id, start: start + shift, end: end + shift, coalesce: key)
            case .caption(let id): setCaptionWindow(id, timelineStart: start + shift, timelineEnd: end + shift, moveWords: true, coalesce: key)
            case .cameraLayout(let id): setCameraLayoutWindow(id, timelineStart: start + shift, timelineEnd: end + shift, moving: true, coalesce: key)
            case .click(let id): moveClick(id, toTimeline: start + shift, coalesce: key)
            default: break
            }
        }
    }

    func endGroupMove() {
        groupMoveOrigins = []
        pendingUndoLabel = nil
        finishOverlayDrag()
    }

    // MARK: Deleting together

    /// ⌫ with several items selected: all of them, in one undo step (the
    /// video keeps at least one clip).
    func deleteSelectedItems() {
        let items = selectedItems
        guard items.count > 1 else {
            deleteSelection()
            return
        }
        var ids = Set<UUID>()
        var clips: [UUID] = []
        for item in items {
            switch item {
            case .zoom(let id), .overlay(let id), .click(let id), .caption(let id), .keystroke(let id), .cameraLayout(let id): ids.insert(id)
            case .clip(let id): clips.append(id)
            case .range, .none: break
            }
        }
        var removedClips = 0
        mutate(label: "Delete \(items.count) Items") { project in
            project.zoomRegions.removeAll { ids.contains($0.id) }
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects.filter { !ids.contains($0.id) })
            project.clickEvents.removeAll { ids.contains($0.id) }
            project.captions.removeAll { ids.contains($0.id) }
            project.keystrokes.removeAll { ids.contains($0.id) }
            project.cameraLayouts.removeAll { ids.contains($0.id) }
            for id in clips where project.deleteClip(id: id, totalDuration: sourceDuration) != nil {
                removedClips += 1
            }
        }
        selection = .none
        let keptClip = removedClips < clips.count ? " (a video keeps at least one clip)" : ""
        showNotice("Removed \(ids.count + removedClips) items — ⌘Z to undo\(keptClip)", symbol: "trash")
    }
}
