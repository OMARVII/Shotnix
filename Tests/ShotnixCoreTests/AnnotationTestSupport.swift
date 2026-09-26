import AppKit
import XCTest
@testable import ShotnixCore

/// Test screenshots with exact pixels, and a way to read pixels back.
@MainActor
enum AnnotationTestImages {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An sRGB image of `pointSize` points at `density` pixels per point.
    /// `draw` works in pixels with a top-left origin.
    static func make(pointSize: CGSize, density: CGFloat, draw: (CGContext, _ pixelSize: CGSize) -> Void) -> NSImage {
        let width = Int((pointSize.width * density).rounded())
        let height = Int((pointSize.height * density).rounded())
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, CGSize(width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    static func solid(_ color: NSColor, pointSize: CGSize, density: CGFloat) -> NSImage {
        make(pointSize: pointSize, density: density) { ctx, size in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 1-pixel black/white checkerboard: the worst case for a leak, every
    /// pixel differs from its neighbors by the full range.
    static func checkerboard(pointSize: CGSize, density: CGFloat) -> NSImage {
        make(pointSize: pointSize, density: density) { ctx, size in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(NSColor.black.cgColor)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) where (x + y) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    /// Random gray per pixel (seeded), so any surviving original detail is
    /// visible as non-uniform blocks.
    static func noise(pointSize: CGSize, density: CGFloat, seed: UInt64 = 42) -> NSImage {
        var state = seed
        return make(pointSize: pointSize, density: density) { ctx, size in
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let value = CGFloat((state >> 33) % 256) / 255
                    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [value, value, value, 1])!)
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }

    /// Dark text on white, like a real screenshot of a document.
    static func document(pointSize: CGSize, density: CGFloat, text: String = "Account 4829 1337 — secret@example.com") -> NSImage {
        make(pointSize: pointSize, density: density) { ctx, size in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let font = NSFont.systemFont(ofSize: 13 * density, weight: .regular)
            var y: CGFloat = 12 * density
            while y < size.height - 16 * density {
                (text as NSString).draw(at: CGPoint(x: 10 * density, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
                y += 20 * density
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// RGBA8 sRGB pixels of an image, row 0 at the top.
struct AnnotationPixels: Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ cgImage: CGImage) {
        width = cgImage.width
        height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    @MainActor
    init(_ image: NSImage) {
        self.init(image.bestCGImage!)
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    func luminance(_ x: Int, _ y: Int) -> Int {
        let p = pixel(x, y)
        return (p.r * 299 + p.g * 587 + p.b * 114) / 1000
    }

    func sameRGBA(_ x: Int, _ y: Int, _ x2: Int, _ y2: Int) -> Bool {
        let a = pixel(x, y), b = pixel(x2, y2)
        return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
    }
}

enum AnnotationSnapshots {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-annotation-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func write(_ cgImage: CGImage, name: String) throws -> URL {
        let url = try directory().appendingPathComponent("\(name).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-ANNOTATION: \(url.path) — \(cgImage.width)x\(cgImage.height)")
        return url
    }

    /// Renders a view (with its subviews) the way it appears on screen.
    @MainActor
    @discardableResult
    static func write(view: NSView, name: String) throws -> URL {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try write(XCTUnwrap(rep.cgImage), name: name)
    }
}

/// Isolates Settings for a test so persisted editor styles don't leak
/// between tests (or from the machine running them).
@MainActor
final class AnnotationSettingsSandbox {
    private let suiteName = "ShotnixCoreTests.Annotation.\(UUID().uuidString)"

    init() {
        Settings.defaults = UserDefaults(suiteName: suiteName)!
    }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }
}
