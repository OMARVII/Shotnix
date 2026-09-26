import AppKit
import SwiftUI

struct VideoEditorRootView: View {
    @ObservedObject var model: VideoEditorModel
    @AppStorage("videoEditorTipsDismissed") private var tipsDismissed = false

    var body: some View {
        GeometryReader { proxy in
            editor(height: proxy.size.height)
        }
        .background(VideoEditorTheme.window)
        .background(VideoKeyboardBridge(model: model).frame(width: 0, height: 0))
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task { await model.load() }
    }

    /// The crop bar and the tips sit under the picture, never over it.
    private var stageBottomInset: CGFloat {
        if model.isCropping { return 66 }
        return tipsDismissed && !model.suggestsTranscript ? 22 : 58
    }

    private func editor(height: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 0) {
                VideoEditorToolbar(model: model)
                    .frame(height: 52)
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        VideoEditorTheme.stage
                        VStack(spacing: 0) {
                            // The picture tools, centered above the preview.
                            if !model.isCropping {
                                VideoToolDock(model: model)
                                    .padding(.top, 12)
                            }
                            VideoStageView(model: model)
                                .padding(.horizontal, 28)
                                .padding(.top, model.isCropping ? 22 : 12)
                                .padding(.bottom, stageBottomInset)
                        }
                        // With the export sheet up, the message shows on the
                        // sheet instead (see VideoOverlayNotice).
                        if let notice = model.notice, !model.isExportPresented {
                            VideoNoticePill(notice: notice)
                                .padding(.top, model.isCropping ? 12 : 80)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        VStack {
                            Spacer()
                            if model.isCropping {
                                VideoCropBar(model: model)
                                    .padding(.bottom, 12)
                            } else if model.suggestsTranscript {
                                VideoTranscribeSuggestion(model: model)
                                    .padding(.bottom, 10)
                            } else {
                                VideoTipsBar()
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                    Rectangle().fill(VideoEditorTheme.hairline).frame(width: 1)
                    VideoInspectorView(model: model)
                        .frame(width: 318)
                }
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                VideoTimelineView(model: model).equatable()
                    .frame(height: timelineHeight(windowHeight: height))
            }
            // Behind a sheet or the palette, VoiceOver stays in front.
            .accessibilityHidden(model.hasOverlayOpen || !model.isReady)

            if model.isExportPresented {
                VideoExportSheet(model: model)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
            }
            if model.isCommandPalettePresented {
                VideoCommandPalette(model: model)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel("Commands")
            }
            if model.isShortcutsPresented {
                VideoShortcutsSheet(model: model)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
            }
            if !model.isReady {
                loadingOverlay
                    .accessibilityAddTraits(.isModal)
            }
        }
    }

    /// Tall enough for every lane, but the picture keeps at least half the
    /// space under the toolbar (the lanes scroll when they don't fit).
    private func timelineHeight(windowHeight: CGFloat) -> CGFloat {
        let content = VideoTimelineMetrics.contentHeight(model.project)
        let limit = max((windowHeight - 53) * 0.5, 190)
        return min(max(44 + 1 + content + 10, 190), limit)
    }

    private var loadingOverlay: some View {
        ZStack {
            VideoEditorTheme.window.opacity(0.92)
            VStack(spacing: 12) {
                if let failure = model.loadFailure {
                    VideoLoadFailureView(model: model, failure: failure)
                } else if let error = model.loadError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.yellow)
                    Text("Couldn't open this video")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Preparing your video…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Toolbar

struct VideoEditorToolbar: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        ZStack {
            VideoWindowDragArea()
            HStack(spacing: 10) {
                Color.clear.frame(width: 76, height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project.sourceURL.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textTertiary)
                        .lineLimit(1)
                }
                .onTapGesture(count: 2) { model.revealSource() }
                .help("Double-click to show the recording in Finder")

                Spacer(minLength: 12)

                Button {
                    model.isCropping ? model.endCrop() : model.beginCrop()
                } label: {
                    Label(model.project.crop.isFull ? "Crop" : "Cropped", systemImage: "crop")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(model.isCropping ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Crop the recording — trim away toolbars or empty space")

                aspectMenu

                HStack(spacing: 2) {
                    Button { model.undo() } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 28)
                    }
                    .buttonStyle(VideoToolButtonStyle())
                    .disabled(!model.canUndo)
                    .help(model.undoLabel.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)")
                    .accessibilityLabel(model.undoLabel.map { "Undo \($0)" } ?? "Undo")
                    Button { model.redo() } label: {
                        Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 28)
                    }
                    .buttonStyle(VideoToolButtonStyle())
                    .disabled(!model.canRedo)
                    .help(model.redoLabel.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)")
                    .accessibilityLabel(model.redoLabel.map { "Redo \($0)" } ?? "Redo")
                }
                .font(.system(size: 13, weight: .semibold))

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.isCommandPalettePresented = true }
                } label: {
                    Image(systemName: "command")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help("All commands (⌘K)")
                .accessibilityLabel("Commands")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.isShortcutsPresented = true }
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help("Keyboard shortcuts (?)")
                .accessibilityLabel("Keyboard shortcuts")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.isExportPresented = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(VideoPrimaryButtonStyle())
                .help("Export (⌘E)")
                .disabled(!model.isReady)
            }
            .padding(.trailing, 14)
        }
    }

    private var subtitle: String {
        let size = model.project.sourceSize
        var parts: [String] = [VideoEditorModel.timecode(model.timelineDuration)]
        if size.width > 0 { parts.append("\(Int(size.width))×\(Int(size.height))") }
        parts.append("\(Int(model.sourceFrameRate.rounded())) fps")
        return parts.joined(separator: " · ")
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(VideoDemoProject.AspectPreset.allCases) { preset in
                Button {
                    model.setAspect(preset)
                } label: {
                    if preset == model.project.aspectPreset {
                        Label("\(preset.title) — \(preset.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(preset.title) — \(preset.detail)")
                    }
                }
            }
            Divider()
            Toggle("Fill the Frame, Follow the Cursor", isOn: Binding(
                get: { model.project.reframe },
                set: { on in model.setStyle { $0.reframe = on } }
            ))
            .disabled(!model.project.canReframe || (model.project.cursorSamples.isEmpty && !model.project.reframe))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.project.aspectPreset.symbol)
                Text(model.project.aspectPreset.title)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        .help("Aspect ratio")
    }
}

struct VideoNoticePill: View {
    let notice: VideoEditorNotice

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: notice.symbol)
                .font(.system(size: 11, weight: .bold))
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .allowsHitTesting(false)
    }
}

/// The editor's latest message, pinned just above the export sheet so it
/// isn't lost under the dimming ("Copied", "Export cancelled"…).
struct VideoOverlayNotice: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        ZStack {
            if let notice = model.notice {
                VideoNoticePill(notice: notice)
                    .transition(.opacity)
            }
        }
        .offset(y: -42)
        .allowsHitTesting(false)
    }
}

/// In the export summary: says so when the export would be silent though
/// the recording has sound (and turns "Mute video" back off in one click).
struct VideoExportSoundWarning: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        if let warning = model.exportSoundWarning {
            HStack(alignment: .top, spacing: 8) {
                Label(warning, systemImage: "speaker.slash.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.project.audio.muted {
                    Button("Turn On") {
                        model.setStyle { $0.audio.muted = false }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(VideoEditorTheme.textPrimary)
                    .help("Turn the video's sound back on")
                }
            }
        }
    }
}

// MARK: - Keyboard

struct VideoKeyboardBridge: NSViewRepresentable {
    let model: VideoEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class Coordinator {
        private let model: VideoEditorModel
        private var monitor: Any?
        private var clickMonitor: Any?
        private weak var view: NSView?

        init(model: VideoEditorModel) {
            self.model = model
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            // Clicking anywhere outside the text being edited ends the
            // editing, so the editor's keys work again.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] incoming in
                nonisolated(unsafe) let event = incoming
                MainActor.assumeIsolated {
                    guard let self, let window = self.view?.window, event.window === window,
                          let responder = window.firstResponder as? NSView,
                          responder is NSText || responder is NSTextField,
                          // The command palette keeps its search field.
                          !self.model.isCommandPalettePresented else { return }
                    // A field's editor stands in for the field itself.
                    let editing: NSView = (responder as? NSText).flatMap { $0.isFieldEditor ? ($0.delegate as? NSView) : nil } ?? responder
                    let frame = window.contentView?.superview ?? window.contentView
                    let hit = frame?.hitTest(frame?.convert(event.locationInWindow, from: nil) ?? .zero)
                    if let hit, hit === editing || hit.isDescendant(of: editing) { return }
                    // Clicks in the box around the field (its padding) count too.
                    let box = editing.convert(editing.bounds, to: nil).insetBy(dx: -12, dy: -12)
                    if box.contains(event.locationInWindow) { return }
                    window.makeFirstResponder(nil)
                }
                return incoming
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] incoming in
                nonisolated(unsafe) let event = incoming
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self,
                          let window = self.view?.window,
                          window.isKeyWindow,
                          event.window === window else { return false }
                    if let responder = window.firstResponder, responder is NSText || responder is NSTextField {
                        // Esc leaves a text field (and closes the command
                        // palette it belongs to); everything else types.
                        if event.keyCode == 53 {
                            window.makeFirstResponder(nil)
                            if self.model.isCommandPalettePresented { self.model.isCommandPalettePresented = false }
                            return true
                        }
                        return false
                    }
                    return self.model.handleKey(event)
                }
                return consumed ? nil : incoming
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }
    }
}

extension VideoEditorModel {
    /// Returns true when the key was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        // Holding a key down doesn't repeat edits (a held ⌫ would delete
        // clip after clip, a held T stack up texts). Arrows, J/L, and the
        // timeline scale keys still repeat.
        if event.isARepeat, modifiers.isEmpty || modifiers == [.shift],
           [51, 117].contains(code) || ["t", "h", "a", "b", "z", "s", "c", "i", "o", "m", " ", "1", "2", "3", "4", "5", "?"].contains(key) {
            return true
        }

        // Modal surfaces first. Undo never reaches the edit behind them.
        let isUndoKey = key == "z" && (modifiers == [.command] || modifiers == [.command, .shift])
        if isExportPresented {
            if code == 53, !isExporting {
                closeExportSheet()
                return true
            }
            // Return presses the sheet's default button; Tab, Space, and the
            // arrows move through and press its controls.
            if [36, 76, 48, 49, 123, 124, 125, 126].contains(code) { return false }
            return modifiers.isEmpty || isUndoKey
        }
        if isCommandPalettePresented || isShortcutsPresented {
            if code == 53 {
                isCommandPalettePresented = false
                isShortcutsPresented = false
                return true
            }
            return isUndoKey
        }

        if isCropping {
            switch code {
            case 53: cancelCrop(); return true
            case 36, 76: endCrop(); return true
            default:
                if modifiers == [.command], key == "z" { undo(); return true }
                if modifiers == [.command, .shift], key == "z" { redo(); return true }
                return modifiers.isEmpty
            }
        }

        switch (modifiers, key) {
        case ([.command], "z"): undo(); return true
        case ([.command, .shift], "z"): redo(); return true
        case ([.command], "k"):
            withAnimation(.easeOut(duration: 0.15)) { isCommandPalettePresented = true }
            return true
        case ([.command], "e"):
            withAnimation(.easeOut(duration: 0.15)) { isExportPresented = true }
            return true
        case ([.command], "b"): splitAtPlayhead(); return true
        case ([.command], "c"): copyCurrentFrame(); return true
        case ([.command], "f"): findInTranscript(); return true
        case ([.command], "d"):
            if let id = selectedZoomID {
                duplicateZoom(id)
            } else if case .overlay(let id) = selection {
                duplicateOverlay(id)
            } else if selection != .none {
                showNotice("Zooms and annotations can be duplicated", symbol: "plus.square.on.square")
            }
            return true
        case ([.command], "="), ([.command], "+"): zoomTimeline(by: 1.4); return true
        case ([.command], "-"): zoomTimeline(by: 1 / 1.4); return true
        default: break
        }

        // Arrows / Home / End.
        switch code {
        case 123: // ←
            if modifiers == [.command] { seek(to: 0) } else if modifiers == [.shift] { jump(by: -1) } else if modifiers == [.option] { selectAdjacentItem(forward: false) } else if modifiers.isEmpty { step(frames: -1) } else { return false }
            return true
        case 124: // →
            if modifiers == [.command] { seek(to: timelineDuration) } else if modifiers == [.shift] { jump(by: 1) } else if modifiers == [.option] { selectAdjacentItem(forward: true) } else if modifiers.isEmpty { step(frames: 1) } else { return false }
            return true
        case 115: seek(to: 0); return true
        case 119: seek(to: timelineDuration); return true
        case 51, 117:
            guard modifiers.isEmpty || modifiers == [.command] else { return false }
            deleteSelection()
            return true
        case 53:
            if selection != .none { selection = .none } else if isPlaying { pause() }
            return true
        default:
            break
        }

        guard modifiers.isEmpty || (modifiers == [.shift] && key == "?") else { return false }
        if event.characters == "?" {
            withAnimation(.easeOut(duration: 0.15)) { isShortcutsPresented = true }
            return true
        }

        switch key {
        case " ": togglePlay()
        case "s", "c": splitAtPlayhead()
        case "z": addZoom(at: clock.time)
        case "t": addOverlay(.text)
        case "h": addOverlay(.highlight)
        case "a": addOverlay(.arrow)
        case "b": addOverlay(.blur)
        case "i": trimSelectedClipToPlayhead(leading: true)
        case "o": trimSelectedClipToPlayhead(leading: false)
        case "j": shuttleBackward()
        case "k": pause()
        case "l": shuttleForward()
        case "m":
            guard hasAudio else {
                showNotice("This recording has no sound", symbol: "speaker.slash")
                return true
            }
            if let id = selectedClipID, let clip = project.timelineClips.first(where: { $0.id == id }) {
                setClipMuted(id, !clip.muted)
            } else {
                togglePreviewMute()
            }
        case "=", "+": zoomTimeline(by: 1.4)
        case "-": zoomTimeline(by: 1 / 1.4)
        case "1", "2", "3", "4", "5":
            guard let id = selectedZoomID else { return false }
            let levels = ["1": 1.25, "2": 1.5, "3": 2.0, "4": 2.5, "5": 3.0]
            if let level = levels[key] { updateZoom(id) { $0.scale = level } }
        default:
            return false
        }
        return true
    }

    var isExporting: Bool {
        if case .running = exportPhase { return true }
        return false
    }
}

// MARK: - Command palette

struct VideoCommandPalette: View {
    @ObservedObject var model: VideoEditorModel
    @State private var query = ""
    @State private var highlighted = 0
    /// Read once per opening (a file on disk), not on every keystroke.
    @State private var recent: [VideoDemoRecentExport]?
    @AppStorage("videoEditorTipsDismissed") private var tipsDismissed = false
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let shortcut: String
        let action: () -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { model.isCommandPalettePresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                    TextField("Search commands", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($focused)
                        .onSubmit { run(filtered.indices.contains(highlighted) ? filtered[highlighted] : filtered.first) }
                        .onChange(of: query) { _ in highlighted = 0 }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button {
                                run(command)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 20)
                                        .foregroundStyle(VideoEditorTheme.textSecondary)
                                    Text(command.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(VideoEditorTheme.textPrimary)
                                    Spacer()
                                    Text(command.shortcut)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(VideoEditorTheme.textTertiary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(index == highlighted ? Color.white.opacity(0.1) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .padding(.top, 90)
        }
        .onAppear {
            focused = true
            recent = model.recentExports
        }
        .background(
            VideoArrowKeyCatcher { delta in
                guard !filtered.isEmpty else { return }
                highlighted = min(max(highlighted + delta, 0), filtered.count - 1)
            }
        )
    }

    private func run(_ command: Command?) {
        guard let command else { return }
        model.isCommandPalettePresented = false
        command.action()
    }

    private var filtered: [Command] {
        let search = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !search.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(search) }
    }

    var commands: [Command] {
        [
            Command(id: "export", title: "Export…", symbol: "square.and.arrow.up", shortcut: "⌘E") { model.isExportPresented = true },
            Command(id: "play", title: model.isPlaying ? "Pause" : "Play", symbol: "playpause.fill", shortcut: "Space") { model.togglePlay() },
            Command(id: "split", title: "Split at Playhead", symbol: "scissors", shortcut: "S") { model.splitAtPlayhead() },
            Command(id: "zoom", title: "Add Zoom at Playhead", symbol: "plus.magnifyingglass", shortcut: "Z") { model.addZoom(at: model.clock.time) },
            Command(id: "auto", title: "Auto Zoom from Clicks", symbol: "sparkles", shortcut: "") { model.autoZoom() },
            Command(id: "remove-zooms", title: "Remove All Zooms", symbol: "trash", shortcut: "") { model.removeAllZooms() },
            Command(id: "idle", title: "Speed Up Idle Moments", symbol: "hare", shortcut: "") { model.speedUpIdle() },
            Command(id: "crop", title: "Crop the Recording…", symbol: "crop", shortcut: "") { model.beginCrop() },
            Command(id: "text", title: "Add Text", symbol: "textformat", shortcut: "T") { model.addOverlay(.text) },
            Command(id: "highlight", title: "Add Highlight", symbol: "rectangle.dashed", shortcut: "H") { model.addOverlay(.highlight) },
            Command(id: "arrow", title: "Add Arrow", symbol: "arrow.up.right", shortcut: "A") { model.addOverlay(.arrow) },
            Command(id: "blur", title: "Add Blur", symbol: "eye.slash", shortcut: "B") { model.addOverlay(.blur) },
            Command(id: "spotlight", title: "Add Spotlight (Dim Around a Spot)", symbol: VideoDemoOverlayEffectKind.spotlight.icon, shortcut: "") { model.addOverlay(.spotlight) },
            Command(id: "shuffle", title: "Shuffle Background", symbol: "dice", shortcut: "") { model.shuffleBackground() },
            Command(id: "full-frame", title: model.project.usesRawSourceFrame ? "Show Background" : "Full Frame (No Background)", symbol: "rectangle.inset.filled", shortcut: "") {
                model.setStyle { $0.padding = $0.usesRawSourceFrame ? VideoStylePreset.factory.padding : 0 }
            },
            Command(id: "save-look", title: "Use This Look for New Recordings", symbol: "checkmark.seal", shortcut: "") { model.saveStyleAsDefault() },
            Command(id: "reset-look", title: "Reset to the Shotnix Look", symbol: "arrow.counterclockwise", shortcut: "") { model.resetStyle() },
            Command(id: "copy-frame", title: "Copy Current Frame", symbol: "photo.on.rectangle", shortcut: "⌘C") { model.copyCurrentFrame() },
            Command(id: "undo", title: model.undoLabel.map { "Undo \($0)" } ?? "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z") { model.undo() },
            Command(id: "redo", title: model.redoLabel.map { "Redo \($0)" } ?? "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z") { model.redo() },
            Command(id: "start", title: "Go to Start", symbol: "backward.end.fill", shortcut: "⌘←") { model.seek(to: 0) },
            Command(id: "end", title: "Go to End", symbol: "forward.end.fill", shortcut: "⌘→") { model.seek(to: model.timelineDuration) },
            Command(id: "reveal", title: "Show Recording in Finder", symbol: "folder", shortcut: "") { model.revealSource() },
            Command(id: "start-over", title: "Start Over from the Original Recording…", symbol: "arrow.counterclockwise.circle", shortcut: "") { model.startOver() },
            Command(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", shortcut: "?") { model.isShortcutsPresented = true },
        ] + (tipsDismissed ? [Command(id: "tips", title: "Show Editor Tips", symbol: "lightbulb", shortcut: "") { tipsDismissed = false }] : [])
            + scriptCommands + recentCommands + cameraCommands + soundCommands + VideoDemoProject.AspectPreset.allCases.map { preset in
            Command(id: "aspect-\(preset.rawValue)", title: "Aspect Ratio \(preset.title) — \(preset.detail)", symbol: preset.symbol, shortcut: "") {
                model.setAspect(preset)
            }
        }
    }
}

extension VideoCommandPalette {
    /// Words, captions, and edit-by-text — each wherever it can work (typed
    /// captions need no sound).
    fileprivate var scriptCommands: [Command] {
        var commands: [Command] = []
        if model.hasAudio, model.captionTask == nil {
            commands.append(Command(id: "transcribe", title: model.hasTranscript ? "Transcribe Again…" : "Transcribe Narration (Captions, Edit by Text)", symbol: "waveform", shortcut: "") {
                model.inspectorTab = .captions
                model.selection = .none
                model.transcribeAgain()
            })
        }
        if model.hasTranscript {
            commands.append(Command(id: "fillers", title: "Remove Ums", symbol: "wand.and.stars", shortcut: "") { model.removeFillers() })
            commands.append(Command(id: "pauses", title: "Shorten Pauses", symbol: "forward.end", shortcut: "") { model.shortenPauses() })
            commands.append(Command(id: "find", title: "Find in Transcript", symbol: "magnifyingglass", shortcut: "⌘F") { model.findInTranscript() })
        }
        commands.append(Command(id: "caption-line", title: "Add Caption Line at Playhead", symbol: "captions.bubble", shortcut: "") {
            model.inspectorTab = .captions
            model.addCaptionAtPlayhead()
        })
        if !model.project.captions.isEmpty {
            commands.append(Command(id: "srt", title: "Save Subtitles (.srt)…", symbol: "doc.text", shortcut: "") { model.exportSRT() })
        }
        return commands
    }

    /// This recording's latest exports, shown in Finder.
    fileprivate var recentCommands: [Command] {
        (recent ?? model.recentExports).prefix(3).map { export in
            Command(id: "recent-\(export.id)", title: "Show Recent Export “\(export.exportURL.lastPathComponent)” in Finder", symbol: "clock.arrow.circlepath", shortcut: "") {
                model.revealExport(export.exportURL)
            }
        }
    }

    fileprivate var cameraCommands: [Command] {
        guard model.hasWebcamFootage else { return [] }
        return [
            Command(id: "camera-full", title: "Full Camera at Playhead", symbol: "person.crop.rectangle", shortcut: "") { model.addCameraLayout(.fullscreen) },
            Command(id: "camera-side", title: "Camera Side by Side at Playhead", symbol: "rectangle.split.2x1", shortcut: "") { model.addCameraLayout(.sideBySide) },
            Command(id: "camera-intro", title: "Full-Camera Intro and Outro", symbol: "person.crop.rectangle.stack", shortcut: "") { model.addCameraIntroOutro() },
        ]
    }

    fileprivate var soundCommands: [Command] {
        var commands: [Command] = []
        if model.hasAudio {
            commands.append(Command(id: "preview-mute", title: model.previewMuted ? "Unmute the Preview" : "Mute the Preview (the Export Keeps Its Sound)", symbol: model.previewMuted ? "speaker.wave.2" : "speaker.slash", shortcut: "M") {
                model.togglePreviewMute()
            })
        }
        if model.canEnhanceVoice || model.project.audio.enhanceVoice {
            let on = model.project.audio.enhanceVoice
            commands.append(Command(id: "enhance", title: on ? "Stop Enhancing Voice" : "Enhance Voice", symbol: "waveform.badge.plus", shortcut: "") {
                model.setStyle { $0.audio.enhanceVoice = !on }
            })
        }
        if model.project.canReframe, !model.project.cursorSamples.isEmpty || model.project.reframe {
            let on = model.project.reframe
            commands.append(Command(id: "reframe", title: on ? "Letterbox Instead of Following the Cursor" : "Fill the Frame, Follow the Cursor", symbol: "rectangle.portrait.arrowtriangle.2.outward", shortcut: "") {
                model.setStyle { $0.reframe = !on }
            })
        }
        return commands
    }
}

/// Up/down arrows while a text field has focus (command palette).
struct VideoArrowKeyCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMove: onMove) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === view.window else { return event }
            switch event.keyCode {
            case 125: context.coordinator.onMove(1); return nil
            case 126: context.coordinator.onMove(-1); return nil
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var onMove: (Int) -> Void
        var monitor: Any?
        init(onMove: @escaping (Int) -> Void) { self.onMove = onMove }
    }
}

// MARK: - Shortcuts sheet

struct VideoShortcutsSheet: View {
    @ObservedObject var model: VideoEditorModel
    @AppStorage("videoEditorTipsDismissed") private var tipsDismissed = false

    /// Every key the editor answers to (VideoEditorModel.handleKey).
    static let groups: [(String, [(String, String)])] = [
        ("Playback", [("Space", "Play / pause"), ("J  K  L", "Back · pause · faster"), ("← →", "Previous / next frame"), ("⇧← ⇧→", "Jump one second"), ("⌘← ⌘→", "Start / end"), ("Home  End", "Start / end"), ("M", "Mute the preview (or the selected clip)")]),
        ("Editing", [("S  C  ⌘B", "Split at playhead"), ("⇧-drag", "Select a range to cut"), ("⇧/⌘-click", "Select several items"), ("I  O", "Clip starts / ends here"), ("⌫", "Delete selection"), ("⌥← ⌥→", "Select previous / next item"), ("⌘Z  ⇧⌘Z", "Undo / redo")]),
        ("Zooms & annotations", [("Z", "Add zoom at playhead"), ("1 – 5", "Zoom level (zoom selected)"), ("⌘D", "Duplicate zoom or annotation"), ("T  H  A  B", "Text · highlight · arrow · blur"), ("Double-click", "Type in a text annotation")]),
        ("Timeline", [("=  −", "Show more / less detail"), ("⌘=  ⌘−", "Show more / less detail"), ("⌘ scroll", "Zoom in at the pointer")]),
        ("General", [("⌘E", "Export"), ("⌘K", "All commands"), ("⌘C", "Copy current frame"), ("⌘F", "Find in the transcript"), ("?", "This list"), ("Esc", "Deselect / close")]),
    ]

    private var groups: [(String, [(String, String)])] { Self.groups }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { model.isShortcutsPresented = false }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(VideoEditorTheme.textPrimary)
                    Spacer()
                    Button { model.isShortcutsPresented = false } label: {
                        Image(systemName: "xmark").frame(width: 26, height: 26)
                    }
                    .buttonStyle(VideoToolButtonStyle())
                    .help("Close (Esc)")
                    .accessibilityLabel("Close")
                }
                HStack(alignment: .top, spacing: 28) {
                    ForEach(0..<2, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(groups.indices.filter { $0 % 2 == column }, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(groups[index].0.uppercased())
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .tracking(0.5)
                                        .foregroundStyle(VideoEditorTheme.textTertiary)
                                    ForEach(groups[index].1, id: \.0) { item in
                                        HStack {
                                            Text(item.0)
                                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(VideoEditorTheme.textPrimary)
                                                .frame(width: 92, alignment: .leading)
                                            Text(item.1)
                                                .font(.system(size: 12))
                                                .foregroundStyle(VideoEditorTheme.textSecondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 280, alignment: .leading)
                    }
                }
                if tipsDismissed {
                    Button("Show tips under the video again") { tipsDismissed = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(VideoEditorTheme.textSecondary)
                }
            }
            .frame(width: 2 * 280 + 28)
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }
}

/// Under the preview of a narrated recording nobody has transcribed yet:
/// captions and edit-by-text are one click away (and easy to wave off).
struct VideoTranscribeSuggestion: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .foregroundStyle(VideoEditorTheme.caption)
                .accessibilityHidden(true)
            Text("Your narration can become captions — then cut the video by editing its words.")
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Button {
                model.inspectorTab = .captions
                model.selection = .none
                model.generateCaptions()
            } label: {
                Text("Transcribe")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(VideoEditorTheme.primary))
            }
            .buttonStyle(.plain)
            .help("Listens on this Mac — nothing is uploaded")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.dismissTranscriptSuggestion() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(VideoEditorTheme.textSecondary)
            .help("Not for this video")
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(VideoEditorTheme.caption.opacity(0.35), lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }
}

/// A video that couldn't be opened: what happened in plain words, and a
/// way on — another video, the file in Finder, or closing the window.
struct VideoLoadFailureView: View {
    @ObservedObject var model: VideoEditorModel
    let failure: VideoLoadFailure

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: failure.kind == .missing ? "questionmark.folder.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(failure.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
            Text(model.project.sourceURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(failure.message)
                .font(.system(size: 12))
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("Close") { model.closeEditor?() }
                    .buttonStyle(VideoSecondaryButtonStyle())
                if let reveal = revealURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                        .buttonStyle(VideoSecondaryButtonStyle())
                }
                Button("Open Another Video…") {
                    guard let url = VideoDemoEditorWindowController.chooseVideo() else { return }
                    model.closeEditor?()
                    VideoDemoEditorWindowController.open(videoURL: url)
                }
                .buttonStyle(VideoPrimaryButtonStyle())
            }
            .padding(.top, 4)
            Text(failure.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
    }

    /// The file itself, or the folder it was in.
    private var revealURL: URL? {
        let url = model.project.sourceURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let folder = url.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}

/// Annotation and zoom tools where people look for them — centered above
/// the preview, like the screenshot editor's dock. One click adds the
/// effect at the playhead, selected, with handles on the video.
struct VideoToolDock: View {
    @ObservedObject var model: VideoEditorModel

    private static let keys: [VideoDemoOverlayEffectKind: String] = [.text: "T", .arrow: "A", .highlight: "H", .blur: "B"]

    private var selectedKind: VideoDemoOverlayEffectKind? {
        guard case .overlay = model.selection else { return nil }
        return model.selectedOverlay?.kind
    }

    var body: some View {
        HStack(spacing: 6) {
            group {
                ForEach(VideoDemoOverlayEffectKind.allCases) { kind in
                    VideoDockButton(
                        title: kind.title,
                        symbol: kind.icon,
                        tint: VideoEditorTheme.overlayTint(kind),
                        active: selectedKind == kind,
                        help: "Add \(kind.title.lowercased()) at the playhead" + (Self.keys[kind].map { " (\($0))" } ?? "")
                    ) {
                        model.addOverlay(kind)
                    }
                }
            }
            group {
                VideoDockButton(
                    title: "Zoom",
                    symbol: "plus.magnifyingglass",
                    tint: VideoEditorTheme.zoom,
                    active: model.selectedZoomID != nil,
                    help: "Add a zoom at the playhead (Z)"
                ) {
                    model.addZoom(at: model.clock.time)
                    model.inspectorTab = .zoom
                }
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.115).opacity(0.94))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct VideoDockButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let active: Bool
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active || hovered ? tint : VideoEditorTheme.textPrimary)
                    .frame(height: 17)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(active ? VideoEditorTheme.textPrimary : VideoEditorTheme.textSecondary)
            }
            .frame(width: 62, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? tint.opacity(0.22) : (hovered ? Color.white.opacity(0.08) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Tips under the preview, a few at a time: the arrow shows the next few,
/// and each new editor window starts on the next page. Dismissed tips come
/// back from the command palette or the shortcuts sheet.
struct VideoTipsBar: View {
    @AppStorage("videoEditorTipsDismissed") private var dismissed = false
    @State private var page = 0

    static let pages: [[(String, String)]] = [
        [("Space", "play"), ("Hover the Zoom track", "add a zoom"), ("Click a zoom", "aim or resize it"), ("⌘E", "export")],
        [("S", "split at the playhead"), ("⇧-drag the timeline", "select a part to cut"), ("I  O", "trim to the playhead")],
        [("T H A B", "text, highlight, arrow, blur"), ("Click it on the video", "select it"), ("Double-click text", "type")],
        [("⌥← ⌥→", "step through the timeline"), ("⌘-scroll", "zoom the timeline"), ("M", "mute the preview")],
        [("Captions tab", "cut by editing words"), ("⌘K", "every command"), ("?", "all shortcuts")],
    ]

    var body: some View {
        if !dismissed {
            HStack(spacing: 14) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(Color.yellow)
                    .accessibilityHidden(true)
                ForEach(Array(Self.pages[page % Self.pages.count].enumerated()), id: \.offset) { _, item in
                    tip(item.0, item.1)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { page += 1 }
                    Settings.videoEditorTipPage = page
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .help("More tips")
                .accessibilityLabel("More tips")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .help("Hide tips (bring them back from ⌘K or the shortcuts list)")
                .accessibilityLabel("Dismiss tips")
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tips")
            .onAppear {
                // Each editor window starts on the next page.
                page = Settings.videoEditorTipPage
                Settings.videoEditorTipPage = page + 1
            }
        }
    }

    private func tip(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VideoEditorTheme.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            Text(action)
                .foregroundStyle(VideoEditorTheme.textSecondary)
        }
    }
}
