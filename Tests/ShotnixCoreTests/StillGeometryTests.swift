import AppKit
import XCTest
@testable import ShotnixCore

/// What a live capture of a rect asks ScreenCaptureKit for
/// (CaptureEngine.stillGeometry): whole points only, and of the answer it
/// keeps the rect's own pixels.
final class StillGeometryTests: XCTestCase {

    func testALiveCaptureOnWholePointsAsksForExactlyThatAndKeepsAllOfIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = CaptureEngine.stillGeometry(rect: CGRect(x: 100, y: 200, width: 300, height: 150), screenFrame: screen, scale: 2)
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 100, y: 982 - 350, width: 300, height: 150), "from the top, as ScreenCaptureKit counts")
        XCTAssertEqual(geometry.pixelWidth, 600)
        XCTAssertEqual(geometry.pixelHeight, 300)
        XCTAssertNil(geometry.crop)
        XCTAssertEqual(geometry.logicalSize, NSSize(width: 300, height: 150))
    }

    func testALiveCaptureOnHalfPointsAsksForTheWholePointsAroundItAndCutsTheRestOff() {
        // Half points are whole pixels on a Retina display, but a source
        // rect on them gets scaled, which softens the shot.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = CaptureEngine.stillGeometry(rect: CGRect(x: 593.5, y: 404.5, width: 201.5, height: 99), screenFrame: screen, scale: 2)
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 593, y: 982 - 504, width: 202, height: 100))
        XCTAssertEqual(geometry.pixelWidth, 404)
        XCTAssertEqual(geometry.pixelHeight, 200)
        XCTAssertEqual(geometry.crop, CGRect(x: 1, y: 1, width: 403, height: 198), "the pixel left of it and the row above it go, the row under it too")
        XCTAssertEqual(geometry.logicalSize, NSSize(width: 201.5, height: 99))
        for value in [geometry.sourceRect.minX, geometry.sourceRect.minY, geometry.sourceRect.width, geometry.sourceRect.height] {
            XCTAssertEqual(value, value.rounded(), "whole points only")
        }
    }

    func testOnADisplayOfOnePixelPerPointALiveCaptureNeverCuts() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let geometry = CaptureEngine.stillGeometry(rect: CGRect(x: 10.3, y: 20.7, width: 99.2, height: 50.5), screenFrame: screen, scale: 1)
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 10, y: 1440 - 20 - 51, width: 100, height: 51))
        XCTAssertNil(geometry.crop)
        XCTAssertEqual(geometry.logicalSize, NSSize(width: 100, height: 51))
    }
}
