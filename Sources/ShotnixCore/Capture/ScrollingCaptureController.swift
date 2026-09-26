import AppKit
import Accelerate
import Carbon.HIToolbox

/// Scrolling capture: the user selects a region, then scrolls. Frames are
/// grabbed back to back and stitched where each one overlaps the last, so
/// the result is the page itself — no repeated bands.
@MainActor
final class ScrollingCaptureController: NSObject {

    enum Outcome {
        case captured(image: NSImage, rect: CGRect, screen: NSScreen, note: String?)
        case cancelled
        case failed(message: String, screen: NSScreen?)
    }

    enum Phase { case idle, selecting, scrolling, finishing, done }

    typealias FrameProvider = @MainActor (CGRect, NSScreen) async -> NSImage?

    /// Frames are grabbed back to back, at most this often. Faster means more
    /// overlap between frames, so quick scrolling still stitches.
    static let frameInterval: TimeInterval = 0.15
    /// A forgotten scrolling capture ends on its own after this long.
    static let maxDuration: TimeInterval = 10 * 60

    private let frameProvider: FrameProvider
    private let completion: (Outcome) -> Void
    private var selectionWindow: AreaSelectionWindow?
    private var captureRect: CGRect = .zero
    private var captureScreen: NSScreen?
    private(set) var hud: ScrollingCaptureHUD?
    private let stitcher: FrameStitcher
    private let stitchQueue = DispatchQueue(label: "com.shotnix.scrolling.stitch", qos: .userInitiated)
    private var loopTask: Task<Void, Never>?
    private var escapeHotKey: TemporaryHotKey?
    private var localKeyMonitor: Any?
    private var startedAt = Date()
    /// Device pixels per point of the captured frames.
    private var pixelScale: CGFloat = 2

    private(set) var phase: Phase = .idle

    init(limits: FrameStitcher.Limits = FrameStitcher.Limits(), frameProvider: @escaping FrameProvider, completion: @escaping (Outcome) -> Void) {
        self.stitcher = FrameStitcher(limits: limits)
        self.frameProvider = frameProvider
        self.completion = completion
    }

    func start(engine: CaptureEngine) async {
        phase = .selecting
        selectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen in
            guard let self else { return }
            self.selectionWindow = nil
            guard let rect else {
                self.complete(.cancelled)
                return
            }
            self.beginScrolling(rect: rect, on: screen)
        }
        await selectionWindow?.prepareAndShow(engine: engine)
    }

    /// The scrolling shortcut pressed again finishes the capture. While the
    /// region is still being selected it's ignored.
    func finishFromShortcut() {
        guard phase == .scrolling else { return }
        finish()
    }

    func beginScrolling(rect: CGRect, on screen: NSScreen) {
        captureRect = rect
        captureScreen = screen
        phase = .scrolling
        startedAt = Date()

        let hud = ScrollingCaptureHUD()
        hud.doneHandler = { [weak self] in self?.finish() }
        hud.cancelHandler = { [weak self] in self?.cancel() }
        hud.show(selection: rect, on: screen)
        self.hud = hud

        installEscape()
        runFrameLoop()
    }

    // MARK: – Frame loop

    private func runFrameLoop() {
        let rect = captureRect
        guard let screen = captureScreen else { return }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .scrolling else { return }
                let frameStarted = Date()
                if let image = await self.frameProvider(rect, screen), let cg = image.bestCGImage, !Task.isCancelled {
                    self.pixelScale = CGFloat(cg.width) / max(image.size.width, 1)
                    let (result, height) = await self.stitch(cg)
                    self.handle(result, height: height)
                }
                guard self.phase == .scrolling else { return }
                if Date().timeIntervalSince(self.startedAt) > Self.maxDuration {
                    self.finish(note: "Scrolling capture stopped after 10 minutes.")
                    return
                }
                let remaining = Self.frameInterval - Date().timeIntervalSince(frameStarted)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }
    }

    /// Stitching runs on its own queue; the loop awaits each frame before
    /// grabbing the next, so the stitcher never sees two callers at once.
    private func stitch(_ frame: CGImage) async -> (FrameStitcher.FrameResult, Int) {
        let job = StitchJob(stitcher: stitcher, frame: frame)
        return await withCheckedContinuation { continuation in
            stitchQueue.async {
                let result = job.stitcher.add(job.frame)
                continuation.resume(returning: (result, job.stitcher.height))
            }
        }
    }

    private func makeStitchedImage() async -> CGImage? {
        let job = StitchJob(stitcher: stitcher, frame: nil)
        return await withCheckedContinuation { continuation in
            stitchQueue.async { continuation.resume(returning: job.stitcher.makeImage()) }
        }
    }

    private func handle(_ result: FrameStitcher.FrameResult, height: Int) {
        let points = Int((CGFloat(height) / pixelScale).rounded())
        switch result {
        case .lostTrack:
            hud?.update(heightPixels: height, status: "Scrolled too fast — scroll back up a little", isWarning: true)
        case .limitReached:
            hud?.update(heightPixels: height, status: "Maximum length reached", isWarning: true)
            finish(note: "Scrolling capture reached its maximum length (\(points.formatted()) points) and finished.")
        case .scrolledBack:
            hud?.update(heightPixels: height, status: "Scroll down to capture more", isWarning: false)
        default:
            hud?.update(heightPixels: height, status: "Scroll down to capture", isWarning: false)
        }
    }

    // MARK: – Finish

    func finish(note: String? = nil) {
        guard phase == .scrolling else { return }
        phase = .finishing
        removeEscape()
        hud?.showFinishing()
        let loop = loopTask
        loop?.cancel()
        Task { @MainActor [weak self] in
            await loop?.value
            guard let self else { return }
            let stitched = await self.makeStitchedImage()
            self.hud?.orderOut(nil)
            self.hud = nil
            guard let stitched, let screen = self.captureScreen else {
                self.complete(.failed(message: "Scrolling capture failed", screen: self.captureScreen))
                return
            }
            // Point size from the frames' own pixel density, so a Retina
            // capture exports at 144 dpi and pastes at its on-screen size.
            let logicalSize = NSSize(width: CGFloat(stitched.width) / self.pixelScale, height: CGFloat(stitched.height) / self.pixelScale)
            let image = CaptureEngine.nsImage(from: stitched, logicalSize: logicalSize)
            self.complete(.captured(image: image, rect: self.captureRect, screen: screen, note: note))
        }
    }

    func cancel() {
        switch phase {
        case .selecting:
            selectionWindow?.cancel()
        case .scrolling:
            phase = .finishing
            removeEscape()
            loopTask?.cancel()
            hud?.orderOut(nil)
            hud = nil
            complete(.cancelled)
        default:
            break
        }
    }

    private func complete(_ outcome: Outcome) {
        guard phase != .done else { return }
        phase = .done
        completion(outcome)
    }

    // MARK: – Escape

    /// Esc finishes. The user is scrolling in another app, so a local key
    /// monitor never sees it; a Carbon hot key does, with no Accessibility
    /// permission — held only for the scrolling phase.
    private func installEscape() {
        escapeHotKey = TemporaryHotKey(keyCode: UInt32(kVK_Escape)) { [weak self] in
            self?.finish()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), self?.phase == .scrolling else { return event }
            self?.finish()
            return nil
        }
    }

    private func removeEscape() {
        escapeHotKey?.unregister()
        escapeHotKey = nil
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

/// Carries the stitcher to the stitch queue — the only place it's touched.
private struct StitchJob: @unchecked Sendable {
    let stitcher: FrameStitcher
    let frame: CGImage!
}

// MARK: – Frame Stitcher

/// Stitches scrolling-capture frames into one tall image.
///
/// Each frame is reduced to a luminance profile: every pixel row averaged
/// into a few column bands (a row signature). For a new frame, the rows that
/// didn't change at all are treated as sticky header/footer, columns that
/// never move (a sidebar) are ignored, and the remaining band is matched
/// against the previous frame at every vertical offset. The best offset says
/// how far the page scrolled, and only the rows that scrolled into view are
/// appended. Not thread-safe: use from one queue.
final class FrameStitcher {

    struct Limits {
        /// Tallest stitched image, in pixels — beyond this many viewers and
        /// encoders struggle.
        var maxHeight = 30_000
        /// Cap on width × height, bounding memory for wide selections.
        var maxPixels = 64_000_000
    }

    enum FrameResult: Equatable {
        case first
        case unchanged
        case appended(rows: Int)
        case scrolledBack
        case lostTrack
        case limitReached
        case ignored
    }

    /// Height the stitched image has right now, in pixels.
    private(set) var height = 0
    private(set) var reachedLimit = false

    private let limits: Limits
    private var maxRows = 0
    private var frameWidth = 0
    private var frameHeight = 0
    private var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private var firstFrame: CGImage?
    private var reference: CGImage?
    private var referenceProfile: [Float] = []
    /// Content-space y of the reference frame's top row (first frame = 0).
    private var referencePosition = 0
    /// Content rows [0, capturedBottom) live in `strips`; nil until the page
    /// first scrolls.
    private var capturedBottom: Int?
    private var footerRows = 0
    private var lastShift = 0
    private var strips: [CGImage] = []

    private static let bands = 32
    /// Mean band difference (0–255) below which a row or column counts as
    /// unchanged — well above screen noise, well below any real change.
    private static let staticThreshold: Float = 1.0
    /// Largest mean difference accepted for a match.
    private static let matchThreshold: Float = 2.5

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func add(_ frame: CGImage) -> FrameResult {
        guard !reachedLimit else { return .limitReached }
        guard let profile = Self.profile(of: frame, bands: Self.bands) else { return .ignored }

        guard reference != nil else {
            frameWidth = frame.width
            frameHeight = frame.height
            maxRows = max(frameHeight, min(limits.maxHeight, limits.maxPixels / max(frameWidth, 1)))
            if let space = frame.colorSpace, space.model == .rgb { colorSpace = space }
            firstFrame = frame
            self.reference = frame
            referenceProfile = profile
            height = frameHeight
            return .first
        }
        guard frame.width == frameWidth, frame.height == frameHeight else { return .ignored }

        let rows = frameHeight
        let bands = Self.bands
        var difference = [Float](repeating: 0, count: rows * bands)
        vDSP_vsub(profile, 1, referenceProfile, 1, &difference, 1, vDSP_Length(rows * bands))
        vDSP_vabs(difference, 1, &difference, 1, vDSP_Length(rows * bands))

        // Columns that didn't move at all (a sidebar, margins) carry no
        // information about the scroll — and would spoil every match.
        var movingBands: [Int] = []
        difference.withUnsafeBufferPointer { buffer in
            for band in 0..<bands {
                var sum: Float = 0
                vDSP_sve(buffer.baseAddress! + band, vDSP_Stride(bands), &sum, vDSP_Length(rows))
                if sum / Float(rows) >= Self.staticThreshold { movingBands.append(band) }
            }
        }
        guard !movingBands.isEmpty else { return .unchanged }

        // Rows unchanged in every moving column: sticky header and footer.
        func isStaticRow(_ row: Int) -> Bool {
            var sum: Float = 0
            for band in movingBands { sum += difference[row * bands + band] }
            return sum / Float(movingBands.count) < Self.staticThreshold
        }
        var top = 0
        while top < rows, isStaticRow(top) { top += 1 }
        var bottom = 0
        while bottom < rows - top, isStaticRow(rows - 1 - bottom) { bottom += 1 }
        let regionTop = top
        let regionBottom = rows - bottom
        guard regionBottom - regionTop >= max(16, rows / 20) else { return .unchanged }

        let previous = Self.select(bands: movingBands, from: referenceProfile, bandCount: bands, rows: rows)
        let current = Self.select(bands: movingBands, from: profile, bandCount: bands, rows: rows)
        guard let shift = bestShift(previous: previous, current: current, width: movingBands.count, regionTop: regionTop, regionBottom: regionBottom) else {
            return .lostTrack
        }

        let position = referencePosition + shift
        let alreadyCaptured = capturedBottom ?? rows - bottom
        self.reference = frame
        referenceProfile = profile
        referencePosition = position
        lastShift = shift

        // Scrolled up, or back down but not yet past what's captured.
        guard shift > 0, position + regionBottom > alreadyCaptured else { return .scrolledBack }

        if capturedBottom == nil, let firstFrame {
            // The page scrolled for the first time: keep everything the
            // first frame showed above its footer, header included.
            appendRows(of: firstFrame, from: 0, to: rows - bottom)
            capturedBottom = rows - bottom
            self.firstFrame = nil
        }
        footerRows = bottom
        let start = max((capturedBottom ?? 0) - position, regionTop)
        var end = regionBottom
        var hitLimit = false
        let room = maxRows - footerRows - (capturedBottom ?? 0)
        if end - start > room {
            end = start + max(0, room)
            hitLimit = true
        }
        let appended = max(0, end - start)
        if appended > 0 {
            appendRows(of: frame, from: start, to: end)
            capturedBottom = (capturedBottom ?? 0) + appended
        }
        height = capturedBottom.map { $0 + footerRows } ?? rows
        if hitLimit {
            reachedLimit = true
            return .limitReached
        }
        return appended > 0 ? .appended(rows: appended) : .unchanged
    }

    /// The stitched image: every appended strip, then the last frame's footer.
    func makeImage() -> CGImage? {
        guard let reference else { return nil }
        guard capturedBottom != nil, !strips.isEmpty else { return firstFrame ?? reference }
        var pieces = strips
        if footerRows > 0, let footer = copyRows(of: reference, from: frameHeight - footerRows, to: frameHeight) {
            pieces.append(footer)
        }
        let totalHeight = pieces.reduce(0) { $0 + $1.height }
        guard let context = makeContext(width: frameWidth, height: totalHeight) else { return nil }
        var y = totalHeight
        for piece in pieces {
            y -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: y, width: frameWidth, height: piece.height))
        }
        return context.makeImage()
    }

    // MARK: Matching

    /// The vertical offset (positive = scrolled down) that best lines the
    /// new frame up with the previous one, or nil when nothing matches.
    private func bestShift(previous: [Float], current: [Float], width: Int, regionTop: Int, regionBottom: Int) -> Int? {
        let regionRows = regionBottom - regionTop
        let minOverlap = max(16, regionRows / 6)
        guard regionRows > minOverlap else { return nil }

        var candidates: [(shift: Int, error: Float)] = []
        candidates.reserveCapacity(2 * (regionRows - minOverlap))
        var scratch = [Float](repeating: 0, count: regionRows * width)
        var texture: Float = 0
        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { curr in
                scratch.withUnsafeMutableBufferPointer { work in
                    let p = prev.baseAddress!
                    let c = curr.baseAddress!
                    let w = work.baseAddress!
                    // A blank region matches at every offset; don't pretend to know.
                    texture = Self.meanAbsoluteDifference(p + regionTop * width, p + (regionTop + 1) * width, count: (regionRows - 1) * width, scratch: w)
                    guard texture >= 0.25 else { return }
                    for distance in 1...(regionRows - minOverlap) {
                        let count = (regionRows - distance) * width
                        // Scrolled down: previous rows [top+d, bottom) now sit at [top, bottom-d).
                        let down = Self.meanAbsoluteDifference(p + (regionTop + distance) * width, c + regionTop * width, count: count, scratch: w)
                        candidates.append((distance, down))
                        let up = Self.meanAbsoluteDifference(p + regionTop * width, c + (regionTop + distance) * width, count: count, scratch: w)
                        candidates.append((-distance, up))
                    }
                }
            }
        }
        guard texture >= 0.25 else { return nil }
        guard let best = candidates.min(by: { $0.error < $1.error }), best.error <= Self.matchThreshold else { return nil }
        let sortedErrors = candidates.map(\.error).sorted()
        let median = sortedErrors[sortedErrors.count / 2]
        // A real match stands out; periodic or washed-out content doesn't.
        guard best.error <= median * 0.5 else { return nil }
        // Near-ties (a list of identical rows): prefer the step closest to the
        // last one — scrolling speed changes smoothly.
        let tolerance = best.error * 1.2 + 0.2
        let ties = candidates.filter { $0.error <= tolerance }
        return ties.min(by: { abs($0.shift - lastShift) < abs($1.shift - lastShift) })?.shift ?? best.shift
    }

    private static func meanAbsoluteDifference(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int, scratch: UnsafeMutablePointer<Float>) -> Float {
        guard count > 0 else { return .greatestFiniteMagnitude }
        vDSP_vsub(b, 1, a, 1, scratch, 1, vDSP_Length(count))
        var sum: Float = 0
        vDSP_svemg(scratch, 1, &sum, vDSP_Length(count))
        return sum / Float(count)
    }

    private static func select(bands selected: [Int], from profile: [Float], bandCount: Int, rows: Int) -> [Float] {
        if selected.count == bandCount { return profile }
        var result = [Float](repeating: 0, count: rows * selected.count)
        for row in 0..<rows {
            for (index, band) in selected.enumerated() {
                result[row * selected.count + index] = profile[row * bandCount + band]
            }
        }
        return result
    }

    /// Rows × bands luminance averages, top row first. Drawing into a narrow
    /// gray context does the column averaging; rows map 1:1.
    static func profile(of image: CGImage, bands: Int) -> [Float]? {
        let rows = image.height
        let width = min(bands, image.width)
        guard rows > 0, width > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: rows * width)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
            return true
        }
        guard drawn else { return nil }
        var values = [Float](repeating: 0, count: rows * width)
        vDSP_vfltu8(pixels, 1, &values, 1, vDSP_Length(rows * width))
        guard width < bands else { return values }
        // Frames narrower than the band count: pad by repeating the last column.
        var padded = [Float](repeating: 0, count: rows * bands)
        for row in 0..<rows {
            for band in 0..<bands {
                padded[row * bands + band] = values[row * width + min(band, width - 1)]
            }
        }
        return padded
    }

    // MARK: Pixels

    private func appendRows(of image: CGImage, from start: Int, to end: Int) {
        guard let strip = copyRows(of: image, from: start, to: end) else { return }
        strips.append(strip)
    }

    /// A private copy of rows [start, end), so a strip never keeps its whole
    /// source frame alive. Same color space as the capture — the display's
    /// profile survives into the stitched file.
    private func copyRows(of image: CGImage, from start: Int, to end: Int) -> CGImage? {
        let rows = end - start
        guard rows > 0,
              let cropped = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: rows)),
              let context = makeContext(width: image.width, height: rows) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: rows))
        return context.makeImage()
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

// MARK: – HUD

/// Floating status bar for a scrolling capture: live height, Done, Cancel.
@MainActor
final class ScrollingCaptureHUD: NSPanel {

    var doneHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    nonisolated static let size = NSSize(width: 392, height: 56)

    private let statusLabel = NSTextField(labelWithString: "Scroll down to capture")
    private let detailLabel = NSTextField(labelWithString: "Esc or Done finishes")
    private let doneButton = HUDButton(title: "Done", target: nil, action: nil)
    private let cancelButton = HUDButton(title: "Cancel", target: nil, action: nil)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above ordinary floating panels, on every Space, and over apps in
        // full screen — Done must always be reachable.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // The HUD material is dark in both themes; keep the text readable on it.
        appearance = NSAppearance(named: .darkAqua)
        buildContent()
    }

    override var canBecomeKey: Bool { false }

    private func buildContent() {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        contentView = effect

        let icon = NSImageView(frame: NSRect(x: 14, y: 16, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "scroll", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        icon.contentTintColor = .controlAccentColor
        effect.addSubview(icon)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 48, y: 28, width: 190, height: 17)
        effect.addSubview(statusLabel)

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 48, y: 11, width: 190, height: 15)
        effect.addSubview(detailLabel)

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.frame = NSRect(x: 244, y: 12, width: 70, height: 32)
        effect.addSubview(cancelButton)

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.frame = NSRect(x: 314, y: 12, width: 66, height: 32)
        doneButton.bezelColor = .controlAccentColor
        effect.addSubview(doneButton)

        setAccessibilityLabel("Scrolling capture controls")
    }

    func show(selection: CGRect, on screen: NSScreen) {
        setFrame(Self.frame(selection: selection, visibleFrame: screen.visibleFrame), display: false)
        orderFrontRegardless()
    }

    func update(heightPixels: Int, status: String, isWarning: Bool) {
        statusLabel.stringValue = status
        statusLabel.textColor = isWarning ? .systemOrange : .labelColor
        detailLabel.stringValue = "\(heightPixels.formatted()) px · Esc or Done finishes"
    }

    func showFinishing() {
        statusLabel.stringValue = "Stitching…"
        statusLabel.textColor = .labelColor
        doneButton.isEnabled = false
        cancelButton.isEnabled = false
    }

    /// Just above the selection when there's room, else just below it, else
    /// pinned inside the top of the usable area — always fully inside the
    /// visible frame, never under the menu bar or the Dock. (It may overlap
    /// the selection then; captures leave Shotnix's windows out.)
    static func frame(selection: CGRect, visibleFrame: CGRect, size: NSSize = size, gap: CGFloat = 12, margin: CGFloat = 8) -> NSRect {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - size.width - margin
        let x = maxX >= minX ? min(max(selection.midX - size.width / 2, minX), maxX) : visibleFrame.midX - size.width / 2
        let above = selection.maxY + gap
        let below = selection.minY - gap - size.height
        let y: CGFloat
        if above + size.height <= visibleFrame.maxY - margin {
            y = above
        } else if below >= visibleFrame.minY + margin {
            y = below
        } else {
            y = visibleFrame.maxY - size.height - margin
        }
        return NSRect(x: x.rounded(), y: max(visibleFrame.minY, y).rounded(), width: size.width, height: size.height)
    }

    @objc private func doneTapped() { doneHandler?() }
    @objc private func cancelTapped() { cancelHandler?() }
}

/// The HUD never becomes key (the user keeps scrolling their own app), so
/// its buttons must take the very first click.
@MainActor
private final class HUDButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: – Temporary hot key

/// A Carbon hot key held only while needed. Carbon hot keys fire while
/// another app is frontmost and, unlike global key monitors, need no
/// Accessibility permission. KeyboardShortcuts' own handler passes on hot
/// keys with other signatures, so the two coexist.
@MainActor
final class TemporaryHotKey {

    fileprivate static let signature: OSType = 0x5358_4E58 // "SXNX"
    private static var nextID: UInt32 = 1

    /// What the Carbon handler calls. The handler registration owns it (a
    /// retained pointer, released on unregister), so a late event can never
    /// reach freed memory even if this object goes away first.
    fileprivate final class Target {
        let id: UInt32
        var action: (() -> Void)?

        init(id: UInt32, action: @escaping () -> Void) {
            self.id = id
            self.action = action
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var target: UnsafeMutableRawPointer?

    init?(keyCode: UInt32, modifiers: UInt32 = 0, action: @escaping () -> Void) {
        let id = Self.nextID
        Self.nextID += 1
        let target = Unmanaged.passRetained(Target(id: id, action: action)).toOpaque()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let target = Unmanaged<TemporaryHotKey.Target>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, hotKeyID.signature == TemporaryHotKey.signature, hotKeyID.id == target.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { target.action?() }
            return noErr
        }, 1, &eventType, target, &handlerRef)
        guard installed == noErr else {
            Unmanaged<Target>.fromOpaque(target).release()
            return nil
        }

        let registered = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard registered == noErr else {
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            Unmanaged<Target>.fromOpaque(target).release()
            return nil
        }
        self.target = target
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let target {
            let owned = Unmanaged<Target>.fromOpaque(target)
            owned.takeUnretainedValue().action = nil
            owned.release()
        }
        hotKeyRef = nil
        handlerRef = nil
        target = nil
    }
}
