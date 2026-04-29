import AppKit
import HotKey

/// Registers all global keyboard shortcuts.
@MainActor
final class HotkeyManager {

    private var hotkeys: [HotKey] = []

    func register(captureEngine: CaptureEngine, historyManager: HistoryManager) {
        // ⌘⇧4 — Capture Area (mirrors macOS default muscle memory)
        let area = HotKey(key: .four, modifiers: [.command, .shift])
        area.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startAreaCapture(historyManager: h) }
        }
        hotkeys.append(area)

        // ⌘⇧5 — Capture Window
        let win = HotKey(key: .five, modifiers: [.command, .shift])
        win.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startWindowCapture(historyManager: h) }
        }
        hotkeys.append(win)

        // ⌘⇧3 — Capture Fullscreen (macOS muscle memory; requires native shortcut disabled)
        let fullNative = HotKey(key: .three, modifiers: [.command, .shift])
        fullNative.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.captureFullscreen(historyManager: h) }
        }
        hotkeys.append(fullNative)

        // ⌘⇧6 — Capture Fullscreen (non-conflicting fallback)
        let full = HotKey(key: .six, modifiers: [.command, .shift])
        full.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.captureFullscreen(historyManager: h) }
        }
        hotkeys.append(full)

        // ⌘⇧7 — Capture Previous Area
        let prev = HotKey(key: .seven, modifiers: [.command, .shift])
        prev.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.capturePreviousArea(historyManager: h) }
        }
        hotkeys.append(prev)

        // ⌘⇧O — OCR Capture Text
        let ocr = HotKey(key: .o, modifiers: [.command, .shift])
        ocr.keyDownHandler = { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startOCRCapture() }
        }
        hotkeys.append(ocr)

        // ⌘⇧S — Scrolling Capture
        let scroll = HotKey(key: .s, modifiers: [.command, .shift])
        scroll.keyDownHandler = { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startScrollingCapture(historyManager: h) }
        }
        hotkeys.append(scroll)
    }
}
