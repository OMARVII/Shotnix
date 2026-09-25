import AppKit
import Foundation

struct VideoDemoCursorSample: Codable, Equatable {
    var time: Double
    /// Video-normalized, y pointing DOWN. Values outside 0...1 mean the
    /// pointer was outside the captured area (the renderer fades it out).
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
    /// When the button was released (nil for recordings made before
    /// press tracking existed — the renderer assumes a quick tap).
    var endTime: Double?

    init(id: UUID = UUID(), time: Double, x: Double, y: Double, button: Button, endTime: Double? = nil) {
        self.id = id
        self.time = time
        self.x = x
        self.y = y
        self.button = button
        self.endTime = endTime
    }

    /// How long the button stayed down, clamped to something drawable.
    var pressDuration: Double {
        guard let endTime, endTime > time else { return 0.12 }
        return min(endTime - time, 30)
    }
}

/// One distinct pointer appearance captured during a recording (arrow,
/// I-beam, pointing hand, resize…) — stored as the system's own high-res
/// bitmap so the editor can redraw the real macOS cursor crisply at any
/// size and zoom.
struct VideoCursorShape: Codable, Equatable, Identifiable {
    var id: String
    /// Hot spot in points, top-left origin (NSCursor convention).
    var hotSpotX: Double
    var hotSpotY: Double
    /// Size in points.
    var width: Double
    var height: Double
    var pngData: Data
}

struct VideoCursorShapeEvent: Codable, Equatable {
    var time: Double
    var shapeID: String
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
    /// Source pixels per screen point (2 on Retina) — sizes the rendered
    /// cursor exactly like the real one.
    var pointPixelScale: Double? = nil
    var cursorShapes: [VideoCursorShape]? = nil
    var cursorShapeEvents: [VideoCursorShapeEvent]? = nil
    /// Whether the editor should draw the pointer. nil (older sidecars)
    /// means "draw it only when it isn't already in the video pixels".
    var renderCursor: Bool? = nil
    /// Camera footage recorded alongside the screen.
    var webcam: VideoWebcamRecording? = nil
    /// Keyboard shortcuts pressed during the recording (never plain typing).
    var keystrokes: [VideoKeystrokeEvent]? = nil
    /// What each audio track carries, in file order.
    var audioTracks: [VideoAudioKind]? = nil

    var shouldRenderCursor: Bool { renderCursor ?? !nativeCursorVisible }
}

/// The recording's own data (pointer path, clicks, shortcuts, camera):
/// found by the ID stamped on the video, so renaming or moving the file
/// keeps it; the path is the fallback.
enum VideoDemoSidecarStore {
    static func legacySidecarURL(for videoURL: URL) -> URL {
        videoURL
            .deletingPathExtension()
            .appendingPathExtension("shotnixvideo.json")
    }

    static func load(for videoURL: URL, baseDirectory: URL? = nil) -> VideoDemoRecordingMetadata? {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        if let id = VideoFileIdentity.id(of: canonical),
           let metadata = load(from: folder.appendingPathComponent(VideoFileIdentity.idKey(id)).appendingPathExtension("json")) {
            return metadata
        }
        // Older names (by path) and the old file next to the video: move
        // them to the ID so a later rename keeps them.
        let pathURL = folder.appendingPathComponent(VideoFileIdentity.pathKey(canonical)).appendingPathExtension("json")
        let candidates = [
            pathURL,
            folder.appendingPathComponent(VideoFileIdentity.legacyKey(videoURL)).appendingPathExtension("json"),
            folder.appendingPathComponent(VideoFileIdentity.legacyKey(canonical)).appendingPathExtension("json"),
            legacySidecarURL(for: videoURL),
        ]
        for url in candidates {
            guard let metadata = load(from: url) else { continue }
            if VideoFileIdentity.ensureID(of: canonical) != nil || url != pathURL,
               save(metadata, for: videoURL, baseDirectory: baseDirectory) {
                // Written under its new name: the old one goes (a file that
                // can't take an ID keeps its path name, untouched).
                let newURL = VideoFileIdentity.id(of: canonical).map { folder.appendingPathComponent(VideoFileIdentity.idKey($0)).appendingPathExtension("json") } ?? pathURL
                if newURL != url { try? FileManager.default.removeItem(at: url) }
            }
            return metadata
        }
        return nil
    }

    /// A copy got its own ID: it keeps the recording's data.
    static func copyData(fromID old: String, toID new: String, baseDirectory: URL? = nil) {
        let folder = directory(baseDirectory: baseDirectory)
        let source = folder.appendingPathComponent(VideoFileIdentity.idKey(old)).appendingPathExtension("json")
        let destination = folder.appendingPathComponent(VideoFileIdentity.idKey(new)).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    @discardableResult
    static func save(_ metadata: VideoDemoRecordingMetadata, for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        let key = VideoFileIdentity.ensureID(of: canonical).map(VideoFileIdentity.idKey) ?? VideoFileIdentity.pathKey(canonical)
        let url = folder.appendingPathComponent(key).appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
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

    private static func directory(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? VideoStorageLocation.root
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoMetadata", isDirectory: true)
    }
}

@MainActor
final class VideoDemoRecordingMetadataRecorder {
    /// Cursor position sampling rate. 60Hz keeps fast flicks faithful; the
    /// editor's smoothing turns the samples into a fluid path.
    static let sampleRate = 60.0

    private let videoURL: URL
    private let captureRect: CGRect
    private let sourcePixelSize: CGSize
    private let fps: Int
    private let nativeCursorVisible: Bool
    private let renderCursor: Bool
    private let recordsKeystrokes: Bool
    private var startedAt: CFTimeInterval = 0
    private var timer: Timer?
    private var buttonMonitor: Any?
    private var keyMonitor: Any?
    private var keystrokes: [VideoKeystrokeEvent] = []
    private var cursorSamples: [VideoDemoCursorSample] = []
    private var clickEvents: [VideoDemoClickEvent] = []
    private var openPresses: [VideoDemoClickEvent.Button: Int] = [:]
    private var cursorShapes: [String: VideoCursorShape] = [:]
    private var cursorShapeEvents: [VideoCursorShapeEvent] = []
    private var lastShapeProbe: CFTimeInterval = 0
    private var lastSampledPoint: CGPoint?
    private var shapeFingerprintCache: [ObjectIdentifier: String] = [:]

    init(videoURL: URL, captureRect: CGRect, sourcePixelSize: CGSize, fps: Int, nativeCursorVisible: Bool, renderCursor: Bool, recordsKeystrokes: Bool = false) {
        self.videoURL = videoURL
        self.captureRect = captureRect
        self.sourcePixelSize = sourcePixelSize
        self.fps = fps
        self.nativeCursorVisible = nativeCursorVisible
        self.renderCursor = renderCursor
        self.recordsKeystrokes = recordsKeystrokes
    }

    func start() {
        startedAt = CACurrentMediaTime()
        sampleCursor(force: true)
        // .common so sampling keeps running while menus track or the user
        // drags — exactly the moments a demo needs the cursor most.
        let timer = Timer(timeInterval: 1.0 / Self.sampleRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleCursor(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        buttonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.recordButton(type)
            }
        }

        // Shortcuts only: the formatter drops anything without ⌘/⌃/⌥
        // (plus Esc and F-keys), so typed text never reaches the file.
        if recordsKeystrokes, VideoKeystrokeFormatter.isAllowed {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard !event.isARepeat,
                      let keys = VideoKeystrokeFormatter.keys(
                          keyCode: event.keyCode,
                          characters: event.charactersIgnoringModifiers,
                          modifiers: event.modifierFlags
                      ) else { return }
                MainActor.assumeIsolated {
                    self?.recordKeystroke(keys)
                }
            }
        }
    }

    private func recordKeystroke(_ keys: [String]) {
        keystrokes.append(VideoKeystrokeEvent(time: elapsedTime, keys: keys))
    }

    /// Re-anchors t=0 to the wall-clock time of the first appended video frame
    /// so cursor/click timestamps align with the video timeline. Samples taken
    /// before the first frame are shifted back; the newest pre-frame cursor
    /// sample is clamped to t=0 so the cursor has a known starting position.
    func alignStart(to wallClockTime: CFTimeInterval) {
        let offset = wallClockTime - startedAt
        guard offset > 0 else { return }
        startedAt = wallClockTime

        var shiftedSamples: [VideoDemoCursorSample] = []
        for sample in cursorSamples {
            let time = sample.time - offset
            if time < 0 {
                // Samples are chronological, so this keeps only the newest pre-frame one.
                shiftedSamples = [VideoDemoCursorSample(time: 0, x: sample.x, y: sample.y)]
            } else {
                shiftedSamples.append(VideoDemoCursorSample(time: time, x: sample.x, y: sample.y))
            }
        }
        cursorSamples = shiftedSamples

        clickEvents = clickEvents.compactMap { event in
            let time = event.time - offset
            guard time >= 0 else { return nil }
            return VideoDemoClickEvent(
                id: event.id,
                time: time,
                x: event.x,
                y: event.y,
                button: event.button,
                endTime: event.endTime.map { max($0 - offset, time) }
            )
        }

        var shiftedShapes: [VideoCursorShapeEvent] = []
        for event in cursorShapeEvents {
            let time = event.time - offset
            if time < 0 {
                shiftedShapes = [VideoCursorShapeEvent(time: 0, shapeID: event.shapeID)]
            } else {
                shiftedShapes.append(VideoCursorShapeEvent(time: time, shapeID: event.shapeID))
            }
        }
        cursorShapeEvents = shiftedShapes

        keystrokes = keystrokes.compactMap { event in
            let time = event.time - offset
            guard time >= 0 else { return nil }
            return VideoKeystrokeEvent(id: event.id, time: time, keys: event.keys)
        }
    }

    func finish(duration: Double) -> VideoDemoRecordingMetadata {
        timer?.invalidate()
        timer = nil
        if let buttonMonitor {
            NSEvent.removeMonitor(buttonMonitor)
            self.buttonMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        sampleCursor(force: true)

        // Presses still held at stop end with the recording.
        let end = max(duration, 0)
        for index in openPresses.values where clickEvents.indices.contains(index) {
            clickEvents[index].endTime = max(end, clickEvents[index].time)
        }
        openPresses.removeAll()

        let usedShapeIDs = Set(cursorShapeEvents.map(\.shapeID))
        let shapes = cursorShapes.values
            .filter { usedShapeIDs.contains($0.id) }
            .sorted { $0.id < $1.id }

        return VideoDemoRecordingMetadata(
            videoURLPath: videoURL.path,
            createdAt: Date(),
            duration: end,
            sourceWidth: Double(max(sourcePixelSize.width, 1)),
            sourceHeight: Double(max(sourcePixelSize.height, 1)),
            fps: fps,
            nativeCursorVisible: nativeCursorVisible,
            cursorSamples: cursorSamples,
            clickEvents: clickEvents,
            pointPixelScale: captureRect.width > 0 ? Double(sourcePixelSize.width / captureRect.width) : nil,
            cursorShapes: shapes.isEmpty ? nil : shapes,
            cursorShapeEvents: cursorShapeEvents.isEmpty ? nil : cursorShapeEvents,
            renderCursor: renderCursor,
            // The stop shortcut itself isn't part of the demo.
            keystrokes: keystrokes.filter { $0.time < end - 0.05 }
        )
    }

    private func sampleCursor(force: Bool) {
        let point = normalizedPoint(for: NSEvent.mouseLocation)
        let moved = lastSampledPoint.map { abs($0.x - point.x) > 0.00005 || abs($0.y - point.y) > 0.00005 } ?? true
        // Stationary stretches collapse to one sample every ~0.25s — the
        // path stays exact while long idle recordings stay small.
        if force || moved || (cursorSamples.last.map { elapsedTime - $0.time >= 0.25 } ?? true) {
            cursorSamples.append(VideoDemoCursorSample(time: elapsedTime, x: point.x, y: point.y))
            lastSampledPoint = point
        }
        probeCursorShape(force: force, moved: moved)
    }

    /// Reads the system pointer appearance (~8x/s while moving, ~2x/s
    /// otherwise; each probe costs a few ms) and records changes.
    private func probeCursorShape(force: Bool, moved: Bool) {
        let now = CACurrentMediaTime()
        let interval = moved ? 0.12 : 0.5
        guard force || now - lastShapeProbe >= interval else { return }
        lastShapeProbe = now
        guard let cursor = NSCursor.currentSystem,
              let shapeID = registerShape(cursor) else { return }
        if cursorShapeEvents.last?.shapeID != shapeID {
            cursorShapeEvents.append(VideoCursorShapeEvent(time: elapsedTime, shapeID: shapeID))
        }
    }

    private func registerShape(_ cursor: NSCursor) -> String? {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // The smallest bitmap is enough to tell cursors apart cheaply.
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        guard let smallest = reps.min(by: { $0.pixelsWide < $1.pixelsWide }),
              let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        var hasher = Hasher()
        hasher.combine(Int(size.width * 10))
        hasher.combine(Int(size.height * 10))
        hasher.combine(Int(cursor.hotSpot.x * 10))
        hasher.combine(Int(cursor.hotSpot.y * 10))
        if let data = smallest.bitmapData {
            let count = smallest.bytesPerRow * smallest.pixelsHigh
            hasher.combine(bytes: UnsafeRawBufferPointer(start: data, count: count))
        }
        let id = String(format: "c%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
        if cursorShapes[id] == nil,
           let png = largest.representation(using: .png, properties: [:]) {
            cursorShapes[id] = VideoCursorShape(
                id: id,
                hotSpotX: cursor.hotSpot.x,
                hotSpotY: cursor.hotSpot.y,
                width: size.width,
                height: size.height,
                pngData: png
            )
        }
        return cursorShapes[id] == nil ? nil : id
    }

    private func recordButton(_ type: NSEvent.EventType) {
        let button: VideoDemoClickEvent.Button
        let isDown: Bool
        switch type {
        case .leftMouseDown: (button, isDown) = (.left, true)
        case .rightMouseDown: (button, isDown) = (.right, true)
        case .otherMouseDown: (button, isDown) = (.other, true)
        case .leftMouseUp: (button, isDown) = (.left, false)
        case .rightMouseUp: (button, isDown) = (.right, false)
        case .otherMouseUp: (button, isDown) = (.other, false)
        default: return
        }

        let point = normalizedPoint(for: NSEvent.mouseLocation)
        if isDown {
            // Presses outside the captured area are not part of the demo.
            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
            clickEvents.append(VideoDemoClickEvent(time: elapsedTime, x: point.x, y: point.y, button: button))
            openPresses[button] = clickEvents.count - 1
            // A press often changes the pointer (closed hand, I-beam) — look now.
            probeCursorShape(force: true, moved: true)
        } else if let index = openPresses.removeValue(forKey: button), clickEvents.indices.contains(index) {
            clickEvents[index].endTime = max(elapsedTime, clickEvents[index].time)
        }
    }

    private var elapsedTime: Double {
        max(CACurrentMediaTime() - startedAt, 0)
    }

    /// Video-normalized point, y down. NOT clamped: positions outside the
    /// captured area are kept (within a margin) so the rendered cursor can
    /// leave the frame naturally instead of sticking to its edge.
    private func normalizedPoint(for screenPoint: NSPoint) -> CGPoint {
        guard captureRect.width > 0, captureRect.height > 0 else { return CGPoint(x: -1, y: -1) }
        let x = (screenPoint.x - captureRect.minX) / captureRect.width
        let y = 1 - ((screenPoint.y - captureRect.minY) / captureRect.height)
        return CGPoint(x: min(max(x, -0.5), 1.5), y: min(max(y, -0.5), 1.5))
    }
}
