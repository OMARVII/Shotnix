import AppKit
import XCTest
@testable import ShotnixCore

/// The editor's toolbar reads as one aligned object: every group sits on
/// the dock's midline with the same margin all around, a selected tool's
/// fill has equal padding on every side, and presses scale about the center.
@MainActor
final class AnnotationToolbarLayoutTests: XCTestCase {

    func testEveryToolSitsInItsGroupWithEqualPaddingOnAllSides() throws {
        let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: AnnotationToolbar.requiredWidth, height: AnnotationToolbar.height))
        XCTAssertEqual(toolbar.groupFrames.count, AnnotationToolbar.toolGroups.count + 1, "three tool groups and the color/options group")

        for (index, group) in AnnotationToolbar.toolGroups.enumerated() {
            let background = toolbar.groupFrames[index]
            for tool in group {
                let button = try XCTUnwrap(toolbar.frame(of: tool))
                XCTAssertEqual(button.minY - background.minY, background.maxY - button.maxY, accuracy: 0.001, "\(tool): as much room below as above")
                XCTAssertEqual(button.minY - background.minY, 3, accuracy: 0.001)
            }
            let first = try XCTUnwrap(toolbar.frame(of: group[0]))
            let last = try XCTUnwrap(toolbar.frame(of: group[group.count - 1]))
            XCTAssertEqual(first.minX - background.minX, 3, accuracy: 0.001, "left padding matches the top")
            XCTAssertEqual(background.maxX - last.maxX, 3, accuracy: 0.001, "right padding matches the left")
        }
    }

    func testTheRowIsCenteredInTheDockWithEvenGaps() throws {
        let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: AnnotationToolbar.requiredWidth, height: AnnotationToolbar.height))
        let groups = toolbar.groupFrames
        for group in groups {
            XCTAssertEqual(group.midY, AnnotationToolbar.height / 2, accuracy: 0.001, "on the dock's midline")
            XCTAssertEqual(group.minY, 8, accuracy: 0.001)
        }
        XCTAssertEqual(groups[0].minX, 8, accuracy: 0.001, "as far from the dock's left edge as from its top")
        for (left, right) in zip(groups, groups.dropFirst()) {
            XCTAssertEqual(right.minX - left.maxX, 8, accuracy: 0.001, "the same gap between every pair of groups")
        }
        XCTAssertEqual(AnnotationToolbar.requiredWidth - toolbar.trailingControlMaxX, 8, accuracy: 0.001, "and from the right edge")

        let color = try XCTUnwrap(toolbar.colorButtonFrame)
        let optionsGroup = groups[groups.count - 1]
        XCTAssertEqual(color.midY, optionsGroup.midY, accuracy: 0.001)
        XCTAssertEqual(color.minX - optionsGroup.minX, color.minY - optionsGroup.minY, accuracy: 0.001, "the color button's side margin matches its top")
    }

    func testPressesScaleAboutTheCenterWhateverTheAnchor() {
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0)] {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
            layer.anchorPoint = anchor
            let transform = layer.scaledAboutCenter(0.92)
            // Points relative to the anchor, as Core Animation applies them.
            func mapped(_ point: CGPoint) -> CGPoint {
                let local = CGPoint(x: point.x - anchor.x * 34, y: point.y - anchor.y * 34)
                let m = transform
                let x = local.x * m.m11 + local.y * m.m21 + m.m41
                let y = local.x * m.m12 + local.y * m.m22 + m.m42
                return CGPoint(x: x + anchor.x * 34, y: y + anchor.y * 34)
            }
            let center = mapped(CGPoint(x: 17, y: 17))
            XCTAssertEqual(center.x, 17, accuracy: 0.0001, "anchor \(anchor): the center doesn't move")
            XCTAssertEqual(center.y, 17, accuracy: 0.0001)
            let corner = mapped(.zero)
            XCTAssertEqual(corner.x, 17 - 17 * 0.92, accuracy: 0.0001, "the corners move in evenly")
            XCTAssertEqual(corner.y, 17 - 17 * 0.92, accuracy: 0.0001)
        }
    }
}
