import AppKit
import SwiftUI

struct VideoEditorRootView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VideoEditorToolbar(model: model)
                    .frame(height: 52)
                Rectangle().fill(VideoEditorTheme.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        VideoEditorTheme.stage
                        VideoStageView(model: model)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 22)
                        if let notice = model.notice {
                            VideoNoticePill(notice: notice)
                                .padding(.top, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        VStack {
                            Spacer()
                            if model.isCropping {
                                VideoCropBar(model: model)
                                    .padding(.bottom, 12)
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
                    .frame(height: timelineHeight)
            }

            if model.isExportPresented {
                VideoExportSheet(model: model)
                    .transition(.opacity)
            }
            if model.isCommandPalettePresented {
                VideoCommandPalette(model: model)
                    .transition(.opacity)
            }
            if model.isShortcutsPresented {
                VideoShortcutsSheet(model: model)
                    .transition(.opacity)
            }
            if !model.isReady {
                loadingOverlay
            }
        }
        .background(VideoEditorTheme.window)
        .background(VideoKeyboardBridge(model: model).frame(width: 0, height: 0))
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task { await model.load() }
    }

    private var timelineHeight: CGFloat {
        let content = VideoTimelineMetrics.contentHeight(model.project)
        return min(max(44 + 1 + content + 10, 190), 380)
    }

    private var loadingOverlay: some View {
        ZStack {
            VideoEditorTheme.window.opacity(0.92)
            VStack(spacing: 12) {
                if let error = model.loadError {
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
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                    Button { model.redo() } label: {
                        Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 28)
                    }
                    .buttonStyle(VideoToolButtonStyle())
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
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
            .disabled(!model.project.canReframe)
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
        private weak var view: NSView?

        init(model: VideoEditorModel) {
            self.model = model
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] incoming in
                nonisolated(unsafe) let event = incoming
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self,
                          let window = self.view?.window,
                          window.isKeyWindow,
                          event.window === window else { return false }
                    if let responder = window.firstResponder, responder is NSText || responder is NSTextField {
                        // Esc leaves a text field; everything else types.
                        if event.keyCode == 53 {
                            window.makeFirstResponder(nil)
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
        }
    }
}

extension VideoEditorModel {
    /// Returns true when the key was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        // Modal surfaces first.
        if isExportPresented {
            if code == 53, !isExporting {
                withAnimation(.easeOut(duration: 0.15)) { isExportPresented = false }
                return true
            }
            return modifiers.isEmpty
        }
        if isCommandPalettePresented || isShortcutsPresented {
            if code == 53 {
                isCommandPalettePresented = false
                isShortcutsPresented = false
                return true
            }
            return false
        }

        if isCropping {
            switch code {
            case 53, 36, 76: endCrop(); return true
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
        case ([.command], "d"):
            if let id = selectedZoomID { duplicateZoom(id) }
            return true
        case ([.command], "="), ([.command], "+"): timelineZoom = min(timelineZoom * 1.4, 40); return true
        case ([.command], "-"): timelineZoom = max(timelineZoom / 1.4, 1); return true
        default: break
        }

        // Arrows / Home / End.
        switch code {
        case 123: // ←
            if modifiers == [.command] { seek(to: 0) } else if modifiers == [.shift] { jump(by: -1) } else if modifiers.isEmpty { step(frames: -1) } else { return false }
            return true
        case 124: // →
            if modifiers == [.command] { seek(to: timelineDuration) } else if modifiers == [.shift] { jump(by: 1) } else if modifiers.isEmpty { step(frames: 1) } else { return false }
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
            if let id = selectedClipID, let clip = project.timelineClips.first(where: { $0.id == id }) {
                setClipMuted(id, !clip.muted)
            } else {
                setStyle { $0.audio.muted.toggle() }
                showNotice(project.audio.muted ? "Sound off" : "Sound on", symbol: project.audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
        case "=", "+": timelineZoom = min(timelineZoom * 1.4, 40)
        case "-": timelineZoom = max(timelineZoom / 1.4, 1)
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
        .onAppear { focused = true }
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

    private var commands: [Command] {
        [
            Command(id: "export", title: "Export…", symbol: "square.and.arrow.up", shortcut: "⌘E") { model.isExportPresented = true },
            Command(id: "play", title: model.isPlaying ? "Pause" : "Play", symbol: "playpause.fill", shortcut: "Space") { model.togglePlay() },
            Command(id: "split", title: "Split at Playhead", symbol: "scissors", shortcut: "S") { model.splitAtPlayhead() },
            Command(id: "zoom", title: "Add Zoom at Playhead", symbol: "plus.magnifyingglass", shortcut: "Z") { model.addZoom(at: model.clock.time) },
            Command(id: "auto", title: "Auto Zoom from Clicks", symbol: "sparkles", shortcut: "") { model.autoZoom() },
            Command(id: "remove-zooms", title: "Remove All Zooms", symbol: "trash", shortcut: "") { model.removeAllZooms() },
            Command(id: "idle", title: "Speed Up Idle Moments", symbol: "hare", shortcut: "") { model.speedUpIdle() },
            Command(id: "text", title: "Add Text", symbol: "textformat", shortcut: "T") { model.addOverlay(.text) },
            Command(id: "highlight", title: "Add Highlight", symbol: "rectangle.dashed", shortcut: "H") { model.addOverlay(.highlight) },
            Command(id: "arrow", title: "Add Arrow", symbol: "arrow.up.right", shortcut: "A") { model.addOverlay(.arrow) },
            Command(id: "blur", title: "Add Blur", symbol: "eye.slash", shortcut: "B") { model.addOverlay(.blur) },
            Command(id: "shuffle", title: "Shuffle Background", symbol: "dice", shortcut: "") { model.shuffleBackground() },
            Command(id: "full-frame", title: model.project.usesRawSourceFrame ? "Show Background" : "Full Frame (No Background)", symbol: "rectangle.inset.filled", shortcut: "") {
                model.setStyle { $0.padding = $0.usesRawSourceFrame ? VideoStylePreset.factory.padding : 0 }
            },
            Command(id: "save-look", title: "Use This Look for New Recordings", symbol: "checkmark.seal", shortcut: "") { model.saveStyleAsDefault() },
            Command(id: "reset-look", title: "Reset to the Shotnix Look", symbol: "arrow.counterclockwise", shortcut: "") { model.resetStyle() },
            Command(id: "copy-frame", title: "Copy Current Frame", symbol: "photo.on.rectangle", shortcut: "⌘C") { model.copyCurrentFrame() },
            Command(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z") { model.undo() },
            Command(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z") { model.redo() },
            Command(id: "start", title: "Go to Start", symbol: "backward.end.fill", shortcut: "⌘←") { model.seek(to: 0) },
            Command(id: "end", title: "Go to End", symbol: "forward.end.fill", shortcut: "⌘→") { model.seek(to: model.timelineDuration) },
            Command(id: "reveal", title: "Show Recording in Finder", symbol: "folder", shortcut: "") { model.revealSource() },
            Command(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", shortcut: "?") { model.isShortcutsPresented = true },
        ] + VideoDemoProject.AspectPreset.allCases.map { preset in
            Command(id: "aspect-\(preset.rawValue)", title: "Aspect Ratio \(preset.title) — \(preset.detail)", symbol: preset.symbol, shortcut: "") {
                model.setAspect(preset)
            }
        }
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

    private let groups: [(String, [(String, String)])] = [
        ("Playback", [("Space", "Play / pause"), ("J  K  L", "Back · pause · faster"), ("← →", "Previous / next frame"), ("⇧← ⇧→", "Jump one second"), ("⌘← ⌘→", "Start / end")]),
        ("Editing", [("S", "Split at playhead"), ("⇧-drag", "Select a range to cut"), ("I  O", "Clip starts / ends here"), ("⌫", "Delete selection"), ("M", "Mute clip"), ("⌘Z  ⇧⌘Z", "Undo / redo")]),
        ("Camera & callouts", [("Z", "Add zoom at playhead"), ("1 – 5", "Zoom level (zoom selected)"), ("⌘D", "Duplicate zoom"), ("T  H  A  B", "Text · highlight · arrow · blur")]),
        ("General", [("⌘E", "Export"), ("⌘K", "All commands"), ("⌘C", "Copy current frame"), ("⌘ scroll", "Zoom the timeline"), ("Esc", "Deselect / close")]),
    ]

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
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }
    }
}

/// One-time orientation for the first editor session.
struct VideoTipsBar: View {
    @AppStorage("videoEditorTipsDismissed") private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 14) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(Color.yellow)
                tip("Space", "play")
                tip("Hover the purple track", "add a zoom")
                tip("Click a zoom", "aim or resize it")
                tip("⌘E", "export")
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VideoEditorTheme.textSecondary)
                .help("Got it")
                .accessibilityLabel("Dismiss tips")
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .transition(.opacity)
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
