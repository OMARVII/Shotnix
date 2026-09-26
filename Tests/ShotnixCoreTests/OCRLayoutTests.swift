import AppKit
import XCTest
@testable import ShotnixCore

/// Layout-aware OCR: reading order by column, table detection with
/// tab-separated copy, and link/email detection — on hand-made line boxes
/// and on real Vision output from rendered text.
final class OCRLayoutTests: XCTestCase {

    // MARK: Geometry

    func testTwoColumnsReadColumnByColumn() {
        var lines: [OCRLine] = []
        for (index, y) in stride(from: 100, to: 400, by: 40).enumerated() {
            lines.append(line("Left \(index)", x: 20, y: CGFloat(y), width: 230))
            lines.append(line("Right \(index)", x: 320, y: CGFloat(y), width: 230))
        }
        let text = OCRResult(lines: lines.shuffled()).text
        let order = text.components(separatedBy: "\n")
        XCTAssertEqual(order, (0..<8).map { "Left \($0)" } + (0..<8).map { "Right \($0)" })
    }

    func testATitleAcrossBothColumnsIsReadFirst() {
        var lines = [line("A title across the page", x: 20, y: 40, width: 530)]
        for (index, y) in stride(from: 100, to: 300, by: 40).enumerated() {
            lines.append(line("Left \(index)", x: 20, y: CGFloat(y), width: 230))
            lines.append(line("Right \(index)", x: 320, y: CGFloat(y), width: 230))
        }
        lines.append(line("A footer across the page", x: 20, y: 340, width: 530))
        let order = OCRResult(lines: lines).text.components(separatedBy: "\n")
        XCTAssertEqual(order.first, "A title across the page")
        XCTAssertEqual(order.last, "A footer across the page")
        XCTAssertEqual(Array(order[1...5]), (0..<5).map { "Left \($0)" })
    }

    func testSingleColumnReadsTopToBottom() {
        let lines = (0..<5).map { line("Line \($0)", x: 20, y: CGFloat(40 + $0 * 30), width: 400 - CGFloat($0 * 40)) }
        XCTAssertEqual(OCRResult(lines: lines.reversed()).text, (0..<5).map { "Line \($0)" }.joined(separator: "\n"))
        XCTAssertNil(OCRResult(lines: lines).table)
    }

    func testAGridOfShortCellsIsATable() throws {
        let rows = [["Item", "Qty", "Price"], ["Pens", "12", "3.50"], ["Paper", "5", "8.00"], ["Ink", "2", "21.00"]]
        var lines: [OCRLine] = []
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                lines.append(line(cell, x: CGFloat(20 + c * 160), y: CGFloat(30 + r * 40), width: CGFloat(cell.count * 11)))
            }
        }
        let result = OCRResult(lines: lines.shuffled())
        let table = try XCTUnwrap(result.table)
        XCTAssertEqual(table.rows, rows)
        XCTAssertEqual(table.tabSeparated, "Item\tQty\tPrice\nPens\t12\t3.50\nPaper\t5\t8.00\nInk\t2\t21.00")
        XCTAssertEqual(result.text.components(separatedBy: "\n").first, "Item Qty Price", "tables read row by row")
    }

    func testEmptyCellsKeepTheirColumn() throws {
        let lines = [
            line("Name", x: 20, y: 30, width: 50), line("Role", x: 200, y: 30, width: 45), line("Team", x: 380, y: 30, width: 45),
            line("Ada", x: 20, y: 70, width: 35), line("Core", x: 380, y: 70, width: 45),
            line("Lin", x: 20, y: 110, width: 30), line("Design", x: 200, y: 110, width: 65), line("Apps", x: 380, y: 110, width: 45),
        ]
        let table = try XCTUnwrap(OCRLayout.table(from: lines))
        XCTAssertEqual(table.rows[1], ["Ada", "", "Core"])
    }

    func testTwoColumnsOfProseAreNotATable() {
        let sentence = "the quick brown fox jumps over a lazy dog"
        var lines: [OCRLine] = []
        for (index, y) in stride(from: 40, to: 300, by: 30).enumerated() {
            lines.append(line("\(sentence) \(index)", x: 20, y: CGFloat(y), width: 240))
            lines.append(line("\(sentence) \(index + 20)", x: 300, y: CGFloat(y), width: 240))
        }
        XCTAssertNil(OCRLayout.table(from: lines))
    }

    func testLinksAndEmailAddressesAreFound() {
        let links = OCRLayout.links(in: "Docs: https://shotnix.com/support\nWrite to hello@shotnix.com or visit shotnix.com again https://shotnix.com/support")
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://shotnix.com/support", "mailto:hello@shotnix.com", "http://shotnix.com"])
        XCTAssertEqual(links.filter(\.isEmail).count, 1)
        XCTAssertTrue(OCRLayout.links(in: "no links here").isEmpty)
    }

    @MainActor
    func testResultToastSummarizesTheExtras() {
        let plain = OCRResult(lines: [line("Hello", x: 0, y: 0, width: 50)])
        XCTAssertNil(OCRResultWindow.extrasSummary(for: plain))
        let linked = OCRResult(lines: [line("See https://shotnix.com and a@b.co", x: 0, y: 0, width: 300)])
        XCTAssertEqual(OCRResultWindow.extrasSummary(for: linked), "1 link, 1 email address")
    }

    // MARK: Vision

    func testRenderedTwoColumnPageReadsColumnByColumn() async throws {
        let left = ["Apples grow on the old tree", "Pears ripen late in autumn", "Plums fall when they are sweet"]
        let right = ["Rivers run fast after rain", "Lakes lie still under ice", "Oceans roll on without end"]
        let image = Self.render(size: NSSize(width: 1180, height: 360)) {
            for (index, text) in left.enumerated() { Self.draw(text, at: NSPoint(x: 40, y: 260 - index * 80), size: 28) }
            for (index, text) in right.enumerated() { Self.draw(text, at: NSPoint(x: 620, y: 260 - index * 80), size: 28) }
        }
        let result = try await OCREngine.recognize(in: image, options: OCREngine.Options(fast: false, languages: ["en-US"]))
        let text = result.text.lowercased()
        let leftPositions = left.compactMap { text.range(of: $0.lowercased())?.lowerBound }
        let rightPositions = right.compactMap { text.range(of: $0.lowercased())?.lowerBound }
        XCTAssertEqual(leftPositions.count, 3, "recognized: \(result.text)")
        XCTAssertEqual(rightPositions.count, 3, "recognized: \(result.text)")
        XCTAssertLessThan(leftPositions.max()!, rightPositions.min()!, "the left column is read before the right: \(result.text)")
    }

    func testRenderedTableIsOfferedAsTabSeparatedRows() async throws {
        let rows = [["Item", "Qty", "Price"], ["Pens", "12", "3.50"], ["Paper", "5", "8.00"], ["Ink", "2", "21.00"]]
        let image = Self.render(size: NSSize(width: 820, height: 420)) {
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.enumerated() {
                    Self.draw(cell, at: NSPoint(x: 60 + c * 260, y: 330 - r * 90))
                }
            }
        }
        let result = try await OCREngine.recognize(in: image, options: OCREngine.Options(fast: false, languages: ["en-US"]))
        let table = try XCTUnwrap(result.table, "recognized: \(result.lines.map(\.text))")
        XCTAssertEqual(table.rows.count, 4)
        XCTAssertEqual(table.rows.first, ["Item", "Qty", "Price"])
        XCTAssertEqual(table.rows.last, ["Ink", "2", "21.00"])
        XCTAssertTrue(table.tabSeparated.contains("Pens\t12\t3.50"))
    }

    func testRenderedLinkIsDetected() async throws {
        let image = Self.render(size: NSSize(width: 1000, height: 240)) {
            Self.draw("Docs at https://shotnix.com/support", at: NSPoint(x: 40, y: 150))
            Self.draw("Write to hello@shotnix.com", at: NSPoint(x: 40, y: 60))
        }
        let result = try await OCREngine.recognize(in: image, options: OCREngine.Options(fast: false, languages: ["en-US"]))
        let urls = result.links.map { $0.url.absoluteString.lowercased() }
        XCTAssertTrue(urls.contains("https://shotnix.com/support"), "links: \(urls), text: \(result.text)")
        XCTAssertTrue(urls.contains("mailto:hello@shotnix.com"), "links: \(urls), text: \(result.text)")
    }

    func testFastRecognitionAndLanguageChoiceStillRead() async throws {
        let image = Self.render(size: NSSize(width: 700, height: 160)) {
            Self.draw("Quick brown fox", at: NSPoint(x: 40, y: 60))
        }
        let fast = try await OCREngine.recognize(in: image, options: OCREngine.Options(fast: true, languages: ["en-US"]))
        XCTAssertTrue(fast.text.lowercased().contains("quick brown fox"), fast.text)
        // A language fast mode doesn't know falls back to automatic.
        let fallback = try await OCREngine.recognize(in: image, options: OCREngine.Options(fast: true, languages: ["ja-JP"]))
        XCTAssertFalse(fallback.isEmpty)
    }

    // MARK: - Helpers

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 18) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func render(size: NSSize, draw: @escaping () -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func draw(_ text: String, at point: NSPoint, size: CGFloat = 34) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.black,
        ])
    }
}
