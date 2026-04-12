# Changelog

## [0.9.1-beta] - 2026-04-12

### Fixed
- **Screenshot quality** — pixel-perfect captures with no CoreGraphics resampling blur
- Correct DPI metadata in PNG/JPEG exports (144 DPI on Retina, 72 on 1x)
- Timestamped filenames — "Shotnix 2026-04-12 at 10.30.48" (prevents conflicts)
- Preferences, history, and annotation windows not coming to front
- Crash guard for empty screen arrays in fullscreen capture
- Async overlay dealloc race in area selection focus callbacks
- Double cleanup race in quick access overlay dismiss
- Silent data loss on disk write failure in history manager
- History panel now restores background-only activation policy on close

### Added
- Auto-detect and disable conflicting macOS native screenshot shortcuts on first launch

## [0.9.0-beta] - 2025-04-08

### Added
- Area, window, fullscreen, previous area, scrolling, and OCR capture
- Full annotation editor with 12 tools (arrows, rectangles, ellipses, lines, freehand, text, highlighter, blur, pixelate, numbered markers, crop)
- Quick access overlay after every capture with copy, save, edit, pin actions
- Keyboard shortcuts on overlay (Cmd+C, Cmd+S, Cmd+E, Escape)
- Right-click context menu on overlay
- Pin screenshots to float on desktop
- Capture history with persistent grid browser
- Global hotkeys (Cmd+Shift+4/5/6/7/O/S)
- Tabbed settings window (General, Shortcuts, Screenshots, About)
- 9 configurable settings (sounds, format, save location, after-capture actions)
- What's New changelog in About tab
- Launch at login support
- Drag-and-drop from overlay to Finder/apps
- Toast notifications for OCR feedback
- Capture flash animation
- Desktop icon hiding during capture

### Known Limitations
- Not notarized (Gatekeeper warning on first launch)
- Multi-display capture coordinates may be incorrect on secondary screens
- Hotkeys are not customizable
- No auto-update mechanism
