import KeyboardShortcuts

enum ShotnixShortcutSection: String {
    case screenshots = "Screenshots"
    case tools = "Advanced Tools"
    case recording = "Recording"
}

enum ShotnixShortcut: CaseIterable, Identifiable {
    case captureArea
    case captureWindow
    case captureFullscreenNative
    case captureFullscreenFallback
    case capturePreviousArea
    case captureTimed
    case captureText
    case captureScrolling
    case openCommandCenter
    case recordArea
    case recordWindow
    case recordFullscreen
    case stopRecording
    case pauseRecording

    var id: String { name.rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreenNative: return "Capture Fullscreen"
        case .captureFullscreenFallback: return "Capture Fullscreen Alt"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureTimed: return "Timed Capture"
        case .captureText: return "OCR / Capture Text"
        case .captureScrolling: return "Scrolling Capture"
        case .openCommandCenter: return "Open Command Center"
        case .recordArea: return "Record Area"
        case .recordWindow: return "Record Window"
        case .recordFullscreen: return "Record Fullscreen"
        case .stopRecording: return "Stop Recording"
        case .pauseRecording: return "Pause / Resume Recording"
        }
    }

    var section: ShotnixShortcutSection {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreenNative, .captureFullscreenFallback, .capturePreviousArea, .captureTimed:
            return .screenshots
        case .captureText, .captureScrolling, .openCommandCenter:
            return .tools
        case .recordArea, .recordWindow, .recordFullscreen, .stopRecording, .pauseRecording:
            return .recording
        }
    }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .captureArea: return .shotnixCaptureArea
        case .captureWindow: return .shotnixCaptureWindow
        case .captureFullscreenNative: return .shotnixCaptureFullscreenNative
        case .captureFullscreenFallback: return .shotnixCaptureFullscreenFallback
        case .capturePreviousArea: return .shotnixCapturePreviousArea
        case .captureTimed: return .shotnixCaptureTimed
        case .captureText: return .shotnixCaptureText
        case .captureScrolling: return .shotnixCaptureScrolling
        case .openCommandCenter: return .shotnixOpenCommandCenter
        case .recordArea: return .shotnixRecordArea
        case .recordWindow: return .shotnixRecordWindow
        case .recordFullscreen: return .shotnixRecordFullscreen
        case .stopRecording: return .shotnixStopRecording
        case .pauseRecording: return .shotnixPauseRecording
        }
    }

    /// The assigned keys ("⌥⌘P"), nil while unassigned.
    @MainActor
    var assignedShortcutText: String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

    static var allNames: [KeyboardShortcuts.Name] {
        allCases.map(\.name)
    }
}

extension KeyboardShortcuts.Name {
    static let shotnixCaptureArea = Self("captureArea", default: KeyboardShortcuts.Shortcut(.four, modifiers: [.command, .shift]))
    static let shotnixCaptureWindow = Self("captureWindow", default: KeyboardShortcuts.Shortcut(.five, modifiers: [.command, .shift]))
    static let shotnixCaptureFullscreenNative = Self("captureFullscreenNative", default: KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift]))
    static let shotnixCaptureFullscreenFallback = Self("captureFullscreenFallback", default: KeyboardShortcuts.Shortcut(.six, modifiers: [.command, .shift]))
    static let shotnixCapturePreviousArea = Self("capturePreviousArea", default: KeyboardShortcuts.Shortcut(.seven, modifiers: [.command, .shift]))
    // Timed capture ships unassigned — users opt in via Preferences → Shortcuts.
    static let shotnixCaptureTimed = Self("captureTimed")
    static let shotnixCaptureText = Self("captureText", default: KeyboardShortcuts.Shortcut(.o, modifiers: [.command, .shift]))
    static let shotnixCaptureScrolling = Self("captureScrolling", default: KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift]))
    // Ships unassigned — the rescue hatch for menu bars so full that macOS
    // hides the Shotnix icon entirely.
    static let shotnixOpenCommandCenter = Self("openCommandCenter")
    // Recording shortcuts ship unassigned — users opt in via Preferences → Shortcuts.
    static let shotnixRecordArea = Self("recordArea")
    static let shotnixRecordWindow = Self("recordWindow")
    static let shotnixRecordFullscreen = Self("recordFullscreen")
    static let shotnixStopRecording = Self("stopRecording")
    static let shotnixPauseRecording = Self("pauseRecording")
}
