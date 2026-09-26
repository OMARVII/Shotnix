import CoreGraphics
import CoreVideo

/// When the screen changed during a recording (`screenActivity` in the
/// metadata), for the editor's idle detection. A frame counts once its
/// dirty area passes a word of typing — a blinking caret stays under it —
/// and samples are at most 0.1 s apart. Some content reports the whole
/// frame dirty every frame (the lock screen, video players, games); there a
/// sparse pixel sample decides whether anything really changed.
struct RecordingScreenActivity {
    static let minimumInterval = 0.1
    static let minimumChangedPoints: CGFloat = 128
    /// A frame this dirty tells nothing about what changed.
    static let wholeFrameFraction: CGFloat = 0.95

    private(set) var samples: [Double] = []
    private var lastGrid: [UInt32]?
    private var lastGridTime = -Double.infinity

    /// `time` is recording seconds; `dirtyRects` and `frameSize` are in
    /// output pixels.
    mutating func observe(time: Double, dirtyRects: [CGRect]?, frameSize: CGSize, pixelsPerPoint: CGFloat, grid: () -> [UInt32]?) {
        if let last = samples.last, time - last < Self.minimumInterval - 0.000_1 { return }
        let frameArea = frameSize.width * frameSize.height
        guard frameArea > 0 else { return }

        if let dirtyRects {
            let frame = CGRect(origin: .zero, size: frameSize)
            let dirtyArea = dirtyRects.reduce(CGFloat(0)) { total, rect in
                let visible = rect.intersection(frame)
                return visible.isNull ? total : total + visible.width * visible.height
            }
            if dirtyArea < frameArea * Self.wholeFrameFraction {
                let scale = max(pixelsPerPoint, 0.01)
                if dirtyArea / (scale * scale) >= Self.minimumChangedPoints {
                    samples.append(time)
                }
                return
            }
        }

        guard time - lastGridTime >= Self.minimumInterval - 0.000_1, let current = grid() else { return }
        defer {
            lastGrid = current
            lastGridTime = time
        }
        if let lastGrid, Self.changed(lastGrid, current) {
            samples.append(time)
        }
    }

    /// Two or more sampled pixels moved by more than a shade (single
    /// pixels flicker with dithering and the caret).
    static func changed(_ old: [UInt32], _ new: [UInt32]) -> Bool {
        guard old.count == new.count else { return true }
        var differing = 0
        for (a, b) in zip(old, new) where a != b && channelsDiffer(a, b) {
            differing += 1
            if differing >= 2 { return true }
        }
        return false
    }

    private static func channelsDiffer(_ a: UInt32, _ b: UInt32) -> Bool {
        for shift in [UInt32(0), 8, 16] {
            let first = Int((a >> shift) & 0xFF)
            let second = Int((b >> shift) & 0xFF)
            if abs(first - second) > 12 { return true }
        }
        return false
    }

    /// A 160×90 grid of BGRA pixels — cheap enough to take ten times a second.
    static func grid(of pixelBuffer: CVPixelBuffer, columns: Int = 160, rows: Int = 90) -> [UInt32]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        var values: [UInt32] = []
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = min((row * 2 + 1) * height / (rows * 2), height - 1)
            let line = base + y * rowBytes
            for column in 0..<columns {
                let x = min((column * 2 + 1) * width / (columns * 2), width - 1)
                values.append(line.load(fromByteOffset: x * 4, as: UInt32.self))
            }
        }
        return values
    }
}
