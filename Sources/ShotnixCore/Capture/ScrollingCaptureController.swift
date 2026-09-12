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
    private var isCapturingFrame = false
    private var captureTimer: Timer?
    private var statusWindow: ScrollingStatusWindow?
    private var hiddenDesktopIconsByCapture = false
    private var pendingStopHistoryManager: HistoryManager?
    /// Single reusable capture engine — never allocate per-frame
    private let captureEngine = CaptureEngine()

    var isActive: Bool { isCapturing || selectionWindow != nil }

    deinit {
        captureTimer?.invalidate()
    }

    func start(historyManager: HistoryManager, hiddenDesktopIconsByCapture: Bool = false) async {
        self.hiddenDesktopIconsByCapture = hiddenDesktopIconsByCapture
        selectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.selectionWindow = nil
            guard let rect else {
                DesktopIconsManager.showAfterCapture(ifHiddenByCapture: self.hiddenDesktopIconsByCapture)
                self.hiddenDesktopIconsByCapture = false
                return
            }
            self.captureRect = rect
            self.captureScreen = screen
            self.beginScrollingPhase(historyManager: historyManager)
        }
        await selectionWindow?.prepareAndShow(engine: captureEngine)
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
        guard !isCapturingFrame else { return }
        isCapturingFrame = true
        Task {
            if let img = await captureEngine.captureRectToImage(rect, on: screen) {
                self.frames.append(img)
                self.statusWindow?.updateCount(self.frames.count)
            }
            self.isCapturingFrame = false
            if let historyManager = self.pendingStopHistoryManager {
                self.pendingStopHistoryManager = nil
                self.finishCapture(historyManager: historyManager)
            }
        }
    }

    private func stopCapture(historyManager: HistoryManager) {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false

        if isCapturingFrame {
            pendingStopHistoryManager = historyManager
            return
        }

        finishCapture(historyManager: historyManager)
    }

    private func finishCapture(historyManager: HistoryManager) {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        isCapturingFrame = false
        selectionWindow = nil
        statusWindow?.orderOut(nil)
        statusWindow = nil
        let shouldRestoreDesktopIcons = hiddenDesktopIconsByCapture
        hiddenDesktopIconsByCapture = false

        guard !frames.isEmpty else {
            DesktopIconsManager.showAfterCapture(ifHiddenByCapture: shouldRestoreDesktopIcons)
            return
        }
        let framesToStitch = frames
        let rect = captureRect ?? .zero
        Task.detached(priority: .userInitiated) {
            let stitched = FrameStitcher.stitch(frames: framesToStitch)
            await MainActor.run { [weak self] in
                guard self != nil else {
                    DesktopIconsManager.showAfterCapture(ifHiddenByCapture: shouldRestoreDesktopIcons)
                    return
                }
                let item = historyManager.add(image: stitched, rect: rect)

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
                DesktopIconsManager.showAfterCapture(ifHiddenByCapture: shouldRestoreDesktopIcons)
            }
        }
    }
}

// MARK: – Frame Stitcher

enum FrameStitcher {

    /// Side length of the square grayscale fingerprint grid used for duplicate detection.
    private static let signatureGridSize = 32

    /// Two frames are duplicates when the mean absolute luminance difference across their
    /// 32×32 signatures is below this (0–255 scale). Cursor blink and antialiasing shimmer
    /// perturb only a handful of grid cells by a few levels (MAD well under 1), while a real
    /// scroll shifts most rows of the grid (MAD typically 5+), so 2.0 separates the two with
    /// comfortable margin on both sides.
    private static let duplicateMADThreshold: Double = 2.0

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

    /// Cheap perceptual fingerprint: downsample the frame into a 32×32 average-luminance
    /// grid (1 KB) by drawing into a tiny grayscale CGContext. No Vision, no PNG encoding.
    private static func signature(of rep: NSBitmapImageRep) -> [UInt8]? {
        guard let cgImage = rep.cgImage else { return nil }
        let side = signatureGridSize
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drewOK = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .medium // area-averaging downsample
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drewOK ? pixels : nil
    }

    /// Mean absolute difference between two signatures, on the 0–255 luminance scale.
    private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count)
    }

    /// Simple vertical stitch: deduplicates overlapping content by finding matching rows.
    static func stitch(frames: [NSImage]) -> NSImage {
        guard frames.count > 1 else { return frames[0] }
        guard let firstRep = bitmapRep(from: frames[0]) else { return frames[0] }

        let width = firstRep.pixelsWide
        var uniqueFrames: [NSBitmapImageRep] = [firstRep]
        // Signature of the most recently accepted frame — each candidate is compared
        // against this instead of byte-comparing full bitmaps.
        var lastSignature = signature(of: firstRep)

        for i in 1..<frames.count {
            guard let rep = bitmapRep(from: frames[i]) else { continue }
            let sig = signature(of: rep)
            if let prev = uniqueFrames.last,
               rep.pixelsWide == prev.pixelsWide,
               rep.pixelsHigh == prev.pixelsHigh,
               let sig,
               let prevSig = lastSignature,
               meanAbsoluteDifference(sig, prevSig) < duplicateMADThreshold {
                continue // near-identical to the last accepted frame — user didn't scroll
            }
            uniqueFrames.append(rep)
            lastSignature = sig
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
    private let countLabel = NSTextField(labelWithString: "0 frames")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
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
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)

        let label = NSTextField(labelWithString: "Scroll to capture…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 12, width: 110, height: 20)
        view.addSubview(label)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 122, y: 12, width: 64, height: 20)
        view.addSubview(countLabel)

        let btn = NSButton(title: "Done", target: self, action: #selector(stopTapped))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 192, y: 8, width: 56, height: 28)
        view.addSubview(btn)
    }

    func updateCount(_ count: Int) {
        countLabel.stringValue = "\(count) frame\(count == 1 ? "" : "s")"
    }

    func show(near point: CGPoint) {
        setFrameOrigin(NSPoint(x: point.x - frame.width / 2, y: point.y))
        orderFrontRegardless()
    }

    @objc private func stopTapped() { stopHandler?() }
}
