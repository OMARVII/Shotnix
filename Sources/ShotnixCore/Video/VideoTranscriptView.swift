import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Index into the transcript's words.
    static let shotnixWord = NSAttributedString.Key("ShotnixTranscriptWord")
    /// A silence before the word at this index.
    static let shotnixPause = NSAttributedString.Key("ShotnixTranscriptPause")
}

/// The recording's words as text: select words and press ⌫ to cut them
/// from the video (⌫ on struck-through words puts them back), click a word
/// to jump there, ⌘F to find. Pauses show as small tokens you can delete.
struct VideoTranscriptEditor: NSViewRepresentable {
    let model: VideoEditorModel
    @ObservedObject var timeline: VideoTimelineState
    @ObservedObject var clock: VideoDemoPlaybackClock
    /// ⌘F from elsewhere in the editor: take focus, open the find bar.
    var wantsFind = false

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let textView = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        textView.coordinator = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.45)]
        textView.setAccessibilityLabel("Transcript")
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.refresh(revision: timeline.revision)
        coordinator.highlight(sourceTime: model.sourceTime(forTimeline: clock.time), playing: model.isPlaying)
        if wantsFind {
            // After this update (the view may have just been created).
            DispatchQueue.main.async { [model, weak coordinator] in
                model.wantsTranscriptFind = false
                coordinator?.showFind()
            }
        }
    }

    @MainActor
    final class Coordinator {
        let model: VideoEditorModel
        weak var textView: TranscriptTextView?
        private var words: [VideoTranscriptWord] = []
        private var wordRanges: [NSRange] = []
        private var highlighted: Int?
        /// What the text shows was built from: the words and which of them
        /// are still in the video. Timeline changes that touch neither (a
        /// zoom step, thumbnails arriving, a selection) leave it alone.
        private var shownWords: [VideoTranscriptWord]?
        private var shownIncluded: [Bool] = []
        private var revision = -1
        /// Tests: how many times the text was rebuilt.
        private(set) var rebuilds = 0
        private static let font = NSFont.systemFont(ofSize: 13)
        private static let pauseFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

        init(model: VideoEditorModel) {
            self.model = model
        }

        func refresh(revision: Int) {
            // Playhead ticks update the view too: only a timeline change can
            // change the words.
            guard revision != self.revision, let textView else { return }
            self.revision = revision
            let words = model.transcriptWords
            // In reading order: each pause (a gap over a second), then the
            // word after it.
            var included: [Bool] = []
            included.reserveCapacity(words.count * 2)
            for (index, word) in words.enumerated() {
                if index > 0, word.start - words[index - 1].end > 1.0 {
                    included.append(model.isIncluded(sourceTime: (words[index - 1].end + word.start) / 2))
                }
                included.append(model.isIncluded(word))
            }
            guard words != shownWords || included != shownIncluded else { return }
            let keptSelection = textView.selectedRange().length > 0 ? indices(in: textView.selectedRange()).words : IndexSet()
            let caret = textView.selectedRange().length == 0 ? textView.selectedRange().location : nil
            shownWords = words
            shownIncluded = included
            self.words = words
            rebuilds += 1
            let visible = textView.visibleRect
            let text = NSMutableAttributedString()
            wordRanges = []
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 10
            var slot = 0
            for (index, word) in words.enumerated() {
                if index > 0 {
                    let previous = words[index - 1]
                    let gap = word.start - previous.end
                    let sentenceEnd = previous.text.last.map { ".?!".contains($0) } ?? false
                    if gap > 1.0 {
                        text.append(NSAttributedString(string: " "))
                        let pauseIncluded = included[slot]
                        slot += 1
                        text.append(NSAttributedString(string: " ⏸ \(VideoEditorModel.format(gap)) ", attributes: [
                            .font: Self.pauseFont,
                            .foregroundColor: NSColor.white.withAlphaComponent(pauseIncluded ? 0.55 : 0.25),
                            .backgroundColor: NSColor.white.withAlphaComponent(pauseIncluded ? 0.1 : 0.04),
                            .shotnixPause: index,
                            .strikethroughStyle: pauseIncluded ? 0 : NSUnderlineStyle.single.rawValue,
                        ]))
                        text.append(NSAttributedString(string: sentenceEnd || gap > 2 ? "\n" : " "))
                    } else if sentenceEnd && gap > 0.6 {
                        text.append(NSAttributedString(string: "\n"))
                    } else if VideoCaptionBuilder.needsSpace(between: previous.text, and: word.text) {
                        text.append(NSAttributedString(string: " "))
                    }
                }
                let isIncluded = included[slot]
                slot += 1
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.font,
                    .foregroundColor: NSColor.white.withAlphaComponent(isIncluded ? 0.9 : 0.3),
                    .shotnixWord: index,
                ]
                if !isIncluded {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = NSColor.white.withAlphaComponent(0.45)
                } else if word.isFiller {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attributes[.underlineColor] = NSColor.systemOrange
                    attributes[.foregroundColor] = NSColor.systemOrange.withAlphaComponent(0.95)
                }
                let start = text.length
                text.append(NSAttributedString(string: word.text, attributes: attributes))
                wordRanges.append(NSRange(location: start, length: text.length - start))
            }
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            textView.textStorage?.setAttributedString(text)
            // The same words stay selected (a cut, then ⌫ again, restores
            // them); a caret stays where it was.
            if let first = keptSelection.first, let last = keptSelection.last,
               wordRanges.indices.contains(first), wordRanges.indices.contains(last) {
                textView.setSelectedRange(NSRange(location: wordRanges[first].location, length: NSMaxRange(wordRanges[last]) - wordRanges[first].location))
            } else {
                textView.setSelectedRange(NSRange(location: min(caret ?? 0, text.length), length: 0))
            }
            highlighted = nil
            textView.scrollToVisible(visible)
        }

        /// Marks the word being spoken.
        func highlight(sourceTime: Double, playing: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let index = lastWord(startingBy: sourceTime + 0.02).flatMap { words[$0].end + 0.25 >= sourceTime ? $0 : nil }
            guard index != highlighted else { return }
            if let old = highlighted, wordRanges.indices.contains(old), NSMaxRange(wordRanges[old]) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: wordRanges[old])
            }
            highlighted = index
            if let index, wordRanges.indices.contains(index), NSMaxRange(wordRanges[index]) <= storage.length {
                storage.addAttribute(.backgroundColor, value: VideoEditorTheme.captionNS.withAlphaComponent(0.45), range: wordRanges[index])
                if playing {
                    textView.scrollRangeToVisible(wordRanges[index])
                }
            }
        }

        /// The last word that starts at or before `time` (words are in time
        /// order: a binary search, 60 times a second while playing).
        private func lastWord(startingBy time: Double) -> Int? {
            var low = 0
            var high = words.count
            while low < high {
                let mid = (low + high) / 2
                if words[mid].start <= time { low = mid + 1 } else { high = mid }
            }
            return low > 0 ? low - 1 : nil
        }

        private func indices(in range: NSRange) -> (words: IndexSet, pauses: [Int]) {
            guard let storage = textView?.textStorage, range.length > 0 else { return ([], []) }
            var found = IndexSet()
            var pauses: [Int] = []
            storage.enumerateAttributes(in: range) { attributes, _, _ in
                if let index = attributes[.shotnixWord] as? Int { found.insert(index) }
                if let pause = attributes[.shotnixPause] as? Int { pauses.append(pause) }
            }
            return (found, Array(Set(pauses)).sorted())
        }

        func deleteSelection() {
            guard let textView else { return }
            let selection = indices(in: textView.selectedRange())
            if !selection.words.isEmpty {
                let cut = selection.words.filter { words.indices.contains($0) && !model.isIncluded(words[$0]) }
                if cut.count == selection.words.count {
                    model.restoreWords(selection.words)
                } else {
                    model.cutWords(selection.words)
                }
            } else if let pause = selection.pauses.first {
                model.shortenPause(before: pause)
            }
        }

        /// ⌫ (or ⌦) with only a cursor in the text: the word (or pause)
        /// just before (after) it is cut — or put back if it already was.
        func deleteWord(before: Bool) {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            let caret = textView.selectedRange().location
            var index = before ? caret - 1 : caret
            while index >= 0, index < storage.length {
                let attributes = storage.attributes(at: index, effectiveRange: nil)
                if let word = attributes[.shotnixWord] as? Int, words.indices.contains(word) {
                    if model.isIncluded(words[word]) {
                        model.cutWords(IndexSet(integer: word))
                    } else {
                        model.restoreWords(IndexSet(integer: word))
                    }
                    return
                }
                if let pause = attributes[.shotnixPause] as? Int {
                    model.shortenPause(before: pause)
                    return
                }
                index += before ? -1 : 1
            }
        }

        func restoreSelection() {
            guard let textView else { return }
            let selection = indices(in: textView.selectedRange())
            model.restoreWords(selection.words)
        }

        func click(at characterIndex: Int) {
            guard let storage = textView?.textStorage, characterIndex >= 0, characterIndex < storage.length else { return }
            if let index = storage.attribute(.shotnixWord, at: characterIndex, effectiveRange: nil) as? Int, words.indices.contains(index) {
                model.seek(toWord: words[index])
            }
        }

        var hasCutWordsInSelection: Bool {
            guard let textView else { return false }
            return indices(in: textView.selectedRange()).words.contains { words.indices.contains($0) && !model.isIncluded(words[$0]) }
        }

        func showFind() {
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(sender)
        }

        func playFromSelection() {
            guard let textView else { return }
            if let first = indices(in: textView.selectedRange()).words.first, words.indices.contains(first) {
                model.seek(toWord: words[first])
            }
            if !model.isPlaying { model.togglePlay() }
        }
    }
}

/// Read-only text view whose Delete key edits the VIDEO.
final class TranscriptTextView: NSTextView {
    weak var coordinator: VideoTranscriptEditor.Coordinator?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, modifiers) {
        case (51, []), (117, []):
            // Words (or a pause) are selected: ⌫ cuts them from the video.
            // With just a cursor, ⌫ takes the word before it (⌦ the one
            // after) — never a clip selected on the timeline.
            if selectedRange().length > 0 {
                coordinator?.deleteSelection()
            } else {
                coordinator?.deleteWord(before: event.keyCode == 51)
            }
        case (123, _), (124, _), (125, _), (126, _):
            // Arrows move through the text (⇧ extends the selection).
            super.keyDown(with: event)
        default:
            if modifiers == [.command], key == "z" {
                coordinator?.model.undo()
            } else if modifiers == [.command, .shift], key == "z" {
                coordinator?.model.redo()
            } else if let model = coordinator?.model, MainActor.assumeIsolated({ model.handleKey(event) }) {
                // Space, S, Z, T… and ⌫ with nothing selected work as they
                // do anywhere else in the editor.
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘F / ⌘G search the transcript (the app menu has no Find item).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let action: NSTextFinder.Action?
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case ([.command], "f"): action = .showFindInterface
        case ([.command], "g"): action = .nextMatch
        case ([.command, .shift], "g"): action = .previousMatch
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // A plain click (no selection) jumps to the word under the pointer —
        // only when it's really on a word, not beside or after it.
        guard selectedRange().length == 0,
              let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.insetBy(dx: -1, dy: -2).contains(inContainer) else { return }
        coordinator?.click(at: layoutManager.characterIndexForGlyph(at: glyph))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let hasSelection = selectedRange().length > 0
        let cut = NSMenuItem(title: "Cut from Video", action: #selector(cutFromVideo), keyEquivalent: "")
        cut.target = self
        cut.isEnabled = hasSelection
        menu.addItem(cut)
        if coordinator?.hasCutWordsInSelection == true {
            let restore = NSMenuItem(title: "Restore", action: #selector(restoreWords), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
        }
        let play = NSMenuItem(title: "Play from Here", action: #selector(playFromHere), keyEquivalent: "")
        play.target = self
        menu.addItem(play)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func cutFromVideo() { coordinator?.deleteSelection() }
    @objc private func restoreWords() { coordinator?.restoreSelection() }
    @objc private func playFromHere() { coordinator?.playFromSelection() }
}

extension VideoEditorTheme {
    static let captionNS = NSColor(red: 0.2, green: 0.74, blue: 0.68, alpha: 1)
}
