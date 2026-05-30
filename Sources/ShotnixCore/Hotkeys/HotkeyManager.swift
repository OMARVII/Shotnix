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
    }

    static func resetDefaults() {
        KeyboardShortcuts.reset(ShotnixShortcut.allNames)
    }
}
