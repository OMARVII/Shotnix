import Vision
import AppKit

enum OCREngineError: Error {
    case invalidImage
}

/// One recognized line, in image pixels with a top-left origin.
struct OCRLine: Equatable {
    let text: String
    let box: CGRect
}

struct OCRTable: Equatable {
    let rows: [[String]]

    /// Tab-separated rows — pastes straight into Numbers, Excel, or Sheets.
    var tabSeparated: String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}

struct OCRLink: Equatable {
    /// As it appears in the recognized text.
    let text: String
    let url: URL

    var isEmail: Bool { url.scheme?.lowercased() == "mailto" }
}

/// Recognized text with its layout: lines in reading order (columns kept
/// together), a table when the lines form a grid, and any links or email
/// addresses in it.
struct OCRResult {
    let lines: [OCRLine]
    let text: String
    let table: OCRTable?
    let links: [OCRLink]

    var isEmpty: Bool { text.isEmpty }

    init(lines: [OCRLine]) {
        let rows: [[OCRLine]]
        if let table = OCRLayout.table(from: lines) {
            // A table reads row by row; columns would scatter it.
            self.table = table
            rows = OCRLayout.rows(from: lines)
        } else {
            self.table = nil
            rows = OCRLayout.readingOrderRows(lines)
        }
        self.lines = rows.flatMap { $0 }
        self.text = rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        self.links = OCRLayout.links(in: text)
    }
}

enum OCREngine {

    struct Options: Equatable {
        var fast = false
        /// BCP-47 codes; empty = detect automatically.
        var languages: [String] = []

        static var current: Options {
            Options(fast: Settings.ocrFastRecognition, languages: Settings.ocrLanguages)
        }
    }

    /// Recognize text in an NSImage, with layout. The text is empty when the
    /// region genuinely contains none; throws when the image is unusable or
    /// Vision recognition fails.
    static func recognize(in image: NSImage, options: Options = .current) async throws -> OCRResult {
        guard let cgImage = image.bestCGImage else { throw OCREngineError.invalidImage }
        return try await recognize(in: cgImage, options: options)
    }

    static func recognize(in cgImage: CGImage, options: Options = .current) async throws -> OCRResult {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let lines: [OCRLine] = try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let request = VNRecognizeTextRequest { request, error in
                guard !didResume else { return }
                didResume = true
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    // Vision boxes are normalized with a bottom-left origin.
                    let box = observation.boundingBox
                    return OCRLine(
                        text: text,
                        box: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
                    )
                }
                continuation.resume(returning: lines)
            }
            configure(request, options: options)

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: error)
            }
        }
        return OCRResult(lines: lines)
    }

    /// Plain recognized text in reading order (history search, quick copies).
    static func recognizeText(in image: NSImage) async throws -> String {
        try await recognize(in: image).text
    }

    static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await recognize(in: cgImage).text
    }

    /// Languages Vision can read at the given accuracy, e.g. "en-US".
    static func supportedLanguages(fast: Bool) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    private static func configure(_ request: VNRecognizeTextRequest, options: Options) {
        request.recognitionLevel = options.fast ? .fast : .accurate
        request.usesLanguageCorrection = !options.fast
        // Fast recognition reads fewer languages; unknown picks fall back to
        // automatic detection rather than failing the request.
        let supported = Set(supportedLanguages(fast: options.fast))
        let chosen = options.languages.filter(supported.contains)
        if chosen.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = chosen
        }
    }
}

// MARK: – Layout

/// Reading order, table, and link detection over recognized lines. Pure
/// geometry, so it's tested with hand-made boxes as well as real OCR.
enum OCRLayout {

    /// Lines grouped into visual rows (top to bottom), each row left to right.
    static func rows(from lines: [OCRLine]) -> [[OCRLine]] {
        var rows: [(minY: CGFloat, maxY: CGFloat, lines: [OCRLine])] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last {
                let overlap = min(last.maxY, line.box.maxY) - max(last.minY, line.box.minY)
                if overlap >= 0.5 * min(last.maxY - last.minY, line.box.height) {
                    rows[rows.count - 1] = (min(last.minY, line.box.minY), max(last.maxY, line.box.maxY), last.lines + [line])
                    continue
                }
            }
            rows.append((line.box.minY, line.box.maxY, [line]))
        }
        return rows.map { $0.lines.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Rows in reading order: a column is read top to bottom before the one
    /// to its right. A line running across the gutter (a title, a caption)
    /// ends the columns above it and is read in place.
    static func readingOrderRows(_ lines: [OCRLine]) -> [[OCRLine]] {
        guard lines.count > 1 else { return lines.isEmpty ? [] : [lines] }
        let gutters = columnGutters(lines)
        guard !gutters.isEmpty else { return rows(from: lines) }

        var ordered: [[OCRLine]] = []
        var band: [OCRLine] = []
        func flushBand() {
            let columns = Dictionary(grouping: band) { line in
                gutters.filter { $0.upperBound <= line.box.midX }.count
            }
            for index in columns.keys.sorted() {
                ordered += rows(from: columns[index] ?? [])
            }
            band.removeAll()
        }
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            let crossesGutter = gutters.contains { gutter in
                let middle = (gutter.lowerBound + gutter.upperBound) / 2
                return line.box.minX < middle && line.box.maxX > middle
            }
            if crossesGutter {
                flushBand()
                ordered.append([line])
            } else {
                band.append(line)
            }
        }
        flushBand()
        return ordered
    }

    /// Vertical whitespace running between side-by-side columns of text.
    static func columnGutters(_ lines: [OCRLine]) -> [ClosedRange<CGFloat>] {
        guard let minX = lines.map(\.box.minX).min(), let maxX = lines.map(\.box.maxX).max(), maxX > minX else { return [] }
        let contentWidth = maxX - minX
        let lineHeight = median(lines.map(\.box.height))
        // Full-width lines (titles over both columns) would bridge every
        // gutter, so gutters are found from the narrower lines.
        let narrow = lines.filter { $0.box.width < contentWidth * 0.6 }
        guard narrow.count >= 4 else { return [] }
        let allowedCrossings = narrow.count >= 10 ? narrow.count / 10 : 0

        var events = narrow.flatMap { [($0.box.minX, 1), ($0.box.maxX, -1)] }
        events.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        var coverage = 0
        var gapStart: CGFloat?
        var gaps: [ClosedRange<CGFloat>] = []
        for (x, delta) in events {
            let before = coverage
            coverage += delta
            if before > allowedCrossings, coverage <= allowedCrossings {
                gapStart = x
            } else if before <= allowedCrossings, coverage > allowedCrossings, let start = gapStart {
                if x > start { gaps.append(start...x) }
                gapStart = nil
            }
        }

        return gaps.filter { gap in
            guard gap.upperBound - gap.lowerBound >= max(lineHeight * 0.75, 4) else { return false }
            let left = narrow.filter { $0.box.maxX <= gap.lowerBound + 0.5 }
            let right = narrow.filter { $0.box.minX >= gap.upperBound - 0.5 }
            guard left.count >= 2, right.count >= 2,
                  let leftTop = left.map(\.box.minY).min(), let leftBottom = left.map(\.box.maxY).max(),
                  let rightTop = right.map(\.box.minY).min(), let rightBottom = right.map(\.box.maxY).max() else { return false }
            // Columns sit side by side: their vertical extents overlap.
            let overlap = min(leftBottom, rightBottom) - max(leftTop, rightTop)
            return overlap >= 0.3 * min(leftBottom - leftTop, rightBottom - rightTop)
        }
    }

    /// A grid: most rows have two or more cells, and the cells line up into
    /// the same columns row after row. What tells a table from a page set in
    /// columns: table columns sit far apart relative to their short cells
    /// (a text gutter is narrow next to its lines), or the cells are numbers.
    static func table(from lines: [OCRLine]) -> OCRTable? {
        let rows = rows(from: lines)
        let multiCell = rows.filter { $0.count >= 2 }
        guard multiCell.count >= 2, Double(multiCell.count) >= Double(rows.count) * 0.6 else { return nil }

        var spans: [ClosedRange<CGFloat>] = []
        for cell in multiCell.flatMap({ $0 }).sorted(by: { $0.box.minX < $1.box.minX }) {
            let range = cell.box.minX...cell.box.maxX
            if let last = spans.last, range.lowerBound <= last.upperBound {
                spans[spans.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                spans.append(range)
            }
        }
        guard spans.count >= 2 else { return nil }

        // By left edge: every grid cell starts inside its own column's span,
        // and a line running across several columns lands in the first.
        func column(for cell: OCRLine) -> Int {
            if let index = spans.firstIndex(where: { $0.contains(cell.box.minX) }) { return index }
            return spans.indices.min { abs(spans[$0].lowerBound - cell.box.minX) < abs(spans[$1].lowerBound - cell.box.minX) } ?? 0
        }
        for row in multiCell {
            let columns = row.map(column(for:))
            guard Set(columns).count == columns.count else { return nil }
        }
        let cells = multiCell.flatMap { $0 }
        let averageWords = Double(cells.map { $0.text.split(separator: " ").count }.reduce(0, +)) / Double(max(cells.count, 1))
        let numberLike = cells.filter { cell in
            cell.text.allSatisfy { $0.isNumber || ".,:%$€£¥+-–/ ".contains($0) } && cell.text.contains(where: \.isNumber)
        }.count
        let widths = cells.map(\.box.width).sorted()
        let medianWidth = max(widths[widths.count / 2], 1)
        let gaps = zip(spans, spans.dropFirst()).map { $1.lowerBound - $0.upperBound }.sorted()
        let gapRatio = gaps[gaps.count / 2] / medianWidth
        let isTable = Double(numberLike) >= Double(cells.count) * 0.25
            || (averageWords <= 4 && gapRatio >= 0.9)
            || (spans.count >= 3 && averageWords <= 3 && gapRatio >= 0.5)
        guard isTable else { return nil }

        let grid = rows.map { row -> [String] in
            var cells = Array(repeating: "", count: spans.count)
            for cell in row {
                let index = column(for: cell)
                cells[index] = cells[index].isEmpty ? cell.text : cells[index] + " " + cell.text
            }
            return cells
        }
        return OCRTable(rows: grid)
    }

    /// Web links and email addresses, in order of appearance, deduplicated.
    static func links(in text: String) -> [OCRLink] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text) else { return nil }
            guard seen.insert(url.absoluteString.lowercased()).inserted else { return nil }
            return OCRLink(text: String(text[range]), url: url)
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
