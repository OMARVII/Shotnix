import AppKit

/// Manages the full annotation editor window.
@MainActor
final class AnnotationWindowController: NSWindowController {

    private static let trafficLightReservedWidth: CGFloat = 92
    private static let minimumEditorWidth = trafficLightReservedWidth + AnnotationToolbar.requiredWidth + 20
    private static let initialScreenWidthFraction: CGFloat = 0.96
    private static let initialScreenHeightFraction: CGFloat = 0.92
    private static let initialScreenEdgeInset: CGFloat = 24

    let canvas: AnnotationCanvas
    let toolbar: AnnotationToolbar
    private let historyItem: HistoryItem?
    private let historyManager: HistoryManager?
    private let scrollView: NSScrollView
    /// Set once this session wrote an edit back to the history entry.
    private var didUpdateHistory = false
    private(set) var isClosed = false

    enum UnsavedChangesChoice {
        case save, discard, cancel
    }

    enum QuitReviewChoice {
        case review, discard, cancel
    }

    /// Puts an exported image on the clipboard and says whether it got there.
    var copyImage: (NSImage) -> Bool = { ImageExporter.copyToClipboard(image: $0) }
    var showToast: (_ message: String, _ duration: TimeInterval) -> Void = { ToastWindow.show(message: $0, duration: $1) }
    /// Asks what to do with unsaved changes before closing; nil shows the
    /// standard sheet. Tests answer directly.
    var unsavedChangesPrompt: ((@escaping (UnsavedChangesChoice) -> Void) -> Void)?

    /// With several unsaved editors, quitting first asks whether to review
    /// them one by one; nil shows the standard alert. Tests answer directly.
    static var quitReviewPrompt: ((_ unsavedCount: Int) -> QuitReviewChoice)?

    // Strong references so controllers aren't deallocated while their window is open
    private static var openControllers: [AnnotationWindowController] = []

    static var hasOpenEditors: Bool {
        !openControllers.isEmpty
    }

    static var hasUnsavedChanges: Bool {
        openControllers.contains { $0.canvas.hasUnsavedChanges || $0.canvas.textEditor != nil }
    }

    /// Before quitting: every editor with unsaved changes asks to save them.
    /// `completion(true)` once each one was saved or discarded (and closed),
    /// `false` as soon as one is kept open.
    static func reviewUnsavedChangesBeforeQuitting(_ completion: @escaping (_ canQuit: Bool) -> Void) {
        reviewUnsavedChanges(in: openControllers, completion)
    }

    static func reviewUnsavedChanges(in editors: [AnnotationWindowController], _ completion: @escaping (_ canQuit: Bool) -> Void) {
        let unsaved = editors.filter {
            $0.canvas.commitTextField()
            return $0.canvas.hasUnsavedChanges
        }
        guard !unsaved.isEmpty else { return completion(true) }
        if unsaved.count > 1 {
            switch askToReviewBeforeQuitting(unsavedCount: unsaved.count) {
            case .review:
                break
            case .discard:
                unsaved.forEach { $0.window?.close() }
                return completion(true)
            case .cancel:
                return completion(false)
            }
        }
        reviewOneByOne(unsaved, completion)
    }

    private static func reviewOneByOne(_ editors: [AnnotationWindowController], _ completion: @escaping (Bool) -> Void) {
        // Checked at each step: an editor may have been saved or closed while
        // an earlier one was asking.
        let remaining = editors.drop {
            $0.canvas.commitTextField()
            return $0.isClosed || !$0.canvas.hasUnsavedChanges
        }
        guard let editor = remaining.first else { return completion(true) }
        editor.bringEditorToFront()
        editor.askAboutUnsavedChanges { closed in
            guard closed else { return completion(false) }
            reviewOneByOne(Array(remaining.dropFirst()), completion)
        }
    }

    private static func askToReviewBeforeQuitting(unsavedCount: Int) -> QuitReviewChoice {
        if let quitReviewPrompt { return quitReviewPrompt(unsavedCount) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved edits in \(unsavedCount) screenshots."
        alert.informativeText = "Do you want to review them before quitting?"
        alert.addButton(withTitle: "Review Changes\u{2026}")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .review
        case .alertThirdButtonReturn: return .discard
        default:                      return .cancel
        }
    }

    static func bringOpenEditorsToFront() {
        guard hasOpenEditors else { return }
        NSApp.unhide(nil)
        ShotnixEditorActivation.sync()
        NSApp.activate(ignoringOtherApps: true)
        for controller in openControllers {
            controller.bringEditorToFront()
        }
    }

    static func open(image: NSImage, historyItem: HistoryItem? = nil, historyManager: HistoryManager? = nil) {
        let controller = AnnotationWindowController(image: image, historyItem: historyItem, historyManager: historyManager)
        openControllers.append(controller)
        ShotnixEditorActivation.sync()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if let win = controller.window {
            win.alphaValue = 0
            controller.bringEditorToFront()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
    }

    init(image: NSImage, historyItem: HistoryItem?, historyManager: HistoryManager?) {
        self.historyItem = historyItem
        self.historyManager = historyManager
        self.canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        self.toolbar = AnnotationToolbar()

        let canvasSize = image.size
        let toolbarHeight: CGFloat = 76
        let toolbarDockHeight: CGFloat = 56
        let stageInset: CGFloat = 18

        // Open as large as the visible display safely allows so the image starts with less scrolling.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minimumEditorHeight = 260 + toolbarHeight
        let screenSafeWidth = max(1, screenFrame.width - Self.initialScreenEdgeInset * 2)
        let screenSafeHeight = max(1, screenFrame.height - Self.initialScreenEdgeInset * 2)
        let maxWindowWidth = min(screenSafeWidth, screenFrame.width * Self.initialScreenWidthFraction)
        let maxWindowHeight = min(screenSafeHeight, screenFrame.height * Self.initialScreenHeightFraction)
        let effectiveMinimumWidth = min(Self.minimumEditorWidth, maxWindowWidth)
        let effectiveMinimumHeight = min(minimumEditorHeight, maxWindowHeight)
        let desiredWindowWidth = canvasSize.width + stageInset * 2
        let desiredWindowHeight = canvasSize.height + toolbarHeight + stageInset
        let winW = max(min(desiredWindowWidth, maxWindowWidth), effectiveMinimumWidth)
        let winH = max(min(desiredWindowHeight, maxWindowHeight), effectiveMinimumHeight)
        let windowSize = NSSize(width: winW, height: winH)

        // A normal window, not floating: the editor shows a Dock icon while
        // open (ShotnixEditorActivation), so it can sit behind other apps like
        // any document — and the color panel can't open behind it.
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.title = "Screenshot Editor"
        win.minSize = NSSize(width: effectiveMinimumWidth, height: effectiveMinimumHeight)
        win.center()

        // Scroll view for canvas — clips content properly
        scrollView = NSScrollView(frame: NSRect(
            x: stageInset,
            y: stageInset,
            width: winW - stageInset * 2,
            height: winH - toolbarHeight - stageInset
        ))

        super.init(window: win)

        canvas.backgroundImage = image

        // Center canvas when viewport is larger than the image (eliminates blank side areas)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.autoresizingMask = [.width, .height]
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        // Zoom: pinch-to-zoom plus ⌘+/⌘-/⌘0 handled in AnnotationCanvas.keyDown
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 18
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = ShotnixColors.editorChromeBorder.cgColor
        scrollView.layer?.shadowColor = NSColor.black.cgColor
        scrollView.layer?.shadowOpacity = 0.24
        scrollView.layer?.shadowRadius = 32
        scrollView.layer?.shadowOffset = CGSize(width: 0, height: -18)

        // Floating toolbar dock positioned at top of window
        let toolbarWidth = min(AnnotationToolbar.requiredWidth, max(0, winW - Self.trafficLightReservedWidth - stageInset))
        let toolbarX = max(Self.trafficLightReservedWidth, round((winW - toolbarWidth) / 2))
        toolbar.frame = NSRect(
            x: toolbarX,
            y: winH - toolbarDockHeight - 10,
            width: toolbarWidth,
            height: toolbarDockHeight
        )
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        toolbar.onToolChanged              = { [weak self] tool in self?.canvas.activeTool = tool }
        toolbar.onColorChanged             = { [weak self] color in self?.canvas.setActiveColor(color) }
        toolbar.onLineWidthChanged         = { [weak self] width in self?.canvas.setActiveLineWidth(width) }
        toolbar.onFontSizeChanged          = { [weak self] size in self?.canvas.setActiveFontSize(size) }
        toolbar.onBoldChanged              = { [weak self] bold in self?.canvas.setActiveTextBold(bold) }
        toolbar.onRedactionStrengthChanged = { [weak self] strength in self?.canvas.setActiveRedactionStrength(strength) }
        toolbar.onRoundedCornersChanged    = { [weak self] rounded in self?.canvas.setRoundedRectangles(rounded) }
        toolbar.onSpotlightShapeChanged    = { [weak self] ellipse in self?.canvas.setSpotlightEllipse(ellipse) }
        toolbar.onApplyCrop                = { [weak self] in self?.canvas.applyCrop() }
        toolbar.onResetCrop                = { [weak self] in self?.canvas.resetCrop() }
        toolbar.onBackgroundOptionsChanged = { [weak self] options in self?.canvas.setBackgroundOptions(options) }
        toolbar.onSave                     = { [weak self] in self?.save() }
        toolbar.onCopy                     = { [weak self] in self?.copyToClipboard() }

        // Keyboard shortcuts from the canvas (⌘S / ⌘C — no main menu in an LSUIElement app)
        canvas.onSaveRequested = { [weak self] in self?.save() }
        canvas.onCopyRequested = { [weak self] in self?.copyToClipboard() }

        // Keep the toolbar in step with the canvas: keyboard tool switches,
        // the selection's style, crop state, and undo of backdrop changes.
        canvas.onToolChanged = { [weak self] tool in self?.toolbar.selectToolExternally(tool) }
        canvas.onOptionsChanged = { [weak self] in self?.refreshToolbarOptions() }
        canvas.onCropStateChanged = { [weak self] in self?.refreshToolbarOptions() }
        canvas.onBackgroundOptionsChanged = { [weak self] options in self?.toolbar.setBackgroundOptionsExternally(options) }
        canvas.onLayoutChanged = { [weak self] refit in
            if refit { self?.fitCanvasToViewport() }
        }
        // The close button shows the standard unsaved-changes dot.
        canvas.onDirtyStateChanged = { [weak self] in
            guard let self else { return }
            self.window?.isDocumentEdited = self.canvas.hasUnsavedChanges
        }

        // Build hierarchy FIRST, then configure layers (layers don't exist until views are in a window)
        let container = PremiumEditorStageView(frame: NSRect(origin: .zero, size: windowSize))
        container.addSubview(scrollView)
        container.addSubview(toolbar)
        win.contentView = container
        win.delegate = self

        // NOW layers exist — set masksToBounds on the clip view (the actual clipping mechanism)
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true

        // Reflect the restored last-used tool/color/styles in the toolbar
        // (the canvas restored its own state from Settings at init)
        toolbar.selectToolExternally(canvas.activeTool)
        toolbar.setColorExternally(canvas.activeColor)
        toolbar.setBackgroundOptionsExternally(canvas.backgroundOptions)
        refreshToolbarOptions()

        // Fit oversized captures to the visible area on open; smaller images stay at 1:1
        fitCanvasToViewport()

        win.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func bringEditorToFront() {
        guard let window else { return }
        NSApp.unhide(nil)
        ShotnixEditorActivation.sync()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
    }

    private func refreshToolbarOptions() {
        toolbar.showOptions(canvas.toolOptions)
    }

    /// Shows the whole canvas when it's bigger than the viewport; smaller
    /// canvases stay at 1:1.
    private func fitCanvasToViewport() {
        let viewport = scrollView.contentSize
        let size = canvas.frame.size
        guard viewport.width > 0, viewport.height > 0, size.width > 0, size.height > 0 else { return }
        scrollView.magnification = min(1, viewport.width / size.width, viewport.height / size.height)
    }

    // MARK: – Actions

    /// `closed` reports whether the editor closed after saving.
    private func save(thenClose: Bool = false, closed: ((Bool) -> Void)? = nil) {
        canvas.commitPendingEdits()
        let flat = canvas.flatten()
        let revision = canvas.documentRevision
        ImageExporter.saveWithPanel(image: flat, suggestedName: ImageExporter.timestampedName, presentingWindow: window) { [weak self] result in
            guard let self else { closed?(true); return }
            if case .saved(let url) = result {
                self.didExport(flat, revision: revision)
                self.showToast(Self.savedScreenshotMessage(for: url), 3.0)
                if thenClose {
                    self.window?.close()
                    closed?(true)
                    return
                }
            }
            self.bringEditorToFront()
            closed?(false)
        }
    }

    private func copyToClipboard() {
        canvas.commitPendingEdits()
        let flat = canvas.flatten()
        guard copyImage(flat) else {
            showToast("Couldn't copy the screenshot. Try again, or save it instead.", 3.0)
            return
        }
        didExport(flat, revision: canvas.documentRevision)
        showToast("Copied to clipboard", 2.0)
    }

    /// A save or copy succeeded: nothing is unsaved any more, and history
    /// shows the edited screenshot.
    private func didExport(_ image: NSImage, revision: Int) {
        canvas.markSaved(revision: revision)
        guard let historyItem, let historyManager, canvas.hasEdits || didUpdateHistory else { return }
        historyManager.replaceImage(of: historyItem, with: image)
        didUpdateHistory = true
    }

    private static func savedScreenshotMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        return "Saved to \(destination): \(url.lastPathComponent)"
    }

    /// `closed` reports whether the editor ended up closed (saved or
    /// discarded) rather than kept open.
    private func askAboutUnsavedChanges(closed: ((Bool) -> Void)? = nil) {
        let resolve: (UnsavedChangesChoice) -> Void = { [weak self] choice in
            guard let self else { closed?(true); return }
            switch choice {
            case .save:
                self.save(thenClose: true, closed: closed)
            case .discard:
                self.window?.close()
                closed?(true)
            case .cancel:
                closed?(false)
            }
        }
        if let unsavedChangesPrompt {
            unsavedChangesPrompt(resolve)
            return
        }
        guard let window, window.attachedSheet == nil else {
            closed?(false)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to this screenshot?"
        alert.informativeText = "Your edits will be lost if you close without saving or copying them."
        alert.addButton(withTitle: "Save\u{2026}")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            // The save panel is a sheet too; let this one finish closing first.
            DispatchQueue.main.async {
                switch response {
                case .alertFirstButtonReturn: resolve(.save)
                case .alertThirdButtonReturn: resolve(.discard)
                default:                      resolve(.cancel)
                }
            }
        }
    }
}

extension AnnotationWindowController: NSWindowDelegate {
    /// ⌘W, the close button, and Close Window all come through here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextField()
        guard canvas.hasUnsavedChanges else { return true }
        askAboutUnsavedChanges()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        toolbar.detachColorPanel()
        AnnotationWindowController.openControllers.removeAll { $0 === self }
        ShotnixEditorActivation.sync()
    }
}

// MARK: – Centering Clip View

/// Centers the document view when the scroll view viewport is larger than the content.
@MainActor
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }
        let docFrame = documentView.frame
        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

@MainActor
private final class PremiumEditorStageView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [ShotnixColors.editorStageTop.cgColor, ShotnixColors.editorStageBottom.cgColor] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        } else {
            ShotnixColors.editorStageTop.setFill()
            rect.fill()
        }

        drawGlow(in: ctx, rect: rect, color: NSColor.controlAccentColor.withAlphaComponent(0.18), center: CGPoint(x: rect.maxX * 0.72, y: rect.minY + 24), radius: max(rect.width, rect.height) * 0.42)
        drawGlow(in: ctx, rect: rect, color: NSColor.systemPurple.withAlphaComponent(0.12), center: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY + 20), radius: max(rect.width, rect.height) * 0.36)
    }

    private func drawGlow(in context: CGContext, rect: CGRect, color: NSColor, center: CGPoint, radius: CGFloat) {
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        let colorSpace = color.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
    }
}

