import AppKit
import AVFoundation
import QuartzCore
import ScreenCaptureKit
import AudioToolbox

/// Central coordinator for all capture modes.
@MainActor
final class CaptureEngine {

    // Remembers the last selected area for "Capture Previous Area"
    private(set) var lastCaptureRect: CGRect?
    private var areaSelectionWindow: AreaSelectionWindow?
    private var scrollingCapture: ScrollingCaptureController?
    private var recordingControlsWindow: RecordingControlsWindow?
    private var recordingScreenChooserWindow: RecordingScreenChooserWindow?
    private var recordingWindowChooserWindow: RecordingWindowChooserWindow?
    private let recordingEngine = RecordingEngine()

    var recordingActive: Bool { recordingEngine.active }
    var recordingActionsEnabled: Bool { !recordingEngine.active && !recordingSetupActive }

    private var recordingSetupActive: Bool {
        areaSelectionWindow != nil || recordingControlsWindow != nil || recordingScreenChooserWindow != nil || recordingWindowChooserWindow != nil
    }

    private func hideDesktopIconsForCaptureIfNeeded() async -> Bool {
        guard Settings.hideDesktopIconsWhileCapturing else { return false }
        let hiddenByCapture = DesktopIconsManager.hideForCapture()
        if hiddenByCapture {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return hiddenByCapture
    }

    private func restoreDesktopIconsIfNeeded(_ hiddenByCapture: Bool) {
        DesktopIconsManager.showAfterCapture(ifHiddenByCapture: hiddenByCapture)
    }

    // Cached SCShareableContent. `SCShareableContent.excludingDesktopWindows`
    // enumerates every on-screen window and routinely costs 30–100 ms. For
    // area/fullscreen/previous capture modes we only need the display list, and
    // the display list only changes when the user plugs/unplugs a monitor or
    // changes resolution — NSApplication.didChangeScreenParametersNotification
    // is the perfect invalidator.
    @available(macOS 14.0, *)
    private static var cachedContent: SCShareableContent?
    private static var cachedContentIncludesWindows = false
    private static var observerInstalled = false

    init() {
        installScreenChangeObserverIfNeeded()
    }

    private func installScreenChangeObserverIfNeeded() {
        guard !Self.observerInstalled else { return }
        Self.observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if #available(macOS 14.0, *) {
                    Self.cachedContent = nil
                    Self.cachedContentIncludesWindows = false
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func shareableContent(includeWindows: Bool) async throws -> SCShareableContent {
        // Only reuse the cache if it covers what the caller needs. A cache
        // populated for "displays only" can't serve window-capture mode.
        if let cached = cachedContent, cachedContentIncludesWindows || !includeWindows {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: includeWindows
        )
        cachedContent = content
        cachedContentIncludesWindows = includeWindows
        return content
    }

    // MARK: – Area Capture

    func startAreaCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return } // already selecting
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            self.lastCaptureRect = rect
            Task {
                await self.captureRect(rect, on: screen, historyManager: historyManager)
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: – Window Capture

    func startWindowCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .window) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                await self.captureRect(rect, on: screen, historyManager: historyManager)
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: – Fullscreen

    func captureFullscreen(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        // Capture the main (key) screen
        let screen = NSScreen.main ?? screens[0]
        let rect = screen.frame
        await captureRect(rect, on: screen, historyManager: historyManager)
    }

    // MARK: – Screen Recording

    func startAreaRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }

        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.lastCaptureRect = rect
            self.showRecordingControls(rect: rect, on: screen, target: .area)
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    func startWindowRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let choices = recordingWindowChoices(from: content.windows)
            guard !choices.isEmpty else {
                ToastWindow.show(message: "No recordable windows found")
                return
            }

            let chooser = RecordingWindowChooserWindow(
                choices: choices,
                selectHandler: { [weak self] choice in
                    guard let self else { return }
                    self.recordingWindowChooserWindow = nil
                    self.showRecordingControls(
                        rect: choice.previewRect,
                        on: choice.screen,
                        target: .window,
                        selectedWindow: choice.window
                    )
                },
                closeHandler: { [weak self] in
                    self?.recordingWindowChooserWindow = nil
                }
            )
            recordingWindowChooserWindow = chooser
            chooser.show()
        } catch {
            ToastWindow.show(message: "Could not list windows. Check permissions.")
            print("[Shotnix] Window picker failed: \(error)")
        }
    }

    func startFullscreenRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        guard screens.count > 1 else {
            let screen = screens[0]
            showRecordingControls(rect: screen.frame, on: screen, target: .fullscreen)
            return
        }

        recordingScreenChooserWindow?.closeChooser()
        let chooser = RecordingScreenChooserWindow(
            screens: screens,
            selectHandler: { [weak self] screen in
                self?.recordingScreenChooserWindow = nil
                self?.showRecordingControls(rect: screen.frame, on: screen, target: .fullscreen)
            },
            closeHandler: { [weak self] in
                self?.recordingScreenChooserWindow = nil
            }
        )
        recordingScreenChooserWindow = chooser
        chooser.show()
    }

    private func canBeginRecordingSetup() -> Bool {
        guard !recordingEngine.active else {
            ToastWindow.show(message: "Recording already in progress")
            return false
        }
        guard !recordingSetupActive else {
            ToastWindow.show(message: "Finish or cancel the current recording setup")
            return false
        }
        return true
    }

    private func recordingWindowChoices(from windows: [SCWindow]) -> [RecordingWindowChoice] {
        let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
        return windows.compactMap { window in
            guard window.frame.width >= 96, window.frame.height >= 64 else { return nil }
            if window.owningApplication?.processID == currentProcessID { return nil }

            let appName = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? "App"
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || appName != "App" else { return nil }

            let screen = screen(containing: window.frame) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return nil }
            let previewRect = CGRect(
                x: screen.frame.midX - window.frame.width / 2,
                y: min(screen.visibleFrame.maxY - window.frame.height - 24, screen.visibleFrame.midY),
                width: window.frame.width,
                height: window.frame.height
            )
            return RecordingWindowChoice(window: window, appName: appName, title: title, frame: window.frame, screen: screen, previewRect: previewRect)
        }
        .sorted {
            let lhs = "\($0.appName) \($0.title)".localizedLowercase
            let rhs = "\($1.appName) \($1.title)".localizedLowercase
            return lhs < rhs
        }
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(rect).width * lhs.frame.intersection(rect).height < rhs.frame.intersection(rect).width * rhs.frame.intersection(rect).height
        }
    }

    private func showRecordingControls(rect: CGRect, on screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow? = nil) {
        recordingControlsWindow?.closeControls()
        let window = RecordingControlsWindow(
            rect: rect,
            screen: screen,
            target: target,
            selectedWindow: selectedWindow,
            startHandler: { [weak self] rect, screen, selectedWindow in
                Task {
                    if let selectedWindow {
                        await self?.recordingEngine.startRecording(window: selectedWindow, on: screen)
                    } else {
                        await self?.recordingEngine.startRecording(rect: rect, on: screen)
                    }
                }
            },
            closeHandler: { [weak self] in
                self?.recordingControlsWindow = nil
            }
        )
        recordingControlsWindow = window
        window.show()
    }

    func stopRecording() {
        guard recordingEngine.active else {
            ToastWindow.show(message: "No recording in progress")
            return
        }
        recordingEngine.stopRecording()
    }

    // MARK: – Previous Area

    func capturePreviousArea(historyManager: HistoryManager) async {
        guard let rect = lastCaptureRect else {
            await startAreaCapture(historyManager: historyManager)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
            await startAreaCapture(historyManager: historyManager); return
        }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        await captureRect(rect, on: screen, historyManager: historyManager)
    }

    // MARK: – Scrolling Capture

    func startScrollingCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard scrollingCapture?.isActive != true else { return }
        scrollingCapture = ScrollingCaptureController()
        await scrollingCapture?.start(historyManager: historyManager, hiddenDesktopIconsByCapture: await hideDesktopIconsForCaptureIfNeeded())
    }

    // MARK: – OCR Capture

    func startOCRCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                guard let image = await self.captureRectToImage(rect, on: screen) else {
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                    return
                }
                let text = await OCREngine.recognizeText(in: image)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.showOCRNotification(text: text)
                }
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: – QR Capture

    func startQRCodeCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                guard let image = await self.captureRectToImage(rect, on: screen) else {
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                    return
                }
                let results = await QRCodeEngine.detect(in: image)
                await MainActor.run {
                    if results.isEmpty {
                        ToastWindow.show(message: "No QR code found in this selection")
                    } else {
                        QRCodeResultWindow.show(results: results)
                    }
                }
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: – Core capture

    func captureRect(_ rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        guard let image = await captureRectToImage(rect, on: screen) else { return }
        playCaptureSound()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = historyManager.add(image: image, rect: rect)

        // After-capture auto-actions (from Preferences)
        if Settings.afterCaptureCopyToClipboard {
            ImageExporter.copyToClipboard(image: image)
        }
        if Settings.afterCaptureSaveAutomatically {
            let dir = Settings.autoSaveLocation
            let name = ImageExporter.timestampedName
            let ext = Settings.screenshotFormat
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            ImageExporter.save(image: image, to: url)
        }
        if Settings.afterCaptureShowOverlay {
            QuickAccessOverlay.show(image: image, historyItem: item, historyManager: historyManager)
        }
    }

    private func playCaptureSound() {
        guard Settings.playSounds else { return }
        AudioServicesPlaySystemSound(1108)
    }

    func captureRectToImage(_ rect: CGRect, on screen: NSScreen) async -> NSImage? {
        if #available(macOS 14.0, *) {
            return await captureRectSCK(rect, on: screen)
        } else {
            return fallbackCapture(rect: rect)
        }
    }

    @available(macOS 14.0, *)
    private func captureRectSCK(_ rect: CGRect, on screen: NSScreen) async -> NSImage? {
        do {
            // captureRectSCK only needs the display list — no window enumeration.
            let content = try await Self.shareableContent(includeWindows: false)
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
                return fallbackCapture(rect: rect)
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let s: CGFloat = CGFloat(filter.pointPixelScale)

            // Snap rect to integer pixel boundaries to avoid subpixel sampling.
            // Fractional sourceRect coords cause SCK to interpolate between pixels,
            // softening text and sharp edges.
            let ox = floor((rect.origin.x - screen.frame.origin.x) * s) / s
            let oy = floor((rect.origin.y - screen.frame.origin.y) * s) / s
            let w  = ceil(rect.width * s) / s
            let h  = ceil(rect.height * s) / s

            // Convert from AppKit (bottom-left origin) to ScreenCaptureKit (top-left origin)
            let screenHeight = screen.frame.height
            let sckRect = CGRect(x: ox, y: screenHeight - oy - h, width: w, height: h)

            let pixelW = Int(w * s)
            let pixelH = Int(h * s)

            let config = SCStreamConfiguration()
            config.sourceRect = sckRect
            config.width = pixelW
            config.height = pixelH
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            // Don't set colorSpaceName — SCK defaults to the display's native
            // calibrated ICC profile, preserving exact on-screen colors.
            // Forcing sRGB or Display P3 overrides the display calibration.

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let logicalSize = NSSize(width: w, height: h)
            return Self.nsImage(from: cgImage, logicalSize: logicalSize)
        } catch {
            return fallbackCapture(rect: rect)
        }
    }

    private func fallbackCapture(rect: CGRect) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, .bestResolution) else { return nil }
        return Self.nsImage(from: cgImage, logicalSize: rect.size)
    }

    /// Creates an NSImage backed by NSBitmapImageRep so the raw CGImage pixels
    /// are preserved through the entire pipeline (no CoreGraphics re-render).
    /// Safe to call from any thread — touches no actor-isolated state.
    nonisolated static func nsImage(from cgImage: CGImage, logicalSize: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize   // logical size for display; pixel data untouched
        let image = NSImage(size: logicalSize)
        image.addRepresentation(rep)
        return image
    }

    // MARK: – OCR notification

    private func showOCRNotification(text: String) {
        let preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        let message = preview.isEmpty ? "No text recognized" : "✓ Text copied to clipboard"
        ToastWindow.show(message: message)
    }
}

@MainActor
private struct RecordingWindowChoice {
    let window: SCWindow
    let appName: String
    let title: String
    let frame: CGRect
    let screen: NSScreen
    let previewRect: CGRect

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var subtitle: String {
        "\(appName) · \(Int(frame.width)) × \(Int(frame.height))"
    }
}

@MainActor
private enum RecordingTargetKind {
    case area
    case window
    case fullscreen

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Display"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        }
    }
}

@MainActor
private final class RecordingWindowChooserWindow: NSWindow {

    private static var openWindows: [RecordingWindowChooserWindow] = []
    private static let panelWidth: CGFloat = 560
    private static let panelHeight: CGFloat = 420
    private static let headerHeight: CGFloat = 74

    private let choices: [RecordingWindowChoice]
    private let selectHandler: (RecordingWindowChoice) -> Void
    private let closeHandler: () -> Void
    private var keyMonitor: Any?
    private var didClose = false

    init(choices: [RecordingWindowChoice], selectHandler: @escaping (RecordingWindowChoice) -> Void, closeHandler: @escaping () -> Void) {
        self.choices = choices
        self.selectHandler = selectHandler
        self.closeHandler = closeHandler
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionChooser()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildContent() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.58
        root.layer?.shadowRadius = 28
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        let panel = NSView(frame: root.bounds)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 20
        panel.layer?.cornerCurve = .continuous
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.026, alpha: 0.985).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.addSubview(panel)

        let title = label("Choose window", size: 15, weight: .bold, color: .white)
        title.frame = NSRect(x: 22, y: frame.height - 40, width: 220, height: 20)
        panel.addSubview(title)

        let subtitle = label("Select a window to record without blocking other apps", size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.48))
        subtitle.frame = NSRect(x: 22, y: frame.height - 60, width: 340, height: 14)
        panel.addSubview(subtitle)

        let closeButton = RecordingChooserCloseButton(frame: NSRect(x: frame.width - 44, y: frame.height - 44, width: 28, height: 28))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        panel.addSubview(closeButton)

        let scrollFrame = NSRect(x: 14, y: 14, width: frame.width - 28, height: frame.height - Self.headerHeight - 18)
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        panel.addSubview(scroll)

        let rowHeight: CGFloat = 54
        let documentHeight = max(scrollFrame.height, CGFloat(choices.count) * rowHeight)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: scrollFrame.width, height: documentHeight))
        scroll.documentView = document

        for (index, choice) in choices.enumerated() {
            let y = documentHeight - CGFloat(index + 1) * rowHeight
            let button = RecordingWindowChoiceButton(frame: NSRect(x: 0, y: y + 5, width: scrollFrame.width - 4, height: rowHeight - 8), choice: choice)
            button.target = self
            button.action = #selector(windowChosen(_:))
            document.addSubview(button)
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func positionChooser() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 72)
        setFrameOrigin(NSPoint(x: max(visible.minX + 24, min(origin.x, visible.maxX - frame.width - 24)), y: max(visible.minY + 24, origin.y)))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closeChooser()
                return nil
            }
            return event
        }
    }

    private func closeChooser(notify: Bool = true) {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        if notify { closeHandler() }
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    @objc private func windowChosen(_ sender: RecordingWindowChoiceButton) {
        let choice = sender.choice
        closeChooser(notify: false)
        selectHandler(choice)
    }

    @objc private func closeTapped() {
        closeChooser()
    }
}

@MainActor
private final class RecordingWindowChoiceButton: NSButton {

    let choice: RecordingWindowChoice

    init(frame: NSRect, choice: RecordingWindowChoice) {
        self.choice = choice
        super.init(frame: frame)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor

        let icon = NSImageView(frame: NSRect(x: 14, y: 15, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.84)
        addSubview(icon)

        let titleField = NSTextField(labelWithString: choice.displayTitle)
        titleField.font = .systemFont(ofSize: 12.5, weight: .bold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: 44, y: 25, width: frame.width - 132, height: 16)
        addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: choice.subtitle)
        subtitleField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.46)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.frame = NSRect(x: 44, y: 9, width: frame.width - 132, height: 13)
        addSubview(subtitleField)

        let actionField = NSTextField(labelWithString: "Select")
        actionField.font = .systemFont(ofSize: 10, weight: .bold)
        actionField.textColor = NSColor.systemRed.withAlphaComponent(0.92)
        actionField.alignment = .right
        actionField.frame = NSRect(x: frame.width - 78, y: 18, width: 56, height: 13)
        addSubview(actionField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
    }
}

@MainActor
private final class RecordingScreenChooserWindow: NSWindow {

    private static var openWindows: [RecordingScreenChooserWindow] = []
    private static let panelWidth: CGFloat = 384
    private static let headerHeight: CGFloat = 80
    private static let rowStride: CGFloat = 52
    private static let rowHeight: CGFloat = 44
    private static let bottomPadding: CGFloat = 16

    private let screens: [NSScreen]
    private let selectHandler: (NSScreen) -> Void
    private let closeHandler: () -> Void
    private var keyMonitor: Any?
    private var didClose = false

    init(screens: [NSScreen], selectHandler: @escaping (NSScreen) -> Void, closeHandler: @escaping () -> Void) {
        self.screens = screens
        self.selectHandler = selectHandler
        self.closeHandler = closeHandler

        let height = Self.headerHeight + CGFloat(screens.count) * Self.rowStride + Self.bottomPadding
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionChooser()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func closeChooser() {
        closeChooser(notify: true)
    }

    private func buildContent() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.58
        root.layer?.shadowRadius = 28
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        let panel = NSView(frame: root.bounds)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.cornerCurve = .continuous
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.026, alpha: 0.985).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.addSubview(panel)

        let title = label("Choose screen", size: 14, weight: .bold, color: .white)
        title.frame = NSRect(x: 20, y: frame.height - 38, width: 220, height: 18)
        panel.addSubview(title)

        let subtitle = label("Select which display to record fullscreen", size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.48))
        subtitle.frame = NSRect(x: 20, y: frame.height - 59, width: 288, height: 14)
        panel.addSubview(subtitle)

        let closeButton = RecordingChooserCloseButton(frame: NSRect(x: frame.width - 42, y: frame.height - 42, width: 28, height: 28))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        panel.addSubview(closeButton)

        for (index, screen) in screens.enumerated() {
            let y = frame.height - Self.headerHeight - Self.rowHeight - CGFloat(index) * Self.rowStride
            let button = RecordingScreenChoiceButton(
                frame: NSRect(x: 14, y: y, width: frame.width - 28, height: Self.rowHeight),
                title: screenTitle(for: screen, index: index),
                subtitle: screenSubtitle(for: screen)
            )
            button.tag = index
            button.target = self
            button.action = #selector(screenChosen(_:))
            panel.addSubview(button)
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func screenTitle(for screen: NSScreen, index: Int) -> String {
        if let main = NSScreen.main, screen === main {
            return "Display \(index + 1) · Main"
        }
        return "Display \(index + 1)"
    }

    private func screenSubtitle(for screen: NSScreen) -> String {
        "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
    }

    private func positionChooser() {
        let screen = NSScreen.main ?? screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 72)
        setFrameOrigin(pixelAligned(NSPoint(x: max(visible.minX + 24, min(origin.x, visible.maxX - frame.width - 24)), y: max(visible.minY + 24, origin.y)), scale: screen?.backingScaleFactor ?? 2))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closeChooser()
                return nil
            }
            return event
        }
    }

    private func closeChooser(notify: Bool) {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        if notify { closeHandler() }
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    @objc private func screenChosen(_ sender: NSButton) {
        guard screens.indices.contains(sender.tag) else { return }
        let screen = screens[sender.tag]
        closeChooser(notify: false)
        selectHandler(screen)
    }

    @objc private func closeTapped() {
        closeChooser()
    }
}

@MainActor
private final class RecordingScreenChoiceButton: NSButton {

    init(frame: NSRect, title: String, subtitle: String) {
        super.init(frame: frame)
        isBordered = false
        self.title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor

        let icon = NSImageView(frame: NSRect(x: 14, y: 14, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.84)
        addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .bold)
        titleField.textColor = .white
        titleField.frame = NSRect(x: 42, y: 22, width: frame.width - 104, height: 15)
        addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.46)
        subtitleField.frame = NSRect(x: 42, y: 8, width: 120, height: 13)
        addSubview(subtitleField)

        let actionField = NSTextField(labelWithString: "Record")
        actionField.font = .systemFont(ofSize: 10, weight: .bold)
        actionField.textColor = NSColor.systemRed.withAlphaComponent(0.92)
        actionField.alignment = .right
        actionField.frame = NSRect(x: frame.width - 78, y: 15, width: 56, height: 13)
        addSubview(actionField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
    }
}

@MainActor
private final class RecordingChooserCloseButton: NSButton {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        contentTintColor = NSColor.white.withAlphaComponent(0.58)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?.withSymbolConfiguration(config)
        toolTip = "Cancel"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class RecordingControlsWindow: NSWindow {

    private static var openWindows: [RecordingControlsWindow] = []
    private static let barHeight: CGFloat = 56
    private static let expandedHeight: CGFloat = 92
    private static let panelWidth: CGFloat = 682
    private static let chromeInset: CGFloat = 8

    private let captureRect: CGRect
    private let targetScreen: NSScreen
    private let target: RecordingTargetKind
    private let selectedWindow: SCWindow?
    private let startHandler: (CGRect, NSScreen, SCWindow?) -> Void
    private let closeHandler: () -> Void

    private var keyMonitor: Any?
    private var didClose = false

    private let systemAudioButton = RecordingToggleButton(symbol: "speaker.wave.2.fill", title: "System audio")
    private let microphoneButton = RecordingToggleButton(symbol: "mic.fill", title: "Microphone", activeTint: .systemGreen)
    private let cursorButton = RecordingToggleButton(symbol: "cursorarrow.rays", title: "Cursor")
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneContainer = NSView()
    private let microphoneLevelMeter = RecordingAudioLevelMeter()
    private var microphoneMonitorSession: AVCaptureSession?
    private var microphoneMonitorOutput: AVCaptureAudioDataOutput?
    private var microphoneMonitorDelegate: MicrophoneLevelMonitor?

    init(rect: CGRect, screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow?, startHandler: @escaping (CGRect, NSScreen, SCWindow?) -> Void, closeHandler: @escaping () -> Void) {
        self.captureRect = rect
        self.targetScreen = screen
        self.target = target
        self.selectedWindow = selectedWindow
        self.startHandler = startHandler
        self.closeHandler = closeHandler

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.chromeInset * 2, height: Self.windowHeight(microphone: Settings.recordingMicrophone)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionPanel()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildContent() {
        let screenScale = targetScreen.backingScaleFactor
        let root = RecordingPanelContentView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.contentsScale = screenScale
        contentView = root

        microphoneContainer.frame = NSRect(x: Self.chromeInset + 158, y: Self.chromeInset + 62, width: 352, height: 30)
        microphoneContainer.wantsLayer = true
        microphoneContainer.layer?.cornerRadius = 12
        microphoneContainer.layer?.cornerCurve = .continuous
        microphoneContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.98).cgColor
        microphoneContainer.layer?.borderWidth = 1
        microphoneContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        root.addSubview(microphoneContainer)

        microphonePopup.frame = NSRect(x: 12, y: 2, width: 328, height: 26)
        microphonePopup.bezelStyle = .shadowlessSquare
        microphonePopup.isBordered = false
        microphonePopup.controlSize = .small
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        microphoneContainer.addSubview(microphonePopup)

        let bar = RecordingRoundedRectView(
            frame: NSRect(x: Self.chromeInset, y: Self.chromeInset, width: Self.panelWidth, height: Self.barHeight),
            cornerRadius: 19,
            fillColor: NSColor(calibratedWhite: 0.018, alpha: 0.995),
            strokeColor: NSColor.white.withAlphaComponent(0.18)
        )
        bar.setRoundedShadow(opacity: 0.58, radius: 24, offset: CGSize(width: 0, height: -10))
        root.addSubview(bar)

        let topGlow = NSView(frame: NSRect(x: 18, y: Self.barHeight - 1, width: Self.panelWidth - 36, height: 1))
        topGlow.wantsLayer = true
        topGlow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        bar.addSubview(topGlow)

        let grip = label("⋮⋮", size: 15, weight: .bold, color: NSColor.white.withAlphaComponent(0.24))
        grip.frame = NSRect(x: 10, y: 18, width: 20, height: 20)
        bar.addSubview(grip)

        let sourcePill = pillLabel("\(target.title) · \(Int(captureRect.width)) × \(Int(captureRect.height))", symbol: target.symbol)
        sourcePill.frame = NSRect(x: 32, y: 9, width: 190, height: 38)
        bar.addSubview(sourcePill)

        let audioGroup = segmentContainer(frame: NSRect(x: 234, y: 8, width: 176, height: 40))
        bar.addSubview(audioGroup)
        bar.addSubview(divider(x: 280, height: 22))
        bar.addSubview(divider(x: 326, height: 22))
        bar.addSubview(divider(x: 362, height: 22))

        systemAudioButton.frame = NSRect(x: 238, y: 9, width: 40, height: 38)
        microphoneButton.frame = NSRect(x: 284, y: 9, width: 40, height: 38)
        microphoneLevelMeter.frame = NSRect(x: 332, y: 16, width: 32, height: 24)
        microphoneLevelMeter.isHidden = true
        bar.addSubview(microphoneLevelMeter)
        cursorButton.frame = NSRect(x: 366, y: 9, width: 40, height: 38)
        for button in [systemAudioButton, microphoneButton, cursorButton] {
            button.target = self
            button.action = #selector(toggleChanged(_:))
            bar.addSubview(button)
        }

        let settingsGroup = segmentContainer(frame: NSRect(x: 418, y: 8, width: 166, height: 40))
        bar.addSubview(settingsGroup)
        bar.addSubview(divider(x: 502, height: 22))

        configurePopup(qualityPopup, items: [("Balanced", "balanced"), ("High", "high"), ("Max", "max")])
        qualityPopup.frame = NSRect(x: 424, y: 14, width: 72, height: 28)
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)
        bar.addSubview(qualityPopup)

        configurePopup(fpsPopup, items: [("30 fps", "30"), ("60 fps", "60")])
        fpsPopup.frame = NSRect(x: 510, y: 14, width: 68, height: 28)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        bar.addSubview(fpsPopup)

        let recordButton = RecordingActionButton(symbol: "record.circle", title: "Record")
        recordButton.frame = NSRect(x: 602, y: 9, width: 38, height: 38)
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        bar.addSubview(recordButton)

        let cancelButton = RecordingActionButton(symbol: "xmark", title: "Cancel", tint: .secondaryLabelColor)
        cancelButton.frame = NSRect(x: 642, y: 9, width: 32, height: 38)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        bar.addSubview(cancelButton)

        let escHint = keyHint("esc")
        escHint.frame = NSRect(x: 646, y: 3, width: 24, height: 12)
        bar.addSubview(escHint)

        syncFromSettings()
    }

    private func syncFromSettings() {
        systemAudioButton.isOn = Settings.recordingSystemAudio
        microphoneButton.isOn = Settings.recordingMicrophone
        cursorButton.isOn = Settings.recordingShowsCursor
        selectItem(in: qualityPopup, representedObject: Settings.recordingQuality)
        selectItem(in: fpsPopup, representedObject: String(Settings.recordingFPS))
        reloadMicrophones()
        updateMicrophoneVisibility()
    }

    private func reloadMicrophones() {
        microphonePopup.removeAllItems()
        microphonePopup.addItem(withTitle: "System Default")
        microphonePopup.lastItem?.representedObject = ""
        for device in RecordingMicrophoneDeviceProvider.options {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if !selectItem(in: microphonePopup, representedObject: Settings.recordingMicrophoneDeviceID) {
            microphonePopup.selectItem(at: 0)
            Settings.recordingMicrophoneDeviceID = ""
        }
    }

    private func updateMicrophoneVisibility() {
        microphoneContainer.isHidden = !Settings.recordingMicrophone
        microphoneLevelMeter.isHidden = !Settings.recordingMicrophone
        if Settings.recordingMicrophone {
            startMicrophoneMonitorIfNeeded()
        } else {
            stopMicrophoneMonitor()
            microphoneLevelMeter.setLevel(0)
        }
        resizeForMicrophoneState()
    }

    private func startMicrophoneMonitorIfNeeded() {
        guard microphoneMonitorSession == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureMicrophoneMonitor()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted, Settings.recordingMicrophone {
                        self.configureMicrophoneMonitor()
                    } else {
                        Settings.recordingMicrophone = false
                        self.microphoneButton.isOn = false
                        self.updateMicrophoneVisibility()
                    }
                }
            }
        case .denied, .restricted:
            Settings.recordingMicrophone = false
            microphoneButton.isOn = false
            updateMicrophoneVisibility()
            ToastWindow.show(message: "Microphone permission is required")
        @unknown default:
            break
        }
    }

    private func configureMicrophoneMonitor() {
        guard microphoneMonitorSession == nil,
              let device = RecordingMicrophoneDeviceProvider.device(for: Settings.recordingMicrophoneDeviceID) else { return }
        do {
            let session = AVCaptureSession()
            session.beginConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecordingControlsError.cannotMonitorMicrophone }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            let delegate = MicrophoneLevelMonitor { [weak self] level in
                self?.microphoneLevelMeter.setLevel(level)
            }
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.shotnix.recording.mic-meter", qos: .userInteractive))
            guard session.canAddOutput(output) else { throw RecordingControlsError.cannotMonitorMicrophone }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()

            microphoneMonitorSession = session
            microphoneMonitorOutput = output
            microphoneMonitorDelegate = delegate
        } catch {
            microphoneLevelMeter.setLevel(0)
            print("[Shotnix] Microphone meter failed: \(error)")
        }
    }

    private func stopMicrophoneMonitor() {
        microphoneMonitorSession?.stopRunning()
        microphoneMonitorSession = nil
        microphoneMonitorOutput = nil
        microphoneMonitorDelegate = nil
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, String)]) {
        popup.removeAllItems()
        popup.bezelStyle = .shadowlessSquare
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12, weight: .semibold)
        popup.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        for item in items {
            popup.addItem(withTitle: item.0)
            popup.lastItem?.representedObject = item.1
        }
    }

    private func resizeForMicrophoneState() {
        let newHeight = Self.windowHeight(microphone: Settings.recordingMicrophone)
        guard abs(frame.height - newHeight) > 0.5 else { return }
        let oldFrame = frame
        setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - newHeight, width: oldFrame.width, height: newHeight), display: true)
    }

    private static func windowHeight(microphone: Bool) -> CGFloat {
        (microphone ? expandedHeight : barHeight) + chromeInset * 2
    }

    @discardableResult
    private func selectItem(in popup: NSPopUpButton, representedObject: String) -> Bool {
        for item in popup.itemArray where item.representedObject as? String == representedObject {
            popup.select(item)
            return true
        }
        return false
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func pillLabel(_ text: String, symbol: String) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.105).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor

        let icon = NSImageView(frame: NSRect(x: 12, y: 11, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white.withAlphaComponent(0.86)
        view.addSubview(icon)

        let textField = label(text, size: 11, weight: .bold, color: NSColor.white.withAlphaComponent(0.86))
        textField.frame = NSRect(x: 36, y: 11, width: 146, height: 16)
        textField.lineBreakMode = .byTruncatingTail
        view.addSubview(textField)
        return view
    }

    private func keyHint(_ text: String) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let field = label(text, size: 7.5, weight: .bold, color: NSColor.white.withAlphaComponent(0.42))
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 1, width: 24, height: 9)
        view.addSubview(field)
        return view
    }

    private func segmentContainer(frame: NSRect) -> NSView {
        RecordingRoundedRectView(
            frame: frame,
            cornerRadius: 14,
            fillColor: NSColor.white.withAlphaComponent(0.075),
            strokeColor: NSColor.white.withAlphaComponent(0.055)
        )
    }

    private func divider(x: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: x, y: (Self.barHeight - height) / 2, width: 1, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }

    private func positionPanel() {
        let visible = targetScreen.visibleFrame
        let visibleHeight = Settings.recordingMicrophone ? Self.expandedHeight : Self.barHeight
        let x = visible.midX - Self.panelWidth / 2
        let y = min(visible.maxY - visibleHeight - 28, captureRect.maxY - visibleHeight - 14)
        let visibleOrigin = NSPoint(
            x: max(visible.minX + 16, min(x, visible.maxX - Self.panelWidth - 16)),
            y: max(visible.minY + 16, y)
        )
        setFrameOrigin(pixelAligned(NSPoint(x: visibleOrigin.x - Self.chromeInset, y: visibleOrigin.y - Self.chromeInset)))
    }

    private func pixelAligned(_ point: NSPoint) -> NSPoint {
        let scale = targetScreen.backingScaleFactor
        return NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            return event
        }
    }

    private func closePanel() {
        guard !didClose else { return }
        didClose = true
        stopMicrophoneMonitor()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        closeHandler()
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    func closeControls() {
        closePanel()
    }

    @objc private func toggleChanged(_ sender: RecordingToggleButton) {
        switch sender {
        case systemAudioButton:
            Settings.recordingSystemAudio = sender.isOn
        case microphoneButton:
            Settings.recordingMicrophone = sender.isOn
            if sender.isOn { reloadMicrophones() }
            updateMicrophoneVisibility()
        case cursorButton:
            Settings.recordingShowsCursor = sender.isOn
        default:
            break
        }
    }

    @objc private func qualityChanged() {
        if let value = qualityPopup.selectedItem?.representedObject as? String {
            Settings.recordingQuality = value
        }
    }

    @objc private func fpsChanged() {
        if let value = fpsPopup.selectedItem?.representedObject as? String, let fps = Int(value) {
            Settings.recordingFPS = fps
        }
    }

    @objc private func microphoneChanged() {
        Settings.recordingMicrophoneDeviceID = microphonePopup.selectedItem?.representedObject as? String ?? ""
        if Settings.recordingMicrophone {
            stopMicrophoneMonitor()
            startMicrophoneMonitorIfNeeded()
        }
    }

    @objc private func recordTapped() {
        qualityChanged()
        fpsChanged()
        microphoneChanged()
        Settings.recordingSystemAudio = systemAudioButton.isOn
        Settings.recordingMicrophone = microphoneButton.isOn
        Settings.recordingShowsCursor = cursorButton.isOn
        closePanel()
        startHandler(captureRect, targetScreen, selectedWindow)
    }

    @objc private func cancelTapped() {
        closePanel()
    }
}

private struct RecordingMicrophoneOption {
    let id: String
    let name: String
}

private enum RecordingControlsError: Error {
    case cannotMonitorMicrophone
}

private enum RecordingMicrophoneDeviceProvider {
    static var options: [RecordingMicrophoneOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified)
            .devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map { RecordingMicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

@MainActor
private final class RecordingPanelContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class RecordingRoundedRectView: NSView {

    private let cornerRadius: CGFloat
    private let fillColor: NSColor
    private let strokeColor: NSColor

    init(frame: NSRect, cornerRadius: CGFloat, fillColor: NSColor, strokeColor: NSColor) {
        self.cornerRadius = cornerRadius
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.allowsEdgeAntialiasing = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    func setRoundedShadow(opacity: Float, radius: CGFloat, offset: CGSize) {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowRadius = radius
        layer?.shadowOffset = offset
        updateShadowPath()
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixel = 1 / scale
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        let radius = max(0, cornerRadius - pixel / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        fillColor.setFill()
        path.fill()

        strokeColor.setStroke()
        path.lineWidth = pixel
        path.stroke()
    }

    private func updateShadowPath() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixel = 1 / scale
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        let radius = max(0, cornerRadius - pixel / 2)
        layer?.shadowPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

@MainActor
private final class RecordingToggleButton: NSButton {

    var isOn: Bool = false {
        didSet { updateAppearance() }
    }

    private let symbol: String
    private let label: String
    private let activeTint: NSColor

    init(symbol: String, title: String, activeTint: NSColor = .controlAccentColor) {
        self.symbol = symbol
        self.label = title
        self.activeTint = activeTint
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.title = ""
        toolTip = label
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let action, let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = isOn
            ? activeTint.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(0.07).cgColor
        contentTintColor = isOn ? activeTint : NSColor.white.withAlphaComponent(0.48)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }
}

@MainActor
private final class RecordingActionButton: NSButton {

    private let symbol: String
    private let buttonTint: NSColor

    init(symbol: String, title: String, tint: NSColor = .systemRed) {
        self.symbol = symbol
        self.buttonTint = tint
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.title = ""
        toolTip = title
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        contentTintColor = buttonTint
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = buttonTint.withAlphaComponent(0.16).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }
}

@MainActor
private final class RecordingAudioLevelMeter: NSView {

    private let bars: [NSView]
    private var smoothedLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in NSView(frame: .zero) }
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.cornerCurve = .continuous
            addSubview(bar)
        }
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.62 + clamped * 0.38
        let gap: CGFloat = 3
        let barWidth: CGFloat = 3
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.17
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.65))
            let height = baseHeight + response * (bounds.height - baseHeight)
            let x = CGFloat(index) * (barWidth + gap)
            bar.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.18).cgColor
        }
    }
}

private final class MicrophoneLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let levelHandler: @MainActor (CGFloat) -> Void

    init(levelHandler: @escaping @MainActor (CGFloat) -> Void) {
        self.levelHandler = levelHandler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let level = Self.level(from: sampleBuffer)
        Task { @MainActor [levelHandler] in
            levelHandler(level)
        }
    }

    private static func level(from sampleBuffer: CMSampleBuffer) -> CGFloat {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData,
              bufferList.mBuffers.mDataByteSize > 0 else {
            return 0
        }

        let sampleCount: Int
        let sumSquares: Double
        if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let value = Double(sample)
                return partial + value * value
            }
        } else if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 64 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Double>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: sampleCount)
            sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        } else if streamDescription.mBitsPerChannel == 16 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + normalized * normalized
            }
        } else if streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int32.max)
                return partial + normalized * normalized
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(max(rms, 0.000_001))
        return CGFloat(max(0, min(1, (decibels + 55) / 45)))
    }
}
