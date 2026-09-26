import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore
import ScreenCaptureKit
import AudioToolbox
import os.log

private enum CapturePerformance {
    private static let log = OSLog(subsystem: "com.shotnix.app", category: "CapturePerformance")

    static func mark(_ label: String, since start: CFAbsoluteTime) {
        let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_log("%{public}@ took %.1f ms", log: log, type: .debug, label, elapsedMS)
    }
}

extension Notification.Name {
    /// Posted once, when the very first capture completes onboarding.
    static let shotnixDidFinishFirstCapture = Notification.Name("shotnixDidFinishFirstCapture")
}

/// The screen the mouse is currently on — choosers and pickers should appear
/// where the user is working, not on whichever display is "main".
@MainActor
private func screenUnderMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens.first
}

/// Central coordinator for all capture modes.
@MainActor
final class CaptureEngine {

    // Remembers the last selected area for "Capture Previous Area"
    private(set) var lastCaptureRect: CGRect?
    private var areaSelectionWindow: AreaSelectionWindow?
    private var countdownWindow: CountdownWindow?
    private var scrollingCapture: ScrollingCaptureController?
    private var recordingControlsWindow: RecordingControlsWindow?
    private var recordingScreenChooserWindow: RecordingScreenChooserWindow?
    private var recordingWindowChooserWindow: RecordingWindowChooserWindow?
    private var recordingCountdownWindow: CountdownWindow?
    private var recordingSelectionActive = false
    private let recordingEngine = RecordingEngine()

    var recordingActive: Bool { recordingEngine.active }
    var recordingIsSaving: Bool { recordingEngine.isSaving }
    var recordingIsPaused: Bool { recordingEngine.isPaused }
    var recordingStopEnabled: Bool { recordingEngine.elapsedSeconds != nil || recordingSetupActive }
    var recordingStopTitle: String { recordingEngine.elapsedSeconds != nil ? "Stop Recording" : "Cancel Recording" }
    /// Setting up the next recording is fine while the last one saves.
    var recordingActionsEnabled: Bool { recordingEngine.elapsedSeconds == nil && !recordingSetupActive }
    var recordingElapsedSeconds: TimeInterval? { recordingEngine.elapsedSeconds }
    /// The finished file and the screen it was recorded on.
    var recordingFinishedHandler: ((URL, NSScreen?) -> Void)? {
        get { recordingEngine.recordingFinishedHandler }
        set { recordingEngine.recordingFinishedHandler = newValue }
    }
    /// Fired whenever recording starts or fully stops — drives the menu bar
    /// recording indicator.
    var recordingStateChangedHandler: (() -> Void)? {
        get { recordingEngine.stateChangedHandler }
        set { recordingEngine.stateChangedHandler = newValue }
    }

    private var recordingSetupActive: Bool {
        recordingSelectionActive || recordingControlsWindow != nil || recordingScreenChooserWindow != nil
            || recordingWindowChooserWindow != nil || recordingCountdownWindow != nil
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
    private static func invalidateCachedContent() {
        cachedContent = nil
        cachedContentIncludesWindows = false
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

    // MARK: – Timed Capture

    /// Area capture with a countdown: select the region first, then a
    /// cancellable on-screen countdown runs before the shot is taken —
    /// time to open menus, hover states, or tooltips.
    func startTimedCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil, countdownWindow == nil else { return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.lastCaptureRect = rect
            let countdown = CountdownWindow(seconds: Settings.timedCaptureDelaySeconds, on: screen) { [weak self] finished in
                guard let self else { return }
                self.countdownWindow = nil
                guard finished else { return }
                Task {
                    let hiddenByCapture = await self.hideDesktopIconsForCaptureIfNeeded()
                    await self.captureRect(rect, on: screen, historyManager: historyManager)
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                }
            }
            self.countdownWindow = countdown
            countdown.start()
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
            // Read before releasing the selection window — the clicked
            // window's ID enables the clean isolated-window capture path.
            let windowID = self.areaSelectionWindow?.selectedWindowID
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                await self.captureWindow(windowID: windowID, fallbackRect: rect, on: screen, historyManager: historyManager)
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    /// Captures the clicked window as an isolated image (no overlapping
    /// windows, no background) via SCK's desktop-independent window filter,
    /// optionally composited over a drawn shadow with transparent padding.
    /// Falls back to the display-region crop when the window can't be
    /// resolved or on macOS 13.
    private func captureWindow(windowID: CGWindowID?, fallbackRect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        if #available(macOS 14.0, *), let windowID,
           let image = await captureIsolatedWindowImage(windowID: windowID, expectedSize: fallbackRect.size) {
            finishCapture(image: image, rect: fallbackRect, historyManager: historyManager)
            return
        }
        await captureRect(fallbackRect, on: screen, historyManager: historyManager)
    }

    @available(macOS 14.0, *)
    private func captureIsolatedWindowImage(windowID: CGWindowID, expectedSize: CGSize) async -> NSImage? {
        do {
            // Try the cached shareable content first — a fresh fetch costs
            // 30-100ms on every window capture. The cached window list can be
            // stale, so refetch when the clicked window is missing or its
            // cached frame no longer matches the just-measured size
            // (expectedSize comes from a ≤150ms-old CGWindowList snapshot).
            func lookup(_ content: SCShareableContent) -> SCWindow? {
                content.windows.first { $0.windowID == windowID }
            }
            func sizeMatches(_ window: SCWindow) -> Bool {
                abs(window.frame.width - expectedSize.width) < 2
                    && abs(window.frame.height - expectedSize.height) < 2
            }
            var window = lookup(try await Self.shareableContent(includeWindows: true))
            if window.map(sizeMatches) != true {
                Self.invalidateCachedContent()
                window = lookup(try await Self.shareableContent(includeWindows: true))
            }
            guard let window else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(window.frame.width * scale))
            config.height = max(2, Int(window.frame.height * scale))
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let logicalSize = NSSize(width: window.frame.width, height: window.frame.height)
            guard Settings.windowCaptureShadow else {
                return Self.nsImage(from: cgImage, logicalSize: logicalSize)
            }
            return Self.compositeWindowShadow(around: cgImage, logicalSize: logicalSize, scale: scale)
        } catch {
            print("[Shotnix] Isolated window capture failed, falling back to region crop: \(error)")
            return nil
        }
    }

    /// Draws the window image onto a larger transparent canvas with a soft
    /// drop shadow — the polished window screenshot look. Output keeps
    /// the source pixel density; the alpha padding survives PNG export.
    nonisolated private static func compositeWindowShadow(around cgImage: CGImage, logicalSize: NSSize, scale: CGFloat) -> NSImage? {
        let padding: CGFloat = 32
        let paddingPx = Int(padding * scale)
        let width = cgImage.width + paddingPx * 2
        let height = cgImage.height + paddingPx * 2
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setShadow(
            offset: CGSize(width: 0, height: -8 * scale),
            blur: 20 * scale,
            color: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 0.38])
        )
        context.draw(cgImage, in: CGRect(x: paddingPx, y: paddingPx, width: cgImage.width, height: cgImage.height))

        guard let composited = context.makeImage() else { return nil }
        let paddedLogical = NSSize(width: logicalSize.width + padding * 2, height: logicalSize.height + padding * 2)
        return nsImage(from: composited, logicalSize: paddedLogical)
    }

    // MARK: – Fullscreen

    func captureFullscreen(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        // Instant, always — a hotkey capture must never open a modal chooser.
        // On multi-monitor setups the shot is the display the user is working
        // on (mouse location); All Displays lives as its own menu action.
        let screen = screenUnderMouse() ?? NSScreen.main ?? screens[0]
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        await captureRect(screen.frame, on: screen, historyManager: historyManager)
    }

    /// Captures every connected display, one image per screen, each through
    /// the normal post-capture pipeline — one shutter sound for the batch.
    func captureAllDisplays(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        for (index, screen) in NSScreen.screens.enumerated() {
            await captureRect(screen.frame, on: screen, historyManager: historyManager, playSound: index == 0)
        }
    }

    // MARK: – Screen Recording

    func startAreaRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }
        RecordingFocus.noteSetupStarted()

        recordingSelectionActive = true
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.recordingSelectionActive = false
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.lastCaptureRect = rect
            self.showRecordingControls(rect: rect, on: screen, target: .area)
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    func startWindowRecording() async {
        let started = CFAbsoluteTimeGetCurrent()
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }
        RecordingFocus.noteSetupStarted()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let choices = await recordingWindowChoices(from: content.windows)
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
            CapturePerformance.mark("Record Window picker", since: started)
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
        RecordingFocus.noteSetupStarted()
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
        guard recordingEngine.elapsedSeconds == nil else {
            ToastWindow.show(message: "Recording already in progress")
            return false
        }
        guard !recordingSetupActive, areaSelectionWindow == nil else {
            ToastWindow.show(message: "Finish or cancel the current recording setup")
            return false
        }
        return true
    }

    private func recordingWindowChoices(from windows: [SCWindow]) async -> [RecordingWindowChoice] {
        let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let candidates: [(window: SCWindow, appName: String, title: String, frame: CGRect, screen: NSScreen, previewRect: CGRect, appIcon: NSImage?)] = windows.compactMap { window in
            guard Self.isRecordableWindowCandidate(window) else { return nil }
            if window.owningApplication?.processID == currentProcessID { return nil }

            let appName = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? "App"
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || appName != "App" else { return nil }

            let screen = screen(containingWindowFrame: window.frame) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return nil }
            let previewRect = CGRect(
                x: screen.frame.midX - window.frame.width / 2,
                y: min(screen.visibleFrame.maxY - window.frame.height - 24, screen.visibleFrame.midY),
                width: window.frame.width,
                height: window.frame.height
            )
            let appIcon = window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
            return (window, appName, title, window.frame, screen, previewRect, appIcon)
        }
        .sorted {
            let lhs = "\($0.appName) \($0.title)".localizedLowercase
            let rhs = "\($1.appName) \($1.title)".localizedLowercase
            return lhs < rhs
        }

        // One SCK screenshot per window — serialized this dominated picker
        // latency (tens of ms × window count). The child tasks stay
        // @MainActor but suspend at the capture awaits, so they overlap.
        struct IndexedPreview: @unchecked Sendable {
            let index: Int
            let image: NSImage?
        }
        let previews: [NSImage?] = await withTaskGroup(of: IndexedPreview.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { @MainActor in
                    IndexedPreview(index: index, image: await self.windowPreviewImage(for: candidate.window))
                }
            }
            var images = [NSImage?](repeating: nil, count: candidates.count)
            for await preview in group {
                images[preview.index] = preview.image
            }
            return images
        }

        var choices: [RecordingWindowChoice] = []
        choices.reserveCapacity(candidates.count)
        for (candidate, previewImage) in zip(candidates, previews) {
            choices.append(
                RecordingWindowChoice(
                    window: candidate.window,
                    appName: candidate.appName,
                    title: candidate.title,
                    frame: candidate.frame,
                    screen: candidate.screen,
                    previewRect: candidate.previewRect,
                    previewImage: previewImage,
                    appIcon: candidate.appIcon
                )
            )
        }
        return choices
    }

    private func windowPreviewImage(for window: SCWindow) async -> NSImage? {
        if #available(macOS 14.0, *), let image = await screenCaptureKitWindowPreview(for: window) {
            return image
        }
        return fallbackWindowPreview(for: window)
    }

    @available(macOS 14.0, *)
    private func screenCaptureKitWindowPreview(for window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixelSize = Self.previewPixelSize(for: window.frame.size)
        let config = SCStreamConfiguration()
        config.width = pixelSize.width
        config.height = pixelSize.height
        config.scalesToFit = true
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Self.nsImage(from: cgImage, logicalSize: Self.previewLogicalSize(pixelSize: pixelSize))
        } catch {
            return nil
        }
    }

    private func fallbackWindowPreview(for window: SCWindow) -> NSImage? {
        let options: CGWindowImageOption = [.bestResolution, .boundsIgnoreFraming]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowID), options) else { return nil }
        return Self.nsImage(from: cgImage, logicalSize: window.frame.size)
    }

    nonisolated private static func previewPixelSize(for size: CGSize) -> (width: Int, height: Int) {
        let maxWidth: CGFloat = 420
        let maxHeight: CGFloat = 260
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return (
            width: max(2, evenCeil(Int(ceil(width * scale * 2)))),
            height: max(2, evenCeil(Int(ceil(height * scale * 2))))
        )
    }

    nonisolated private static func previewLogicalSize(pixelSize: (width: Int, height: Int)) -> CGSize {
        CGSize(width: CGFloat(pixelSize.width) / 2, height: CGFloat(pixelSize.height) / 2)
    }

    nonisolated private static func evenCeil(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    nonisolated private static func isRecordableWindowCandidate(_ window: SCWindow) -> Bool {
        guard window.frame.width >= 160, window.frame.height >= 120 else { return false }
        let aspectRatio = window.frame.width / max(window.frame.height, 1)
        guard aspectRatio <= 10 else { return false }

        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let searchText = "\(appName) \(title)".localizedLowercase
        let blockedFragments = ["backstop", "underbelly"]
        return !blockedFragments.contains { searchText.contains($0) }
    }

    /// The NSScreen showing the largest share of an SCWindow frame.
    /// SCWindow frames are CG-space — convert before comparing against
    /// NSScreen frames (AppKit-space).
    private func screen(containingWindowFrame windowFrame: CGRect) -> NSScreen? {
        let rect = ScreenCoordinates.appKitRect(fromCG: windowFrame)
        return NSScreen.screens
            .map { (screen: $0, overlap: $0.frame.intersection(rect)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .screen
    }

    private func showRecordingControls(rect: CGRect, on screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow? = nil) {
        let started = CFAbsoluteTimeGetCurrent()
        recordingControlsWindow?.closeControls()
        let window = RecordingControlsWindow(
            rect: rect,
            screen: screen,
            target: target,
            selectedWindow: selectedWindow,
            startHandler: { [weak self] rect, screen, selectedWindow in
                self?.beginRecording(rect: rect, on: screen, window: selectedWindow)
            },
            closeHandler: { [weak self] in
                self?.recordingControlsWindow = nil
            }
        )
        recordingControlsWindow = window
        window.show()
        CapturePerformance.mark("Recording controls", since: started)
    }

    /// Record was pressed: an optional countdown, then focus goes back to
    /// what's being recorded before the first frame.
    private func beginRecording(rect: CGRect, on screen: NSScreen, window: SCWindow?) {
        let start = { [weak self] in
            guard let self else { return }
            let owner = window?.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            RecordingFocus.returnFocus(to: owner)
            Task {
                if let window {
                    await self.recordingEngine.startRecording(window: window, on: screen)
                } else {
                    await self.recordingEngine.startRecording(rect: rect, on: screen)
                }
            }
        }
        let seconds = Settings.recordingCountdownSeconds
        guard seconds > 0 else { return start() }
        let countdown = CountdownWindow(seconds: seconds, on: screen) { [weak self] finished in
            guard let self else { return }
            self.recordingCountdownWindow = nil
            if finished {
                start()
            } else {
                // The bar left the camera preview on for the recording.
                CameraCapture.shared.stop()
            }
        }
        recordingCountdownWindow = countdown
        countdown.start()
    }

    func stopRecording() {
        if recordingEngine.elapsedSeconds != nil {
            recordingEngine.stopRecording()
            return
        }

        if recordingSetupActive {
            cancelRecordingSetup()
            ToastWindow.show(message: "Recording canceled")
            return
        }

        ToastWindow.show(message: recordingEngine.isSaving ? "Saving the recording…" : "No recording in progress")
    }

    func togglePauseRecording() {
        guard recordingEngine.elapsedSeconds != nil else {
            ToastWindow.show(message: "No recording in progress")
            return
        }
        recordingEngine.togglePause()
    }

    private func cancelRecordingSetup() {
        if recordingSelectionActive {
            recordingSelectionActive = false
            let selectionWindow = areaSelectionWindow
            areaSelectionWindow = nil
            selectionWindow?.cancel()
        }

        if let controlsWindow = recordingControlsWindow {
            recordingControlsWindow = nil
            controlsWindow.closeControls()
        }

        if let chooserWindow = recordingScreenChooserWindow {
            recordingScreenChooserWindow = nil
            chooserWindow.closeChooser()
        }

        if let chooserWindow = recordingWindowChooserWindow {
            recordingWindowChooserWindow = nil
            chooserWindow.closeChooser()
        }

        if let countdown = recordingCountdownWindow {
            recordingCountdownWindow = nil
            countdown.cancel()
        }
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
                    ToastWindow.show(message: "Capture failed", on: screen)
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                    return
                }
                do {
                    let text = try await OCREngine.recognizeText(in: image)
                    await MainActor.run {
                        // Only touch the pasteboard when there is actual text —
                        // never clobber the user's clipboard for an empty result.
                        if text.isEmpty {
                            ToastWindow.show(message: "No text found in this selection", on: screen)
                        } else {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            ToastWindow.show(message: "✓ Text copied to clipboard", on: screen)
                        }
                    }
                } catch {
                    print("[Shotnix] OCR failed: \(error)")
                    await MainActor.run {
                        ToastWindow.show(message: "Text recognition failed", on: screen)
                    }
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
                    ToastWindow.show(message: "Capture failed", on: screen)
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                    return
                }
                let results = await QRCodeEngine.detect(in: image)
                await MainActor.run {
                    if results.isEmpty {
                        ToastWindow.show(message: "No barcode found in this selection", on: screen)
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

    func captureRect(_ rect: CGRect, on screen: NSScreen, historyManager: HistoryManager, playSound: Bool = true) async {
        guard let image = await captureRectToImage(rect, on: screen) else {
            print("[Shotnix] Capture failed for rect \(rect)")
            ToastWindow.show(message: "Capture failed", on: screen)
            return
        }
        finishCapture(image: image, rect: rect, historyManager: historyManager, playSound: playSound)
    }

    /// Shared post-capture pipeline: sound, haptic, history, auto-actions,
    /// overlay — and the first successful capture completes onboarding.
    private func finishCapture(image: NSImage, rect: CGRect, historyManager: HistoryManager, playSound: Bool = true) {
        if playSound { playCaptureSound() }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = historyManager.add(image: image, rect: rect)
        StarNudge.captureDidFinish(rect: rect)

        // After-capture auto-actions (from Preferences). Both encode off the
        // main thread — a 5K PNG encode here used to stutter the overlay's
        // entrance animation.
        if Settings.afterCaptureCopyToClipboard {
            ImageExporter.copyToClipboardAsync(image: image)
        }
        if Settings.afterCaptureSaveAutomatically {
            let dir = Settings.autoSaveLocation
            let name = ImageExporter.timestampedName
            let ext = Settings.screenshotFormat
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            ImageExporter.saveAsync(image: image, to: url)
        }
        if Settings.afterCaptureShowOverlay {
            QuickAccessOverlay.show(image: image, historyItem: item, historyManager: historyManager)
        }

        if !Settings.onboardingCompleted {
            Settings.onboardingCompleted = true
            NotificationCenter.default.post(name: .shotnixDidFinishFirstCapture, object: nil)
        }
    }

    private func playCaptureSound() {
        guard Settings.playSounds else { return }
        if let soundID = Self.bundledCaptureSoundID {
            AudioServicesPlaySystemSound(soundID)
        } else {
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
    }

    /// Registered once and reused for the process lifetime.
    /// Uses ShotnixResources, NOT Bundle.module — the generated accessor
    /// fatalErrors in released .app bundles (issue #25).
    private static let bundledCaptureSoundID: SystemSoundID? = {
        guard let url = ShotnixResources.url(forResource: "capture", withExtension: "aiff") else {
            os_log("Bundled capture sound resource missing", type: .error)
            return nil
        }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            os_log("AudioServicesCreateSystemSoundID failed with status %d", type: .error, Int32(status))
            return nil
        }
        return soundID
    }()

    static func warmCaptureSound() {
        _ = bundledCaptureSoundID
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
            // captureRectSCK only needs the display and application lists —
            // no on-screen window enumeration.
            let content = try await Self.shareableContent(includeWindows: false)
            // SCDisplay frames are CG-space (top-left origin) while `rect` and
            // `screen` are AppKit-space (bottom-left origin) — the spaces only
            // agree on the primary display, so match by display ID. Geometric
            // intersection picks the wrong display (or none) for secondary
            // screens, and SCK renders an out-of-bounds sourceRect as black.
            guard let display = ScreenCoordinates.display(for: screen, in: content.displays) else {
                return fallbackCapture(rect: rect)
            }
            // Exclude Shotnix's floating chrome (selection overlays, toasts,
            // the quick-access thumbnail, pinned screenshots, countdowns,
            // recording HUDs) so it never bakes into captures — but the app's
            // REAL windows (video editor, annotation editor, history,
            // preferences) must stay capturable: users screenshot the editor
            // itself. Chrome is always borderless; content windows are titled
            // or normal-level, so except those back into the capture.
            let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
            let filter: SCContentFilter
            if let ownApp = content.applications.first(where: { $0.processID == currentProcessID }) {
                let contentWindowIDs = Set(NSApp.windows.compactMap { window -> CGWindowID? in
                    guard window.isVisible,
                          window.level == .normal || window.styleMask.contains(.titled) else { return nil }
                    return CGWindowID(window.windowNumber)
                })
                var exceptedWindows: [SCWindow] = []
                if !contentWindowIDs.isEmpty {
                    // The cached shareable content's window list can be stale
                    // (it only refreshes on display changes) — fetch fresh so
                    // a just-opened editor window is actually in the filter.
                    let windowContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    exceptedWindows = windowContent.windows.filter {
                        $0.owningApplication?.processID == currentProcessID && contentWindowIDs.contains($0.windowID)
                    }
                }
                filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: exceptedWindows)
            } else {
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == currentProcessID }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            }
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

            let logicalSize = NSSize(width: w, height: h)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if Self.isEffectivelyBlack(cgImage) {
                // Diagnostic breadcrumb: a black frame here either means the
                // content really is black or SCScreenshotManager glitched —
                // the stream retry rescues the latter at ~0.5-1.5s cost.
                os_log("Screenshot came back black for rect %{public}@ — retrying via SCStream", type: .info, NSStringFromRect(rect))
                if let streamImage = try? await captureRectStream(filter: filter, configuration: config) {
                    return Self.nsImage(from: streamImage, logicalSize: logicalSize)
                }
            }

            return Self.nsImage(from: cgImage, logicalSize: logicalSize)
        } catch {
            print("[Shotnix] ScreenCaptureKit capture failed, falling back to CGWindowListCreateImage: \(error)")
            return fallbackCapture(rect: rect)
        }
    }

    @available(macOS 14.0, *)
    private func captureRectStream(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await SingleFrameImageCapture().capture(filter: filter, configuration: configuration)
    }

    private func fallbackCapture(rect: CGRect) -> NSImage? {
        // CGWindowListCreateImage takes CG global coordinates (top-left
        // origin); `rect` arrives in AppKit global coordinates (bottom-left).
        let cgRect = ScreenCoordinates.cgRect(fromAppKit: rect)
        guard let cgImage = CGWindowListCreateImage(cgRect, .optionAll, kCGNullWindowID, .bestResolution) else {
            print("[Shotnix] CGWindowListCreateImage returned nil for rect \(rect)")
            return nil
        }
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

    nonisolated private static func isEffectivelyBlack(_ cgImage: CGImage) -> Bool {
        let width = min(max(cgImage.width, 1), 32)
        let height = min(max(cgImage.height, 1), 32)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            if max(red, green, blue) > 8 {
                return false
            }
        }
        return true
    }
}

@available(macOS 14.0, *)
private final class SingleFrameImageCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let sampleQueue = DispatchQueue(label: "com.shotnix.capture.single-frame", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?

    func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(filter: filter, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            self.cancelCapture()
        }
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration, continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        lock.lock()
        self.stream = stream
        lock.unlock()

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            finish(.failure(error))
            return
        }

        Task {
            do {
                try await stream.startCapture()
            } catch {
                finish(.failure(error))
            }
        }

        sampleQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish(.failure(SingleFrameImageCaptureError.timeout))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let cgImage = Self.ciContext.createCGImage(image, from: extent) else {
            return
        }
        finish(.success(cgImage))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        Task {
            if let stream {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .screen)
            }
            switch result {
            case .success(let image):
                continuation.resume(returning: image)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func cancelCapture() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        Task {
            if let stream {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .screen)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] else {
            return false
        }
        if let status = rawStatus as? SCFrameStatus { return status == .complete }
        if let raw = rawStatus as? Int { return SCFrameStatus(rawValue: raw) == .complete }
        if let raw = rawStatus as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) == .complete }
        return false
    }
}

private enum SingleFrameImageCaptureError: Error {
    case timeout
}

@MainActor
private struct RecordingWindowChoice {
    let window: SCWindow
    let appName: String
    let title: String
    let frame: CGRect
    let screen: NSScreen
    let previewRect: CGRect
    let previewImage: NSImage?
    let appIcon: NSImage?

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// Recordings are measured in pixels, so the chooser is too.
    var pixelSizeText: String {
        let scale = screen.backingScaleFactor
        return "\(Int((frame.width * scale).rounded())) × \(Int((frame.height * scale).rounded()))"
    }

    var subtitle: String {
        "\(appName) · \(pixelSizeText) px"
    }
}

@MainActor
enum RecordingTargetKind {
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
    private static let panelWidth: CGFloat = 724
    private static let panelHeight: CGFloat = 560
    private static let headerHeight: CGFloat = 84

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
        NSApp.ensureForegroundCapable()
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

        let title = label("Choose window", size: 16, weight: .bold, color: .white)
        title.frame = NSRect(x: 24, y: frame.height - 42, width: 220, height: 20)
        panel.addSubview(title)

        let subtitle = label("Select a window to record without blocking other apps", size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.48))
        subtitle.frame = NSRect(x: 24, y: frame.height - 63, width: 360, height: 14)
        panel.addSubview(subtitle)

        let closeButton = RecordingChooserCloseButton(frame: NSRect(x: frame.width - 44, y: frame.height - 44, width: 28, height: 28))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        panel.addSubview(closeButton)

        let scrollFrame = NSRect(x: 16, y: 16, width: frame.width - 48, height: frame.height - Self.headerHeight - 18)
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        panel.addSubview(scroll)

        let rowHeight: CGFloat = 150
        let documentHeight = max(scrollFrame.height, CGFloat(choices.count) * rowHeight)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: scrollFrame.width, height: documentHeight))
        scroll.documentView = document

        for (index, choice) in choices.enumerated() {
            let y = documentHeight - CGFloat(index + 1) * rowHeight
            let button = RecordingWindowChoiceButton(frame: NSRect(x: 0, y: y + 6, width: scrollFrame.width - 8, height: rowHeight - 12), choice: choice)
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
        guard let visible = screenUnderMouse()?.visibleFrame else { return }
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

    func closeChooser() {
        closeChooser(notify: true)
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
    private let idleBackground = NSColor.white.withAlphaComponent(0.074)
    private let pressedBackground = NSColor.white.withAlphaComponent(0.125)

    init(frame: NSRect, choice: RecordingWindowChoice) {
        self.choice = choice
        super.init(frame: frame)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = idleBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.105).cgColor

        let previewFrame = NSRect(x: 12, y: 12, width: 180, height: frame.height - 24)
        let preview = RecordingWindowPreviewView(frame: previewFrame, image: choice.previewImage, appIcon: choice.appIcon)
        addSubview(preview)

        let icon = NSImageView(frame: NSRect(x: 214, y: frame.height - 44, width: 22, height: 22))
        icon.image = choice.appIcon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.84)
        addSubview(icon)

        let titleField = NSTextField(labelWithString: choice.displayTitle)
        titleField.font = .systemFont(ofSize: 14, weight: .bold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: 244, y: frame.height - 43, width: frame.width - 390, height: 18)
        addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: choice.subtitle)
        subtitleField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.46)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.frame = NSRect(x: 244, y: frame.height - 62, width: frame.width - 390, height: 13)
        addSubview(subtitleField)

        let description = NSTextField(labelWithString: "Preview the target, then continue to recording controls.")
        description.font = .systemFont(ofSize: 11, weight: .medium)
        description.textColor = NSColor.white.withAlphaComponent(0.42)
        description.lineBreakMode = .byTruncatingTail
        description.frame = NSRect(x: 214, y: 48, width: frame.width - 358, height: 15)
        addSubview(description)

        let sizePill = RecordingWindowPillLabel(text: choice.pixelSizeText)
        sizePill.frame = NSRect(x: 214, y: 18, width: 92, height: 24)
        addSubview(sizePill)

        let selectPill = RecordingWindowSelectPill(frame: NSRect(x: frame.width - 120, y: 52, width: 82, height: 32))
        addSubview(selectPill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedBackground.cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = idleBackground.cgColor
    }
}

@MainActor
private final class RecordingWindowPreviewView: NSView {

    private let image: NSImage?
    private let appIcon: NSImage?

    init(frame: NSRect, image: NSImage?, appIcon: NSImage?) {
        self.image = image
        self.appIcon = appIcon
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.02, alpha: 0.98).setFill()
        backgroundPath.fill()

        let inner = bounds.insetBy(dx: 8, dy: 8)
        let imageRect = image.map { Self.aspectFitRect(imageSize: $0.size, in: inner) }
        if let image, let imageRect {
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            drawPlaceholder(in: inner)
        }

        if let appIcon {
            let iconRect = NSRect(x: bounds.minX + 12, y: bounds.minY + 12, width: 30, height: 30)
            NSColor.black.withAlphaComponent(0.34).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10).fill()
            appIcon.draw(in: iconRect)
        }

        NSColor.white.withAlphaComponent(0.12).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()
    }

    private func drawPlaceholder(in rect: NSRect) {
        let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold))?.draw(
            in: NSRect(x: rect.midX - 18, y: rect.midY - 18, width: 36, height: 36),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.54
        )
    }

    private static func aspectFitRect(imageSize: CGSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

@MainActor
private final class RecordingWindowSelectPill: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.systemRed.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.systemRed.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = "Select" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.96)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(x: bounds.midX - textSize.width / 2 - 5, y: bounds.midY - textSize.height / 2, width: textSize.width, height: textSize.height)
        text.draw(in: textRect, withAttributes: attributes)

        let chevron = NSBezierPath()
        let x = textRect.maxX + 8
        let y = bounds.midY
        chevron.move(to: NSPoint(x: x - 2, y: y + 4))
        chevron.line(to: NSPoint(x: x + 2, y: y))
        chevron.line(to: NSPoint(x: x - 2, y: y - 4))
        NSColor.systemRed.withAlphaComponent(0.86).setStroke()
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
}

@MainActor
private final class RecordingWindowPillLabel: NSView {

    private let textField: NSTextField

    init(text: String) {
        textField = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        textField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        textField.textColor = NSColor.white.withAlphaComponent(0.62)
        textField.alignment = .center
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        textField.frame = bounds.insetBy(dx: 8, dy: 5)
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
    private let subtitleText: String
    private let actionTitle: String
    private let selectHandler: (NSScreen) -> Void
    private let allDisplaysHandler: (() -> Void)?
    private let closeHandler: () -> Void
    private var keyMonitor: Any?
    private var didClose = false

    init(
        screens: [NSScreen],
        subtitle: String = "Select which display to record fullscreen",
        actionTitle: String = "Record",
        selectHandler: @escaping (NSScreen) -> Void,
        allDisplaysHandler: (() -> Void)? = nil,
        closeHandler: @escaping () -> Void
    ) {
        self.screens = screens
        self.subtitleText = subtitle
        self.actionTitle = actionTitle
        self.selectHandler = selectHandler
        self.allDisplaysHandler = allDisplaysHandler
        self.closeHandler = closeHandler

        // The optional "All Displays" row sits below the per-screen rows.
        let rowCount = screens.count + (allDisplaysHandler == nil ? 0 : 1)
        let height = Self.headerHeight + CGFloat(rowCount) * Self.rowStride + Self.bottomPadding
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
        NSApp.ensureForegroundCapable()
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

        let subtitle = label(subtitleText, size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.48))
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
                subtitle: screenSubtitle(for: screen),
                actionTitle: actionTitle
            )
            button.tag = index
            button.target = self
            button.action = #selector(screenChosen(_:))
            panel.addSubview(button)
        }

        if allDisplaysHandler != nil {
            let y = frame.height - Self.headerHeight - Self.rowHeight - CGFloat(screens.count) * Self.rowStride
            let button = RecordingScreenChoiceButton(
                frame: NSRect(x: 14, y: y, width: frame.width - 28, height: Self.rowHeight),
                title: "All Displays",
                subtitle: "\(screens.count) screens",
                symbol: "display.2",
                actionTitle: actionTitle
            )
            button.target = self
            button.action = #selector(allDisplaysChosen)
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
        let scale = screen.backingScaleFactor
        return "\(Int(screen.frame.width * scale)) × \(Int(screen.frame.height * scale)) px"
    }

    private func positionChooser() {
        let screen = screenUnderMouse() ?? screens.first
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

    @objc private func allDisplaysChosen() {
        guard let allDisplaysHandler else { return }
        closeChooser(notify: false)
        allDisplaysHandler()
    }

    @objc private func closeTapped() {
        closeChooser()
    }
}

@MainActor
private final class RecordingScreenChoiceButton: NSButton {

    init(frame: NSRect, title: String, subtitle: String, symbol: String = "display", actionTitle: String = "Record") {
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
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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

        let actionField = NSTextField(labelWithString: actionTitle)
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
final class RecordingControlsWindow: NSWindow {

    private static var openWindows: [RecordingControlsWindow] = []
    private static let barHeight: CGFloat = 56
    private static let expandedHeight: CGFloat = 92
    private static let panelWidth: CGFloat = 808
    private static let chromeInset: CGFloat = 8
    /// startRunning/stopRunning block for a noticeable moment: never on main.
    private static let microphoneMonitorQueue = DispatchQueue(label: "com.shotnix.recording.mic-meter-session", qos: .userInitiated)

    private let captureRect: CGRect
    private let targetScreen: NSScreen
    private let target: RecordingTargetKind
    private let selectedWindow: SCWindow?
    private let startHandler: (CGRect, NSScreen, SCWindow?) -> Void
    private let closeHandler: () -> Void

    private var keyMonitor: Any?
    private var didClose = false
    /// Record was pressed: the camera stays on for the recording.
    private var keepsCameraAfterClose = false
    /// Waits for Accessibility access after the ⌘ button asked for it.
    private var accessibilityPoll: Timer?
    private var accessibilityPollTicks = 0

    private let systemAudioButton = RecordingToggleButton(symbol: "speaker.wave.2.fill", title: "System audio")
    private let microphoneButton = RecordingToggleButton(symbol: "mic.fill", title: "Microphone", activeTint: .systemGreen)
    private let cursorButton = RecordingToggleButton(symbol: "cursorarrow.rays", title: "Cursor")
    private let cameraButton = RecordingToggleButton(symbol: "video.fill", title: "Camera", activeTint: .systemBlue)
    private let keysButton = RecordingToggleButton(symbol: "command", title: "Show keyboard shortcuts")
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let optionsButton = RecordingActionButton(symbol: "ellipsis.circle", title: "More recording options", tint: NSColor.white.withAlphaComponent(0.72))
    private let recordButton = RecordingActionButton(symbol: "record.circle", title: "Record")
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneContainer = NSView()
    private let microphoneLevelMeter = RecordingAudioLevelMeter()
    private var microphoneMonitorSession: AVCaptureSession?
    private var microphoneMonitorOutput: AVCaptureAudioDataOutput?
    private var microphoneMonitorDelegate: MicrophoneLevelMonitor?
    private var microphoneMonitorStartupTask: Task<Void, Never>?
    private var hasMicrophone = true

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
        NSApp.ensureForegroundCapable()
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

        scheduleDeferredMicrophoneMonitor()
        if Settings.recordingCamera { startCameraPreview() }
        // Asked for shortcuts earlier but access hasn't arrived yet.
        if Settings.recordingKeystrokes, !VideoKeystrokeFormatter.isAllowed { waitForAccessibility() }
    }

    private func startCameraPreview() {
        CameraCapture.shared.interruptionHandler = { [weak self] _ in self?.cameraDropped() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await CameraCapture.shared.start(deviceID: Settings.recordingCameraDeviceID, around: self.captureRect, on: self.targetScreen)
            guard !self.didClose || result == .started else { return }
            if let message = result.message {
                Settings.recordingCamera = false
                self.cameraButton.isOn = false
                // Denied and "no camera" need different fixes.
                ToastWindow.show(message: message, duration: 3.5, on: self.targetScreen)
            } else if self.didClose, !self.keepsCameraAfterClose {
                CameraCapture.shared.stop()
            }
        }
    }

    private func cameraDropped() {
        guard !didClose, cameraButton.isOn else { return }
        CameraCapture.shared.stop()
        Settings.recordingCamera = false
        cameraButton.isOn = false
        ToastWindow.show(message: "Camera disconnected.", on: targetScreen)
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
        microphonePopup.setAccessibilityLabel("Microphone")
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

        // Recordings are measured in pixels, so the size shown is too.
        let pixels = outputPixelSize
        let sourcePill = pillLabel("\(target.title) · \(pixels.width) × \(pixels.height)", symbol: target.symbol)
        sourcePill.frame = NSRect(x: 32, y: 9, width: 190, height: 38)
        sourcePill.toolTip = "Records \(pixels.width) × \(pixels.height) pixels (\(Int(captureRect.width)) × \(Int(captureRect.height)) points)"
        bar.addSubview(sourcePill)

        let audioGroup = segmentContainer(frame: NSRect(x: 234, y: 8, width: 268, height: 40))
        bar.addSubview(audioGroup)
        bar.addSubview(divider(x: 280, height: 22))
        bar.addSubview(divider(x: 326, height: 22))
        bar.addSubview(divider(x: 362, height: 22))
        bar.addSubview(divider(x: 408, height: 22))
        bar.addSubview(divider(x: 454, height: 22))

        systemAudioButton.frame = NSRect(x: 238, y: 9, width: 40, height: 38)
        microphoneButton.frame = NSRect(x: 284, y: 9, width: 40, height: 38)
        microphoneLevelMeter.frame = NSRect(x: 332, y: 16, width: 32, height: 24)
        microphoneLevelMeter.isHidden = true
        bar.addSubview(microphoneLevelMeter)
        cursorButton.frame = NSRect(x: 366, y: 9, width: 40, height: 38)
        cameraButton.frame = NSRect(x: 412, y: 9, width: 40, height: 38)
        keysButton.frame = NSRect(x: 458, y: 9, width: 40, height: 38)
        for button in [systemAudioButton, microphoneButton, cursorButton, cameraButton, keysButton] {
            button.target = self
            button.action = #selector(toggleChanged(_:))
            bar.addSubview(button)
        }

        let settingsGroup = segmentContainer(frame: NSRect(x: 510, y: 8, width: 166, height: 40))
        bar.addSubview(settingsGroup)
        bar.addSubview(divider(x: 594, height: 22))

        configurePopup(qualityPopup, items: [("Balanced", "balanced"), ("High", "high"), ("Max", "max")])
        qualityPopup.frame = NSRect(x: 516, y: 18, width: 72, height: 28)
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)
        qualityPopup.setAccessibilityLabel("Quality")
        bar.addSubview(qualityPopup)

        configurePopup(fpsPopup, items: [("30 fps", "30"), ("60 fps", "60")])
        fpsPopup.frame = NSRect(x: 602, y: 18, width: 68, height: 28)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        fpsPopup.setAccessibilityLabel("Frame rate")
        bar.addSubview(fpsPopup)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        sizeLabel.alignment = .center
        sizeLabel.frame = NSRect(x: 514, y: 11, width: 158, height: 11)
        sizeLabel.toolTip = "Estimated file size. Still screens take less."
        bar.addSubview(sizeLabel)

        optionsButton.frame = NSRect(x: 684, y: 9, width: 36, height: 38)
        optionsButton.target = self
        optionsButton.action = #selector(optionsTapped)
        bar.addSubview(optionsButton)

        recordButton.frame = NSRect(x: 728, y: 9, width: 38, height: 38)
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        // Return records, as the default button of the bar.
        recordButton.keyEquivalent = "\r"
        recordButton.toolTip = "Record (Return)"
        bar.addSubview(recordButton)

        let cancelButton = RecordingActionButton(symbol: "xmark", title: "Cancel", tint: .secondaryLabelColor)
        cancelButton.frame = NSRect(x: 768, y: 9, width: 32, height: 38)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        bar.addSubview(cancelButton)

        let escHint = keyHint("esc")
        escHint.frame = NSRect(x: 772, y: 3, width: 24, height: 12)
        bar.addSubview(escHint)

        syncFromSettings()
    }

    /// The file's pixel size — scaled down only where no encoder takes the
    /// full size.
    private var outputPixelSize: (width: Int, height: Int) {
        let geometry = RecordingEngine.captureGeometry(rect: captureRect, screenFrame: targetScreen.frame, scale: max(targetScreen.backingScaleFactor, 1))
        let format = RecordingVideoFormat.plan(width: geometry.pixelWidth, height: geometry.pixelHeight, fps: Settings.recordingFPS)
        return (format.width, format.height)
    }

    private func updateSizeEstimate() {
        let geometry = RecordingEngine.captureGeometry(rect: captureRect, screenFrame: targetScreen.frame, scale: max(targetScreen.backingScaleFactor, 1))
        let bytes = RecordingSizeEstimate.bytesPerMinute(
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            fps: Settings.recordingFPS,
            quality: RecordingQuality(rawValue: Settings.recordingQuality) ?? .high,
            systemAudio: Settings.recordingSystemAudio,
            microphone: Settings.recordingMicrophone && hasMicrophone
        )
        sizeLabel.stringValue = RecordingSizeEstimate.label(bytesPerMinute: bytes)
        sizeLabel.setAccessibilityLabel("Estimated size \(sizeLabel.stringValue)")
    }

    private func syncFromSettings() {
        systemAudioButton.isOn = Settings.recordingSystemAudio
        microphoneButton.isOn = Settings.recordingMicrophone
        cursorButton.isOn = Settings.recordingShowsCursor
        cameraButton.isOn = Settings.recordingCamera
        keysButton.isOn = Settings.recordingKeystrokes && VideoKeystrokeFormatter.isAllowed
        selectItem(in: qualityPopup, representedObject: Settings.recordingQuality)
        selectItem(in: fpsPopup, representedObject: String(Settings.recordingFPS))
        reloadMicrophones()
        updateMicrophoneVisibility(startMonitor: false)
        updateSizeEstimate()
    }

    private func reloadMicrophones() {
        microphonePopup.removeAllItems()
        let options = RecordingMicrophoneDeviceProvider.options
        hasMicrophone = !options.isEmpty
        guard hasMicrophone else {
            // Recording still works; it just won't have a mic track.
            microphonePopup.addItem(withTitle: "No microphone connected")
            microphonePopup.isEnabled = false
            return
        }
        microphonePopup.isEnabled = true
        microphonePopup.addItem(withTitle: "System Default")
        microphonePopup.lastItem?.representedObject = ""
        for device in options {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if !selectItem(in: microphonePopup, representedObject: Settings.recordingMicrophoneDeviceID) {
            microphonePopup.selectItem(at: 0)
            Settings.recordingMicrophoneDeviceID = ""
        }
    }

    private func updateMicrophoneVisibility(startMonitor: Bool = true) {
        microphoneContainer.isHidden = !Settings.recordingMicrophone
        microphoneLevelMeter.isHidden = !Settings.recordingMicrophone || !hasMicrophone
        if Settings.recordingMicrophone {
            if startMonitor {
                startMicrophoneMonitorIfNeeded()
            }
        } else {
            microphoneMonitorStartupTask?.cancel()
            microphoneMonitorStartupTask = nil
            stopMicrophoneMonitor()
            microphoneLevelMeter.setLevel(0)
        }
        resizeForMicrophoneState()
    }

    private func scheduleDeferredMicrophoneMonitor() {
        guard Settings.recordingMicrophone else { return }
        microphoneMonitorStartupTask?.cancel()
        microphoneMonitorStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled, !self.didClose, Settings.recordingMicrophone else { return }
            self.startMicrophoneMonitorIfNeeded()
        }
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
            ToastWindow.show(message: "Microphone access is off. Allow Shotnix in System Settings → Privacy & Security → Microphone.", duration: 3.5, on: targetScreen)
        @unknown default:
            break
        }
    }

    private func configureMicrophoneMonitor() {
        guard microphoneMonitorSession == nil else { return }
        guard let device = RecordingMicrophoneDeviceProvider.device(for: Settings.recordingMicrophoneDeviceID) else {
            // Nothing to listen to: no meter rather than one that never moves.
            microphoneLevelMeter.isHidden = true
            return
        }
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
            nonisolated(unsafe) let running = session
            Self.microphoneMonitorQueue.async { running.startRunning() }

            microphoneMonitorSession = session
            microphoneMonitorOutput = output
            microphoneMonitorDelegate = delegate
        } catch {
            microphoneLevelMeter.setLevel(0)
            print("[Shotnix] Microphone meter failed: \(error)")
        }
    }

    private func stopMicrophoneMonitor() {
        if let session = microphoneMonitorSession {
            nonisolated(unsafe) let stopping = session
            Self.microphoneMonitorQueue.async { stopping.stopRunning() }
        }
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
        microphoneMonitorStartupTask?.cancel()
        microphoneMonitorStartupTask = nil
        stopMicrophoneMonitor()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        stopWaitingForAccessibility()
        CameraCapture.shared.interruptionHandler = nil
        if !keepsCameraAfterClose { CameraCapture.shared.stop() }
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
        case cameraButton:
            Settings.recordingCamera = sender.isOn
            if sender.isOn {
                startCameraPreview()
            } else {
                CameraCapture.shared.stop()
            }
        case keysButton:
            if sender.isOn, !VideoKeystrokeFormatter.isAllowed {
                // macOS asks once; the button switches on by itself the
                // moment access is granted.
                VideoKeystrokeFormatter.requestAccess()
                sender.isOn = false
                Settings.recordingKeystrokes = true
                waitForAccessibility()
                ToastWindow.show(message: "Allow Shotnix in Accessibility — shortcuts turn on by themselves.", duration: 3.2)
            } else {
                Settings.recordingKeystrokes = sender.isOn
                if !sender.isOn { stopWaitingForAccessibility() }
            }
        default:
            break
        }
        updateSizeEstimate()
    }

    private func waitForAccessibility() {
        stopWaitingForAccessibility()
        accessibilityPollTicks = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoll = timer
    }

    private func checkAccessibility() {
        accessibilityPollTicks += 1
        guard !didClose, accessibilityPollTicks <= 600 else {
            stopWaitingForAccessibility()
            return
        }
        guard VideoKeystrokeFormatter.isAllowed else { return }
        stopWaitingForAccessibility()
        guard Settings.recordingKeystrokes else { return }
        keysButton.isOn = true
        ToastWindow.show(message: "Keyboard shortcuts are on")
    }

    private func stopWaitingForAccessibility() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
    }

    @objc private func qualityChanged() {
        if let value = qualityPopup.selectedItem?.representedObject as? String {
            Settings.recordingQuality = value
        }
        updateSizeEstimate()
    }

    @objc private func fpsChanged() {
        if let value = fpsPopup.selectedItem?.representedObject as? String, let fps = Int(value) {
            Settings.recordingFPS = fps
        }
        updateSizeEstimate()
    }

    @objc private func microphoneChanged() {
        guard hasMicrophone else { return }
        Settings.recordingMicrophoneDeviceID = microphonePopup.selectedItem?.representedObject as? String ?? ""
        if Settings.recordingMicrophone {
            stopMicrophoneMonitor()
            startMicrophoneMonitorIfNeeded()
        }
    }

    /// The settings that don't earn a button in the bar.
    @objc private func optionsTapped() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let cameraHeader = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraHeader.isEnabled = false
        menu.addItem(cameraHeader)
        let cameras = CameraCapture.devices
        if cameras.isEmpty {
            let none = NSMenuItem(title: "No camera connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        } else {
            for (title, id) in [("System Default", "")] + cameras.map({ ($0.localizedName, $0.uniqueID) }) {
                let item = NSMenuItem(title: title, action: #selector(cameraDeviceChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = Settings.recordingCameraDeviceID == id ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let editable = NSMenuItem(title: "Editable Cursor", action: #selector(editableCursorToggled), keyEquivalent: "")
        editable.target = self
        editable.state = Settings.recordingEditableCursor ? .on : .off
        editable.isEnabled = cursorButton.isOn
        editable.toolTip = "Records the pointer separately, so the editor can smooth it, resize it, and keep it crisp when zoomed."
        menu.addItem(editable)
        let openEditor = NSMenuItem(title: "Open Editor After Recording", action: #selector(openEditorToggled), keyEquivalent: "")
        openEditor.target = self
        openEditor.state = Settings.openVideoEditorAfterRecording ? .on : .off
        menu.addItem(openEditor)

        menu.addItem(.separator())
        let countdown = NSMenuItem(title: "Countdown", action: nil, keyEquivalent: "")
        let countdownMenu = NSMenu()
        for seconds in Settings.recordingCountdownChoices {
            let item = NSMenuItem(title: seconds == 0 ? "Off" : "\(seconds) seconds", action: #selector(countdownChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = Settings.recordingCountdownSeconds == seconds ? .on : .off
            countdownMenu.addItem(item)
        }
        countdown.submenu = countdownMenu
        menu.addItem(countdown)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: optionsButton)
    }

    @objc private func cameraDeviceChosen(_ sender: NSMenuItem) {
        Settings.recordingCameraDeviceID = sender.representedObject as? String ?? ""
        guard cameraButton.isOn else { return }
        CameraCapture.shared.stop()
        startCameraPreview()
    }

    @objc private func editableCursorToggled() {
        Settings.recordingEditableCursor.toggle()
    }

    @objc private func openEditorToggled() {
        Settings.openVideoEditorAfterRecording.toggle()
    }

    @objc private func countdownChosen(_ sender: NSMenuItem) {
        Settings.recordingCountdownSeconds = sender.tag
    }

    @objc private func recordTapped() {
        // Every setting was saved when it changed. Pressing Record stores
        // nothing: saving what the menus merely showed is what kept most
        // people on the old 30 fps default.
        keepsCameraAfterClose = cameraButton.isOn
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
    private static var cachedOptions: [RecordingMicrophoneOption]?
    private static var cachedAt: CFAbsoluteTime = 0

    static var options: [RecordingMicrophoneOption] {
        let now = CFAbsoluteTimeGetCurrent()
        if let cachedOptions, now - cachedAt < 5 {
            return cachedOptions
        }

        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        let options = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified)
            .devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map { RecordingMicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
        cachedOptions = options
        cachedAt = now
        return options
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
        didSet {
            updateAppearance()
            if isOn != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
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
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
    }

    // Every way of pressing the button — click, Space with keyboard focus,
    // VoiceOver — goes through here, so every way toggles it.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        isOn.toggle()
        return super.sendAction(action, to: target)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
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
