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
    case captureText
    case captureScrolling
    case recordArea
    case recordWindow
    case recordFullscreen
    case stopRecording

    var id: String { name.rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreenNative: return "Capture Fullscreen"
        case .captureFullscreenFallback: return "Capture Fullscreen Alt"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureText: return "OCR / Capture Text"
        case .captureScrolling: return "Scrolling Capture"
        case .recordArea: return "Record Area"
        case .recordWindow: return "Record Window"
        case .recordFullscreen: return "Record Fullscreen"
        case .stopRecording: return "Stop Recording"
        }
    }

    var section: ShotnixShortcutSection {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreenNative, .captureFullscreenFallback, .capturePreviousArea:
            return .screenshots
        case .captureText, .captureScrolling:
            return .tools
        case .recordArea, .recordWindow, .recordFullscreen, .stopRecording:
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
        case .captureText: return .shotnixCaptureText
        case .captureScrolling: return .shotnixCaptureScrolling
        case .recordArea: return .shotnixRecordArea
        case .recordWindow: return .shotnixRecordWindow
        case .recordFullscreen: return .shotnixRecordFullscreen
        case .stopRecording: return .shotnixStopRecording
        }
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
    static let shotnixCaptureText = Self("captureText", default: KeyboardShortcuts.Shortcut(.o, modifiers: [.command, .shift]))
    static let shotnixCaptureScrolling = Self("captureScrolling", default: KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift]))
    // Recording shortcuts ship unassigned — users opt in via Preferences → Shortcuts.
    static let shotnixRecordArea = Self("recordArea")
    static let shotnixRecordWindow = Self("recordWindow")
    static let shotnixRecordFullscreen = Self("recordFullscreen")
    static let shotnixStopRecording = Self("stopRecording")
}
