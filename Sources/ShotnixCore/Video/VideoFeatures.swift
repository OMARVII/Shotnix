import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Webcam

/// How the camera bubble sits on the video.
struct VideoWebcamSettings: Codable, Equatable {
    enum Anchor: String, Codable, CaseIterable, Identifiable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var id: String { rawValue }

        var title: String {
            switch self {
            case .topLeft: return "Top left"
            case .top: return "Top"
            case .topRight: return "Top right"
            case .left: return "Left"
            case .right: return "Right"
            case .bottomLeft: return "Bottom left"
            case .bottom: return "Bottom"
            case .bottomRight: return "Bottom right"
            }
        }

        /// Position on the frame, 0...1 with y down.
        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .topRight: return CGPoint(x: 1, y: 0)
            case .left: return CGPoint(x: 0, y: 0.5)
            case .right: return CGPoint(x: 1, y: 0.5)
            case .bottomLeft: return CGPoint(x: 0, y: 1)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            }
        }

        /// The anchor nearest a unit point (for drag-to-snap).
        static func nearest(to point: CGPoint) -> Anchor {
            allCases.min { a, b in
                hypot(a.unit.x - point.x, a.unit.y - point.y) < hypot(b.unit.x - point.x, b.unit.y - point.y)
            } ?? .bottomRight
        }
    }

    enum Shape: String, Codable, CaseIterable, Identifiable {
        case circle
        case square
        case rectangle
        /// Just you — no frame, the background removed.
        case cutout

        var id: String { rawValue }
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .square: return "Rounded"
            case .rectangle: return "Wide"
            case .cutout: return "Cutout"
            }
        }

        /// Width / height.
        var aspect: CGFloat {
            switch self {
            case .rectangle: return 4 / 3
            case .cutout: return 3 / 4
            default: return 1
            }
        }
    }

    /// What's behind you in the camera picture.
    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case original
        case blur
        /// Replaced with the video's own background.
        case remove

        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "Original"
            case .blur: return "Blur"
            case .remove: return "Remove"
            }
        }
    }

    static let sizeRange: ClosedRange<Double> = 0.12...0.5

    var visible = true
    /// Height as a fraction of the output's short side.
    var size = 0.26
    var anchor: Anchor = .bottomRight
    var shape: Shape = .circle
    /// Selfie view: flipped like a mirror.
    var mirror = true
    /// The bubble gets out of the way while the screen is zoomed in.
    var shrinkWhenZoomed = true
    var backdrop: Backdrop = .original

    /// Person segmentation is needed for this look.
    var needsPersonMask: Bool { shape == .cutout || backdrop != .original }

    init() {}

    private enum CodingKeys: String, CodingKey { case visible, size, anchor, shape, mirror, shrinkWhenZoomed, backdrop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoWebcamSettings()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        anchor = (try? c.decode(Anchor.self, forKey: .anchor)) ?? d.anchor
        shape = (try? c.decode(Shape.self, forKey: .shape)) ?? d.shape
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        shrinkWhenZoomed = try c.decodeIfPresent(Bool.self, forKey: .shrinkWhenZoomed) ?? d.shrinkWhenZoomed
        backdrop = (try? c.decode(Backdrop.self, forKey: .backdrop)) ?? d.backdrop
    }
}

/// A stretch of the timeline where the camera takes a different layout.
struct VideoCameraLayoutRegion: Codable, Equatable, Identifiable {
    enum Layout: String, Codable, CaseIterable, Identifiable {
        /// The camera fills the frame (intros, outros, talking points).
        case fullscreen
        /// Screen on the left, camera on the right.
        case sideBySide
        /// No camera.
        case hidden

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fullscreen: return "Full camera"
            case .sideBySide: return "Side by side"
            case .hidden: return "Camera hidden"
            }
        }
        /// For narrow buttons.
        var shortTitle: String {
            switch self {
            case .fullscreen: return "Full camera"
            case .sideBySide: return "Side by side"
            case .hidden: return "Hidden"
            }
        }
        var symbol: String {
            switch self {
            case .fullscreen: return "person.crop.rectangle.fill"
            case .sideBySide: return "rectangle.split.2x1.fill"
            case .hidden: return "eye.slash.fill"
            }
        }
    }

    var id: UUID
    /// Source seconds.
    var start: Double
    var end: Double
    var layout: Layout

    init(id: UUID = UUID(), start: Double, end: Double, layout: Layout) {
        self.id = id
        self.start = start
        self.end = end
        self.layout = layout
    }

    static let minimumDuration = 0.8
}

/// The camera footage recorded alongside a screen recording.
struct VideoWebcamRecording: Codable, Equatable {
    var path: String
    /// Seconds the camera's first frame arrived after the screen's first
    /// frame (negative: before). Camera time = screen time − offset.
    var offset: Double
    var width: Double
    var height: Double

    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Captions

struct VideoCaptionWord: Codable, Equatable {
    var text: String
    /// Source seconds.
    var start: Double
    var end: Double
}

struct VideoCaptionLine: Codable, Equatable, Identifiable {
    var id: UUID
    /// Source seconds.
    var start: Double
    var end: Double
    var text: String
    /// Word timings for highlighting; dropped when the text is edited.
    var words: [VideoCaptionWord]

    init(id: UUID = UUID(), start: Double, end: Double, text: String, words: [VideoCaptionWord] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

enum VideoTextSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
    /// Font height as a fraction of the output's short side.
    var scale: CGFloat {
        switch self {
        case .small: return 0.032
        case .medium: return 0.04
        case .large: return 0.05
        }
    }
}

enum VideoTextPosition: String, Codable, CaseIterable, Identifiable {
    case bottom, top

    var id: String { rawValue }
    var title: String { self == .bottom ? "Bottom" : "Top" }
}

struct VideoCaptionStyle: Codable, Equatable {
    var visible = true
    var size: VideoTextSize = .medium
    var position: VideoTextPosition = .bottom
    /// Brightens each word as it's spoken.
    var highlightWords = true
    /// The look (see VideoCaptionStyles.swift).
    var preset: VideoCaptionPreset = .classic
    /// The spoken word's color (nil: the look's own).
    var highlightColor: VideoRGBA?

    init() {}

    private enum CodingKeys: String, CodingKey { case visible, size, position, highlightWords, preset, highlightColor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoCaptionStyle()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        size = (try? c.decode(VideoTextSize.self, forKey: .size)) ?? d.size
        position = (try? c.decode(VideoTextPosition.self, forKey: .position)) ?? d.position
        highlightWords = try c.decodeIfPresent(Bool.self, forKey: .highlightWords) ?? d.highlightWords
        preset = (try? c.decode(VideoCaptionPreset.self, forKey: .preset)) ?? d.preset
        highlightColor = try? c.decodeIfPresent(VideoRGBA.self, forKey: .highlightColor)
    }
}

// MARK: - Keyboard shortcuts

struct VideoKeystrokeEvent: Codable, Equatable, Identifiable {
    var id: UUID
    /// Source seconds.
    var time: Double
    /// Display labels, modifiers first: ["⌘", "⇧", "4"].
    var keys: [String]

    init(id: UUID = UUID(), time: Double, keys: [String]) {
        self.id = id
        self.time = time
        self.keys = keys
    }
}

struct VideoKeystrokeStyle: Codable, Equatable {
    var visible = true
    var size: VideoTextSize = .medium
    var position: VideoTextPosition = .bottom

    init() {}

    private enum CodingKeys: String, CodingKey { case visible, size, position }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoKeystrokeStyle()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        size = (try? c.decode(VideoTextSize.self, forKey: .size)) ?? d.size
        position = (try? c.decode(VideoTextPosition.self, forKey: .position)) ?? d.position
    }
}

// MARK: - Crop

/// The part of the recording that's kept, normalized with y down.
struct VideoCropRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = VideoCropRect(x: 0, y: 0, width: 1, height: 1)
    static let minimumSide = 0.08

    var isFull: Bool {
        abs(x) < 0.0005 && abs(y) < 0.0005 && abs(width - 1) < 0.0005 && abs(height - 1) < 0.0005
    }

    /// Clamped inside the frame with a minimum size.
    var normalized: VideoCropRect {
        let w = min(max(width, Self.minimumSide), 1)
        let h = min(max(height, Self.minimumSide), 1)
        return VideoCropRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// Source-normalized point → position inside the crop (0...1 inside).
    func map(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - CGFloat(x)) / CGFloat(max(width, 0.0001)), y: (point.y - CGFloat(y)) / CGFloat(max(height, 0.0001)))
    }

    /// Inverse of `map`.
    func unmap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: CGFloat(x) + point.x * CGFloat(width), y: CGFloat(y) + point.y * CGFloat(height))
    }

    /// Whether a source-normalized point survives the crop.
    func keeps(_ point: CGPoint) -> Bool {
        let inside = map(point)
        return inside.x >= -0.005 && inside.x <= 1.005 && inside.y >= -0.005 && inside.y <= 1.005
    }
}

extension VideoDemoProject {
    /// Recorded clicks the crop keeps (ripples and Auto Zoom ignore the rest).
    var clicksInsideCrop: [VideoDemoClickEvent] {
        let crop = self.crop.normalized
        return crop.isFull ? clickEvents : clickEvents.filter { crop.keeps(CGPoint(x: $0.x, y: $0.y)) }
    }
}

// MARK: - Keystroke capture

/// Turns key presses into shortcut labels — and ignores plain typing, so
/// passwords and messages never end up in a recording.
enum VideoKeystrokeFormatter {
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 76: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// US-layout shifted symbols back to their key (⇧⌘4, not ⇧⌘$).
    private static let unshifted: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func keys(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> [String]? {
        let flags = modifiers.intersection([.control, .option, .shift, .command])
        let special = specialKeys[keyCode]
        let isFunctionKey = special?.hasPrefix("F") == true && special != nil
        let isEscape = keyCode == 53
        // ⌥ alone types characters on many layouts (@ on German, ł and ó
        // on Polish): with a character key it's typing, not a shortcut.
        // Only ⌘ or ⌃ make a character key a shortcut; ⌥ counts with keys
        // that type nothing (arrows, Delete, Return, Tab).
        let hasShortcutModifier = !flags.intersection([.control, .command]).isEmpty
        let optionWithNonCharacter = flags.contains(.option) && special != nil && keyCode != 49
        // Plain typing (letters, Return, arrows, Delete…) is never recorded.
        guard hasShortcutModifier || optionWithNonCharacter || isFunctionKey || isEscape else { return nil }

        var labels: [String] = []
        if flags.contains(.control) { labels.append("⌃") }
        if flags.contains(.option) { labels.append("⌥") }
        if flags.contains(.shift) { labels.append("⇧") }
        if flags.contains(.command) { labels.append("⌘") }

        if let special {
            labels.append(special)
        } else if let characters, let first = characters.first {
            labels.append(unshifted[first] ?? String(first).uppercased())
        } else {
            return nil
        }
        return labels
    }

    /// Whether macOS lets Shotnix see key presses in other apps.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS for the permission (opens the system prompt).
    @discardableResult
    static func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
