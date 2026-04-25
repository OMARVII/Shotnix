import AppKit
import ScreenCaptureKit
import AudioToolbox

/// Central coordinator for all capture modes.
@MainActor
final class CaptureEngine {

    // Remembers the last selected area for "Capture Previous Area"
    private(set) var lastCaptureRect: CGRect?
    private var areaSelectionWindow: AreaSelectionWindow?
    private var scrollingCapture: ScrollingCaptureController?

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
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.lastCaptureRect = rect
            Task { await self.captureRect(rect, on: screen, historyManager: historyManager) }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: – Window Capture

    func startWindowCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        areaSelectionWindow = AreaSelectionWindow(mode: .window) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            Task { await self.captureRect(rect, on: screen, historyManager: historyManager) }
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
        // Capture the main (key) screen
        let screen = NSScreen.main ?? screens[0]
        let rect = screen.frame
        await captureRect(rect, on: screen, historyManager: historyManager)
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
        await captureRect(rect, on: screen, historyManager: historyManager)
    }

    // MARK: – Scrolling Capture

    func startScrollingCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        scrollingCapture = ScrollingCaptureController()
        await scrollingCapture?.start(historyManager: historyManager)
    }

    // MARK: – OCR Capture

    func startOCRCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            Task {
                guard let image = await self.captureRectToImage(rect, on: screen) else { return }
                let text = await OCREngine.recognizeText(in: image)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.showOCRNotification(text: text)
                }
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
