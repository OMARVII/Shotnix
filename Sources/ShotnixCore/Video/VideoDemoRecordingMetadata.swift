import AppKit
import Foundation

struct VideoDemoZoomKeyframe: Codable, Equatable, Identifiable {
    var id: UUID
    var time: Double
    var scale: Double
    var focusX: Double
    var focusY: Double

    init(id: UUID = UUID(), time: Double, scale: Double = 1.65, focusX: Double = 0.5, focusY: Double = 0.5) {
        self.id = id
        self.time = max(time, 0)
        self.scale = min(max(scale, 1), 3)
        self.focusX = min(max(focusX, 0), 1)
        self.focusY = min(max(focusY, 0), 1)
    }
}

struct VideoDemoZoomState: Equatable {
    var scale: Double
    var focusX: Double
    var focusY: Double

    static let identity = VideoDemoZoomState(scale: 1, focusX: 0.5, focusY: 0.5)

    func isMeaningfullyDifferent(from other: VideoDemoZoomState) -> Bool {
        abs(scale - other.scale) > 0.01 ||
        abs(focusX - other.focusX) > 0.01 ||
        abs(focusY - other.focusY) > 0.01
    }
}

struct VideoDemoCursorSample: Codable, Equatable {
    var time: Double
    var x: Double
    var y: Double
}

struct VideoDemoClickEvent: Codable, Equatable, Identifiable {
    enum Button: String, Codable {
        case left
        case right
        case other
    }

    var id: UUID
    var time: Double
    var x: Double
    var y: Double
    var button: Button

    init(id: UUID = UUID(), time: Double, x: Double, y: Double, button: Button) {
        self.id = id
        self.time = time
        self.x = x
        self.y = y
        self.button = button
    }
}

struct VideoDemoRecordingMetadata: Codable, Equatable {
    var videoURLPath: String
    var createdAt: Date
    var duration: Double
    var sourceWidth: Double
    var sourceHeight: Double
    var fps: Int
    var nativeCursorVisible: Bool
    var cursorSamples: [VideoDemoCursorSample]
    var clickEvents: [VideoDemoClickEvent]
}

enum VideoDemoSidecarStore {
    static func sidecarURL(for videoURL: URL, baseDirectory: URL? = nil) -> URL {
        metadataURL(for: videoURL, baseDirectory: baseDirectory)
    }

    static func metadataURL(for videoURL: URL, baseDirectory: URL? = nil) -> URL {
        directory(baseDirectory: baseDirectory)
            .appendingPathComponent(fileKey(for: videoURL), isDirectory: false)
            .appendingPathExtension("json")
    }

    static func legacySidecarURL(for videoURL: URL) -> URL {
        videoURL
            .deletingPathExtension()
            .appendingPathExtension("shotnixvideo.json")
    }

    static func load(for videoURL: URL, baseDirectory: URL? = nil) -> VideoDemoRecordingMetadata? {
        let url = metadataURL(for: videoURL, baseDirectory: baseDirectory)
        if let metadata = load(from: url) {
            removeLegacySidecarIfPossible(for: videoURL)
            return metadata
        }

        let legacyURL = legacySidecarURL(for: videoURL)
        guard let legacyMetadata = load(from: legacyURL) else { return nil }
        if save(legacyMetadata, for: videoURL, baseDirectory: baseDirectory) {
            removeLegacySidecarIfPossible(for: videoURL)
        }
        return legacyMetadata
    }

    @discardableResult
    static func save(_ metadata: VideoDemoRecordingMetadata, for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let url = metadataURL(for: videoURL, baseDirectory: baseDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            removeLegacySidecarIfPossible(for: videoURL)
            return true
        } catch {
            print("[Shotnix] Video metadata save failed: \(error)")
            return false
        }
    }

    private static func load(from url: URL) -> VideoDemoRecordingMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(VideoDemoRecordingMetadata.self, from: data)
        } catch {
            print("[Shotnix] Video metadata load failed: \(error)")
            return nil
        }
    }

    private static func removeLegacySidecarIfPossible(for videoURL: URL) {
        let legacyURL = legacySidecarURL(for: videoURL)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private static func directory(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoMetadata", isDirectory: true)
    }

    private static func fileKey(for videoURL: URL) -> String {
        Data(videoURL.standardizedFileURL.path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class VideoDemoRecordingMetadataRecorder {
    private let videoURL: URL
    private let captureRect: CGRect
    private let sourcePixelSize: CGSize
    private let fps: Int
    private let nativeCursorVisible: Bool
    private var startedAt: CFTimeInterval = 0
    private var timer: Timer?
    private var clickMonitor: Any?
    private var cursorSamples: [VideoDemoCursorSample] = []
    private var clickEvents: [VideoDemoClickEvent] = []

    init(videoURL: URL, captureRect: CGRect, sourcePixelSize: CGSize, fps: Int, nativeCursorVisible: Bool) {
        self.videoURL = videoURL
        self.captureRect = captureRect
        self.sourcePixelSize = sourcePixelSize
        self.fps = fps
        self.nativeCursorVisible = nativeCursorVisible
    }

    func start() {
        startedAt = CACurrentMediaTime()
        sampleCursor()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleCursor()
            }
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.recordClick(event)
            }
        }
    }

    func finish(duration: Double) -> VideoDemoRecordingMetadata {
        timer?.invalidate()
        timer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        sampleCursor()

        return VideoDemoRecordingMetadata(
            videoURLPath: videoURL.path,
            createdAt: Date(),
            duration: max(duration, 0),
            sourceWidth: Double(max(sourcePixelSize.width, 1)),
            sourceHeight: Double(max(sourcePixelSize.height, 1)),
            fps: fps,
            nativeCursorVisible: nativeCursorVisible,
            cursorSamples: cursorSamples,
            clickEvents: clickEvents
        )
    }

    private func sampleCursor() {
        guard let point = normalizedPoint(for: NSEvent.mouseLocation) else { return }
        cursorSamples.append(VideoDemoCursorSample(time: elapsedTime, x: point.x, y: point.y))
    }

    private func recordClick(_ event: NSEvent) {
        guard let point = normalizedPoint(for: NSEvent.mouseLocation) else { return }
        let button: VideoDemoClickEvent.Button = switch event.type {
        case .rightMouseDown: .right
        case .otherMouseDown: .other
        default: .left
        }
        clickEvents.append(VideoDemoClickEvent(time: elapsedTime, x: point.x, y: point.y, button: button))
    }

    private var elapsedTime: Double {
        max(CACurrentMediaTime() - startedAt, 0)
    }

    private func normalizedPoint(for screenPoint: NSPoint) -> CGPoint? {
        guard captureRect.width > 0, captureRect.height > 0, captureRect.contains(screenPoint) else { return nil }
        let x = (screenPoint.x - captureRect.minX) / captureRect.width
        let y = 1 - ((screenPoint.y - captureRect.minY) / captureRect.height)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
