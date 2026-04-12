import AppKit
import ScreenCaptureKit

/// Scrolling capture: user selects a region, then scrolls. Shotnix stitches frames.
@MainActor
final class ScrollingCaptureController: NSObject {

    private var selectionWindow: AreaSelectionWindow?
    private var captureRect: CGRect?
    private var captureScreen: NSScreen?
    private var frames: [NSImage] = []
    private var isCapturing = false
    private var captureTimer: Timer?
    private var statusWindow: ScrollingStatusWindow?
    /// Single reusable capture engine — never allocate per-frame
    private let captureEngine = CaptureEngine()

    func start(historyManager: HistoryManager) async {
        selectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self, let rect else { return }
            self.captureRect = rect
            self.captureScreen = screen
            self.beginScrollingPhase(historyManager: historyManager)
        }
        selectionWindow?.show()
    }

    private func beginScrollingPhase(historyManager: HistoryManager) {
        guard let rect = captureRect else { return }
        frames = []
        isCapturing = true

        statusWindow = ScrollingStatusWindow()
        statusWindow?.show(near: CGPoint(x: rect.midX, y: rect.maxY + 20))
        statusWindow?.stopHandler = { [weak self] in
            self?.stopCapture(historyManager: historyManager)
        }

        // Capture first frame immediately
        captureFrame()

        // Then capture a frame every 300ms while user scrolls (150ms was too aggressive)
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.captureFrame() }
        }
    }

    private func captureFrame() {
        guard isCapturing, let rect = captureRect, let screen = captureScreen else { return }
        Task {
            if let img = await captureEngine.captureRectToImage(rect, on: screen) {
                self.frames.append(img)
            }
        }
    }

    private func stopCapture(historyManager: HistoryManager) {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        statusWindow?.orderOut(nil)
        statusWindow = nil

        guard !frames.isEmpty else { return }
        let stitched = FrameStitcher.stitch(frames: frames)
        let item = historyManager.add(image: stitched, rect: captureRect ?? .zero)

        // Respect after-capture auto-actions (same as CaptureEngine.captureRect)
        if Settings.afterCaptureCopyToClipboard {
            ImageExporter.copyToClipboard(image: stitched)
        }
        if Settings.afterCaptureSaveAutomatically {
            let dir = Settings.autoSaveLocation
            let name = ImageExporter.timestampedName
            let ext = Settings.screenshotFormat
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            ImageExporter.save(image: stitched, to: url)
        }
        if Settings.afterCaptureShowOverlay {
            QuickAccessOverlay.show(image: stitched, historyItem: item, historyManager: historyManager)
        }
    }
}

// MARK: – Frame Stitcher

enum FrameStitcher {

    /// Convert any NSImage to NSBitmapImageRep reliably (handles CGImage-backed images).
    private static func bitmapRep(from image: NSImage) -> NSBitmapImageRep? {
        // First try direct cast — works for images created from NSBitmapImageRep
        if let existing = image.representations.first as? NSBitmapImageRep {
            return existing
        }
        // Fall back to drawing into a new bitmap (handles CGImage-backed NSImages from SCScreenshotManager)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep
    }

    /// Simple vertical stitch: deduplicates overlapping content by finding matching rows.
    static func stitch(frames: [NSImage]) -> NSImage {
        guard frames.count > 1 else { return frames[0] }
        guard let firstRep = bitmapRep(from: frames[0]) else { return frames[0] }

        let width = firstRep.pixelsWide
        var uniqueFrames: [NSBitmapImageRep] = [firstRep]

        for i in 1..<frames.count {
            guard let rep = bitmapRep(from: frames[i]) else { continue }
            // Simple dedup: skip frame if identical to previous
            if let prev = uniqueFrames.last,
               rep.representation(using: .png, properties: [:]) == prev.representation(using: .png, properties: [:]) {
                continue
            }
            uniqueFrames.append(rep)
        }

        let totalHeight = uniqueFrames.reduce(0) { $0 + $1.pixelsHigh }
        guard let result = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: totalHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return frames[0] }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: result) {
            NSGraphicsContext.current = ctx
            var y = totalHeight
            for rep in uniqueFrames {
                y -= rep.pixelsHigh
                rep.draw(in: NSRect(x: 0, y: y, width: width, height: rep.pixelsHigh))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: NSSize(width: width, height: totalHeight))
        output.addRepresentation(result)
        return output
    }
}

// MARK: – Scrolling Status Window

@MainActor
private final class ScrollingStatusWindow: NSWindow {

    var stopHandler: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true

        guard let contentView else { return }
        let view = NSVisualEffectView(frame: contentView.bounds)
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        contentView.addSubview(view)

        let label = NSTextField(labelWithString: "Scroll to capture…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 12, width: 120, height: 20)
        view.addSubview(label)

        let btn = NSButton(title: "Done", target: self, action: #selector(stopTapped))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 136, y: 8, width: 56, height: 28)
        view.addSubview(btn)
    }

    func show(near point: CGPoint) {
        setFrameOrigin(NSPoint(x: point.x - frame.width / 2, y: point.y))
        orderFrontRegardless()
    }

    @objc private func stopTapped() { stopHandler?() }
}
