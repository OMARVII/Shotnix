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
