import AppKit
import KeyboardShortcuts

/// Registers all global keyboard shortcuts.
@MainActor
final class HotkeyManager {

    func register(captureEngine: CaptureEngine, historyManager: HistoryManager) {
        KeyboardShortcuts.removeAllHandlers()

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureArea) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startAreaCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureWindow) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startWindowCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureFullscreenNative) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.captureFullscreen(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureFullscreenFallback) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.captureFullscreen(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCapturePreviousArea) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.capturePreviousArea(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureText) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startOCRCapture() }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixCaptureScrolling) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startScrollingCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixRecordArea) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startAreaRecording() }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixRecordWindow) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startWindowRecording() }
        }

        KeyboardShortcuts.onKeyDown(for: .shotnixRecordFullscreen) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startFullscreenRecording() }
        }

        // Always registered — CaptureEngine.stopRecording() shows a
        // "No recording in progress" toast when nothing is being recorded.
        KeyboardShortcuts.onKeyDown(for: .shotnixStopRecording) { [weak captureEngine] in
            captureEngine?.stopRecording()
        }
    }

    static func resetDefaults() {
        KeyboardShortcuts.reset(ShotnixShortcut.allNames)
    }
}
