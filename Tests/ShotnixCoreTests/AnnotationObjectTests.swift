import XCTest
@testable import ShotnixCore

final class AnnotationObjectTests: XCTestCase {
    func testAnnotationCopyIsIndependentOfOriginalMutation() throws {
        let original = ArrowAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10))
        let copy = try XCTUnwrap(original.copy() as? ArrowAnnotation)

        XCTAssertFalse(original === copy)
        XCTAssertEqual(copy.startPoint, CGPoint(x: 0, y: 0))
        XCTAssertEqual(copy.endPoint, CGPoint(x: 10, y: 10))

        original.move(by: CGPoint(x: 50, y: 50))

        XCTAssertEqual(copy.startPoint, CGPoint(x: 0, y: 0))
        XCTAssertEqual(copy.endPoint, CGPoint(x: 10, y: 10))
    }
}
