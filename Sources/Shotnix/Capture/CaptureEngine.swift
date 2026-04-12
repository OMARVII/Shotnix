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
        areaSelectionWindow?.show()
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
        areaSelectionWindow?.show()
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
        areaSelectionWindow?.show()
    }

    // MARK: – Core capture

    func captureRect(_ rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        guard let image = await captureRectToImage(rect, on: screen) else { return }
        playCaptureSound()
        showCaptureFlash(on: screen)
        let item = historyManager.add(image: image, rect: rect)
        QuickAccessOverlay.show(image: image, historyItem: item, historyManager: historyManager)
    }

    private func playCaptureSound() {
        guard Settings.playSounds else { return }
        AudioServicesPlaySystemSound(1108)
    }

    private func showCaptureFlash(on screen: NSScreen) {
        let flash = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        flash.isOpaque = false
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.3)
        flash.level = .floating
        flash.ignoresMouseEvents = true
        flash.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            flash.animator().alphaValue = 0
        }, completionHandler: {
            flash.orderOut(nil)
        })
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
            // Convert from AppKit (bottom-left origin) to ScreenCaptureKit (top-left origin)
            let screenHeight = screen.frame.height
            let sckRect = CGRect(
                x: rect.origin.x - screen.frame.origin.x,
                y: screenHeight - rect.origin.y - rect.height + screen.frame.origin.y,
                width: rect.width,
                height: rect.height
            )
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
                return fallbackCapture(rect: rect)
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.sourceRect = sckRect
            config.width = Int(ceil(rect.width * scale))
            config.height = Int(ceil(rect.height * scale))
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Self.nsImage(from: cgImage, logicalSize: rect.size)
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
    static func nsImage(from cgImage: CGImage, logicalSize: NSSize) -> NSImage {
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
