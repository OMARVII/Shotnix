import AppKit
import SwiftUI

@MainActor
final class VideoDemoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [VideoDemoEditorWindowController] = []
    let model: VideoEditorModel
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
        openControllers.forEach { $0.bringEditorToFront() }
    }

    static func splitActiveEditor() { frontController()?.model.splitAtPlayhead() }
    static func deleteActiveSelection() { frontController()?.model.deleteSelection() }
    static func trimActiveInToPlayhead() { frontController()?.model.trimSelectedClipToPlayhead(leading: true) }
    static func trimActiveOutToPlayhead() { frontController()?.model.trimSelectedClipToPlayhead(leading: false) }
    static func undoActiveTimelineEdit() {
        guard let model = frontController()?.model, !model.hasOverlayOpen else { return }
        model.undo()
    }

    static func redoActiveTimelineEdit() {
        guard let model = frontController()?.model, !model.hasOverlayOpen else { return }
        model.redo()
    }

    static func muteActiveClip() {
        guard let model = frontController()?.model, let id = model.selectedClipID,
              let clip = model.project.timelineClips.first(where: { $0.id == id }) else { return }
        model.setClipMuted(id, !clip.muted)
    }

    /// The editor in the key window (menu items act on it only).
    static var keyModel: VideoEditorModel? {
        (NSApplication.shared.keyWindow?.delegate as? VideoDemoEditorWindowController)?.model
    }

    static func exportActive() {
        guard let model = keyModel, model.isReady, !model.isCropping else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.isExportPresented = true }
    }

    static func saveActiveSubtitles() {
        guard let model = keyModel, !model.project.captions.isEmpty else { return }
        model.exportSRT()
    }

    /// Asks for a video to edit (nil: cancelled).
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        Settings.lastRecordingPath = url.path
        return url
    }

    private static func frontController() -> VideoDemoEditorWindowController? {
        openControllers.first(where: { $0.window?.isKeyWindow == true })
            ?? openControllers.first(where: { $0.window?.isVisible == true })
            ?? openControllers.last
    }

    init(videoURL: URL) {
        let sourceURL = Self.canonicalVideoURL(videoURL)
        self.sourceURL = sourceURL
        let model = VideoEditorModel(videoURL: sourceURL)
        self.model = model

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 944)
        let width = min(max(visible.width * 0.9, 1180), 1680)
        let height = min(max(visible.height * 0.92, 760), 1080)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(width, visible.width), height: min(height, visible.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = sourceURL.deletingPathExtension().lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.055, alpha: 1)
        window.minSize = NSSize(width: 1080, height: 700)
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none
        let hosting = VideoEditorHostingView(rootView: VideoEditorRootView(model: model))
        window.contentView = hosting
        window.center()
        window.setFrameAutosaveName("ShotnixVideoEditor")

        super.init(window: window)
        window.delegate = self
        model.closeEditor = { [weak self] in self?.window?.performClose(nil) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Window buttons

    /// The editor draws its own 52pt top bar; the window buttons are
    /// re-centered inside it (the stock title bar is only 28pt tall).
    static let topBarHeight: CGFloat = 52

    private func layoutWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let height = Self.topBarHeight
        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame
        titlebar.frame = NSRect(x: 0, y: 0, width: frame.width, height: height)
        let y = ((height - close.frame.height) / 2).rounded()
        let shiftX = 18 - close.frame.minX
        for button in [close, minimize, zoom] {
            button.setFrameOrigin(NSPoint(x: button.frame.minX + shiftX, y: y))
        }
    }

    func windowDidResize(_ notification: Notification) { layoutWindowButtons() }
    func windowDidEndLiveResize(_ notification: Notification) { layoutWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutWindowButtons() }
    func windowDidBecomeMain(_ notification: Notification) { layoutWindowButtons() }

    /// Closing mid-export (or mid-transcription) asks first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let job = model.runningJobDescription else { return true }
        let alert = NSAlert()
        alert.messageText = "Shotnix is still \(job)"
        alert.informativeText = "Closing the editor stops it."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Stop and Close")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard response == .alertSecondButtonReturn, let self, let sender else { return }
            self.model.stop()
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.openControllers.removeAll { $0 === self }
        ShotnixEditorActivation.sync()
        // Take the editor's views down with the window: the preview's
        // display link would otherwise keep the window, and with it the
        // editor, alive after closing.
        window?.contentView = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
        Self.openControllers.append(self)
        // Renamed in Finder meanwhile: the title and exports follow.
        model.followRenamedRecording()
        window?.title = model.project.sourceURL.deletingPathExtension().lastPathComponent
    }

    func windowDidResignKey(_ notification: Notification) {
        model.saveDraftNow()
    }

    private static func canonicalVideoURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func bringEditorToFront() {
        guard let window else { return }
        NSApp.unhide(nil)
        ShotnixEditorActivation.sync()
        ShotnixEditorActivation.activateApp()
        showWindow(nil)
        layoutWindowButtons()
        window.deminiaturize(nil)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // The editor is open now, so the stop-to-editor foreground hold
        // can end (the editor keeps the app regular on its own).
        ShotnixEditorActivation.releaseForeground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window, window.isVisible else { return }
            // A policy switch right before can make the first activation
            // request miss; ask once more before leaving the floating level.
            if !NSApp.isActive { ShotnixEditorActivation.activateApp() }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Clicks land on the first try even while another app is in front —
/// hitting Play or a timeline tool shouldn't need a focusing click first.
final class VideoEditorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
