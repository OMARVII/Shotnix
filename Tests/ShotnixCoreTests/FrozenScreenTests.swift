import AppKit
import XCTest
@testable import ShotnixCore

/// Cutting a shot out of a display's still (FrozenScreen): the same pixels a
/// live capture of that rect would take.
final class FrozenScreenTests: XCTestCase {

    /// A picture whose every pixel says where it is: red = column, green =
    /// row (both modulo 256), blue = 200.
    private func still(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                data[offset] = 200                      // blue
                data[offset + 1] = UInt8(row % 256)     // green
                data[offset + 2] = UInt8(column % 256)  // red
                data[offset + 3] = 255
            }
        }
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }

    /// (red, green, blue) of a pixel, counted from the top-left.
    private func pixel(_ image: CGImage, _ column: Int, _ row: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (row * image.width + column) * 4
        return [Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset])]
    }

    func testARectIsCutFromTheRowsItCovers() throws {
        // 200 × 120 points at 2×. AppKit's y runs up, the picture's rows down.
        let frozen = FrozenScreen(image: still(width: 400, height: 240), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let cut = try XCTUnwrap(frozen.cut(CGRect(x: 30, y: 20, width: 50, height: 40)))
        XCTAssertEqual(cut.logicalSize, NSSize(width: 50, height: 40))
        XCTAssertEqual(cut.image.width, 100)
        XCTAssertEqual(cut.image.height, 80)
        // Top-left of the cut: column 60, and row (120 − 20 − 40) × 2 = 120.
        XCTAssertEqual(pixel(cut.image, 0, 0), [60, 120, 200])
        XCTAssertEqual(pixel(cut.image, 99, 79), [159, 199, 200])
    }

    func testAScreenBesideTheMainOneIsMeasuredFromItsOwnCorner() throws {
        // Left of the main display and higher up, at 1×.
        let frame = CGRect(x: -1512, y: 458, width: 1512, height: 982)
        let frozen = FrozenScreen(image: still(width: 1512, height: 982), screenFrame: frame)
        let cut = try XCTUnwrap(frozen.cut(CGRect(x: -1500, y: 1400, width: 100, height: 30)))
        XCTAssertEqual(cut.image.width, 100)
        XCTAssertEqual(cut.image.height, 30)
        // Column 12; row 982 − (1400 − 458) − 30 = 10.
        XCTAssertEqual(pixel(cut.image, 0, 0), [12, 10, 200])
    }

    func testFractionalEdgesSnapOutwardToWholePixelsLikeALiveCapture() throws {
        let frozen = FrozenScreen(image: still(width: 400, height: 240), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let rect = CGRect(x: 10.3, y: 5.2, width: 20.4, height: 10.1)
        let cut = try XCTUnwrap(frozen.cut(rect))
        // CaptureEngine.captureRectSCK: floor the origin, ceil the size, in pixels.
        let scale: CGFloat = 2
        XCTAssertEqual(cut.image.width, Int(ceil(rect.width * scale)))
        XCTAssertEqual(cut.image.height, Int(ceil(rect.height * scale)))
        XCTAssertEqual(cut.logicalSize.width, ceil(rect.width * scale) / scale)
        XCTAssertEqual(cut.logicalSize.height, ceil(rect.height * scale) / scale)
        let column = Int(floor(rect.minX * scale))
        let bottom = Int(floor(rect.minY * scale))
        XCTAssertEqual(pixel(cut.image, 0, 0), [column, 240 - bottom - cut.image.height, 200])
    }

    func testARectReachingPastTheScreenIsCutAtItsEdge() throws {
        let frozen = FrozenScreen(image: still(width: 400, height: 240), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let cut = try XCTUnwrap(frozen.cut(CGRect(x: 180, y: 100, width: 100, height: 100)))
        XCTAssertEqual(cut.logicalSize, NSSize(width: 20, height: 20))
        XCTAssertEqual(cut.image.width, 40)
        XCTAssertEqual(cut.image.height, 40)
        XCTAssertEqual(pixel(cut.image, 0, 0), [360 % 256, 0, 200], "the top-right corner")
        let whole = try XCTUnwrap(frozen.cut(CGRect(x: -50, y: -50, width: 500, height: 500)))
        XCTAssertEqual(whole.image.width, 400)
        XCTAssertEqual(whole.image.height, 240)
        XCTAssertEqual(whole.logicalSize, NSSize(width: 200, height: 120))
    }

    func testARectOnAnotherScreenOrTooSmallCutsNothing() {
        let frozen = FrozenScreen(image: still(width: 400, height: 240), screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertNil(frozen.cut(CGRect(x: 300, y: 10, width: 50, height: 50)))
        XCTAssertNil(frozen.cut(CGRect(x: 10, y: 10, width: 0.4, height: 50)))
        XCTAssertNil(frozen.cut(.null))
        XCTAssertNil(FrozenScreen(image: still(width: 4, height: 4), screenFrame: .zero).cut(CGRect(x: 0, y: 0, width: 2, height: 2)))
    }

    func testTheCutKeepsTheDisplaysColorSpaceAndEveryPixel() throws {
        // A display's own profile, not sRGB: nothing may be converted.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let frozen = FrozenScreen(image: still(width: 300, height: 200, space: space), screenFrame: CGRect(x: 0, y: 0, width: 150, height: 100))
        let cut = try XCTUnwrap(frozen.cut(CGRect(x: 20, y: 30, width: 60, height: 40)))
        XCTAssertEqual(cut.image.colorSpace?.name, space.name)
        for (column, row) in [(0, 0), (59, 39), (119, 79), (60, 17)] {
            XCTAssertEqual(pixel(cut.image, column, row), [(40 + column) % 256, (200 - 60 - 80 + row) % 256, 200], "pixel \(column), \(row)")
        }
    }

    func testTheCutDoesNotKeepTheWholeStillAlive() throws {
        let image = still(width: 400, height: 240)
        let frozen = FrozenScreen(image: image, screenFrame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let cut = try XCTUnwrap(frozen.cut(CGRect(x: 30, y: 20, width: 50, height: 40)))
        // A plain crop shares the still's bytes: 400 × 240 of them for a 100 × 80 shot.
        let bytes = CFDataGetLength(try XCTUnwrap(cut.image.dataProvider?.data))
        XCTAssertLessThanOrEqual(bytes, cut.image.bytesPerRow * cut.image.height)
        XCTAssertLessThan(bytes, 400 * 240 * 4 / 2)
    }

    // MARK: Against a live capture

    func testALiveCaptureKeepsTheSamePixelsAsACutFromTheStill() {
        // Whatever the rect, both come to the same pixels of the display.
        let screen = CGRect(x: -1512, y: 458, width: 1512, height: 982)
        let still = FrozenScreen(image: Self.gradient(width: 3024, height: 1964), screenFrame: screen)
        for rect in [
            CGRect(x: -1400.27, y: 600.81, width: 187.36, height: 93.4),
            CGRect(x: -1000.5, y: 700, width: 120.5, height: 130),
            CGRect(x: -900, y: 500.5, width: 77, height: 151.5),
            CGRect(x: -1512, y: 458, width: 1512, height: 982),
        ] {
            let geometry = CaptureEngine.stillGeometry(rect: rect, screenFrame: screen, scale: 2)
            let cut = try? XCTUnwrap(still.cut(rect))
            let crop = geometry.crop ?? CGRect(x: 0, y: 0, width: geometry.pixelWidth, height: geometry.pixelHeight)
            XCTAssertEqual(cut?.image.width, Int(crop.width), "\(rect)")
            XCTAssertEqual(cut?.image.height, Int(crop.height), "\(rect)")
            XCTAssertEqual(cut?.logicalSize, geometry.logicalSize, "\(rect)")
            // The first pixel kept, counted from the display's top left.
            let x = geometry.sourceRect.minX * 2 + crop.minX
            let y = geometry.sourceRect.minY * 2 + crop.minY
            XCTAssertEqual(x, floor((rect.minX - screen.minX) * 2), "\(rect)")
            XCTAssertEqual(y, 1964 - floor((rect.minY - screen.minY) * 2) - ceil(rect.height * 2), "\(rect)")
        }
    }

    private static func gradient(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
