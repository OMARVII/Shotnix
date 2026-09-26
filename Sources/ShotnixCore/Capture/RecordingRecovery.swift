import AVFoundation
import Foundation

/// A note left on disk while a recording runs. If Shotnix dies before it is
/// cleared (crash, force quit, power loss), the next launch finds it. The
/// movie itself survives — it's written in fragments — so recovery only
/// has to reattach the camera and point the user at the file.
struct RecordingRecoveryNote: Codable, Equatable {
    var videoPath: String
    var cameraPath: String?
    /// Camera time = screen time − offset, once both first frames arrived.
    var cameraOffset: Double?
    var fps: Int
    var nativeCursorVisible: Bool
    var audioTracks: [VideoAudioKind]?
    var startedAt: Date
}

enum RecordingRecovery {
    static func noteURL(baseDirectory: URL? = nil) -> URL {
        (baseDirectory ?? VideoStorageLocation.root)
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("InterruptedRecording.json")
    }

    static func save(_ note: RecordingRecoveryNote, baseDirectory: URL? = nil) {
        let url = noteURL(baseDirectory: baseDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(note).write(to: url, options: .atomic)
        } catch {
            print("[Shotnix] Recording recovery note failed: \(error)")
        }
    }

    static func load(baseDirectory: URL? = nil) -> RecordingRecoveryNote? {
        guard let data = try? Data(contentsOf: noteURL(baseDirectory: baseDirectory)) else { return nil }
        return try? JSONDecoder().decode(RecordingRecoveryNote.self, from: data)
    }

    static func clear(baseDirectory: URL? = nil) {
        try? FileManager.default.removeItem(at: noteURL(baseDirectory: baseDirectory))
    }

    /// Clears the note only if it's `video`'s: a take finishing late must
    /// never delete the note of the next one, already recording.
    static func clear(ifFor video: URL, baseDirectory: URL? = nil) {
        guard let note = load(baseDirectory: baseDirectory), note.videoPath == video.path else { return }
        clear(baseDirectory: baseDirectory)
    }

    /// Launch-time check: returns the interrupted recording when it plays,
    /// with its camera reattached; an unplayable leftover is deleted.
    static func recoverInterruptedRecording(baseDirectory: URL? = nil) async -> URL? {
        guard let note = load(baseDirectory: baseDirectory) else { return nil }
        clear(baseDirectory: baseDirectory)
        let video = URL(fileURLWithPath: note.videoPath)
        let camera = note.cameraPath.map { URL(fileURLWithPath: $0) }
        guard let duration = await playableDuration(of: video), duration > 0.2 else {
            try? FileManager.default.removeItem(at: video)
            if let camera { try? FileManager.default.removeItem(at: camera) }
            return nil
        }
        // Finishing normally writes the sidecar and clears the note; a
        // sidecar here means it was written after all.
        guard VideoDemoSidecarStore.load(for: video, baseDirectory: baseDirectory) == nil else { return video }

        let size = await videoSize(of: video) ?? .zero
        var metadata = VideoDemoRecordingMetadata(
            videoURLPath: video.path,
            createdAt: note.startedAt,
            duration: duration,
            sourceWidth: Double(max(size.width, 1)),
            sourceHeight: Double(max(size.height, 1)),
            fps: note.fps,
            nativeCursorVisible: note.nativeCursorVisible,
            cursorSamples: [],
            clickEvents: []
        )
        // The pointer path lived in memory: nothing to draw.
        metadata.renderCursor = false
        metadata.audioTracks = note.audioTracks
        if let camera, let offset = note.cameraOffset,
           await playableDuration(of: camera) != nil,
           let cameraSize = await videoSize(of: camera) {
            metadata.webcam = VideoWebcamRecording(path: camera.path, offset: offset, width: Double(cameraSize.width), height: Double(cameraSize.height))
        } else if let camera {
            try? FileManager.default.removeItem(at: camera)
        }
        VideoDemoSidecarStore.save(metadata, for: video, baseDirectory: baseDirectory)
        return video
    }

    /// Seconds of playable movie, or nil when the file can't be read.
    static func playableDuration(of url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    private static func videoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        return size
    }
}
