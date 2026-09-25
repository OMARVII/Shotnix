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
    }

    @MainActor
    final class Coordinator {
        let model: VideoEditorModel
        weak var textView: TranscriptTextView?
        private var revision = -1
        private var words: [VideoTranscriptWord] = []
        private var wordRanges: [NSRange] = []
        private var highlighted: Int?
        private static let font = NSFont.systemFont(ofSize: 13)
        private static let pauseFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

        init(model: VideoEditorModel) {
            self.model = model
        }

        func refresh(revision: Int) {
            guard revision != self.revision, let textView else { return }
            self.revision = revision
            let visible = textView.visibleRect
            words = model.transcriptWords
            let text = NSMutableAttributedString()
            wordRanges = []
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 10
            for (index, word) in words.enumerated() {
                if index > 0 {
                    let previous = words[index - 1]
                    let gap = word.start - previous.end
                    let sentenceEnd = previous.text.last.map { ".?!".contains($0) } ?? false
                    if gap > 1.0 {
                        text.append(NSAttributedString(string: " "))
                        let pauseIncluded = model.isIncluded(sourceTime: (previous.end + word.start) / 2)
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
                let included = model.isIncluded(word)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.font,
                    .foregroundColor: NSColor.white.withAlphaComponent(included ? 0.9 : 0.3),
                    .shotnixWord: index,
                ]
                if !included {
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
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            highlighted = nil
            textView.scrollToVisible(visible)
        }

        /// Marks the word being spoken.
        func highlight(sourceTime: Double, playing: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let index = words.lastIndex { $0.start <= sourceTime + 0.02 }.flatMap { words[$0].end + 0.25 >= sourceTime ? $0 : nil }
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
        case (51, []) where selectedRange().length > 0, (117, []) where selectedRange().length > 0:
            // Words (or a pause) are selected: ⌫ cuts them from the video.
            coordinator?.deleteSelection()
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
