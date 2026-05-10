# Changelog

## [0.12.0-beta] - 2026-05-10

### Added
- **Image backdrops** — annotation exports can now use generated image-style backgrounds or a custom user-selected image.

### Changed
- **Editor shell polish** — the annotation editor has a refined stage, floating toolbar dock, compact background popovers, and cleaner toolbar spacing.

### Fixed
- **Editor controls** — numbered markers, color swatches, Background controls, and popover style switching now render cleanly without clipped labels or stale layout.

## [0.11.0-beta] - 2026-05-09

### Added
- **Presentation backdrops** — annotation exports can now include per-image solid or gradient backgrounds with padding, rounded corners, and shadows.

### Fixed
- **Editor export parity** — the annotation editor preview now matches saved and copied output when a backdrop is enabled.
- **Editor save flow** — save panels, copy feedback, and editor restoration are more reliable for the menu bar app lifecycle.
- **Screenshot file promises** — history and overlay drag exports now write PNG data atomically and report encoding failures.

## [0.10.2-beta] - 2026-05-03

### Added
- **Record Window previews** — the Record Window picker now shows premium window preview cards with app icons and clearer target details.

### Fixed
- **Record Window picker polish** — desktop/backstop windows are filtered out and the Select control no longer crowds the scrollbar edge.

## [0.10.1] - 2026-05-03

### Fixed
- **Recording retry** — stopping a recording now clears capture and writer state reliably, so back-to-back recordings and screenshots no longer get stuck.
- **Recording quality** — recordings now preserve Retina-scale capture dimensions and use higher encoder quality for sharper MP4 output.

## [0.10.0-beta] - 2026-05-03

### Added
- **Screen recording** — record an area, selected window, or fullscreen display directly from the menu bar.
- **Recording controls** — choose system audio, microphone input, cursor visibility, quality, and FPS before recording starts.
- **Live recording HUD** — draggable timer island with stop control, active audio state, and live microphone level feedback.

### Fixed
- **Window recording picker** — Record Window now shows a selectable ScreenCaptureKit window list instead of relying on an overlay that blocked clicks on other windows.
- **Recording setup safety** — recording actions are disabled while another recording setup or active recording is in progress.

## [0.9.9-beta] - 2026-05-02

### Added
- **QR code scanning** — scan a selected screen area for QR codes from the Tools menu.
- **Smart QR results** — recognized links, email, phone, SMS, Wi-Fi, and plain text payloads now show friendly fields and explicit actions.

## [0.9.8-beta] - 2026-05-02

### Changed
- **About links** — added Website and Report Issue links next to GitHub so beta users can quickly find the site, source, and issue tracker.
- **Welcome copy** — refreshed the first-launch description to mention annotation, OCR, scrolling capture, pinning, and local history.

## [0.9.7-beta] - 2026-05-01

### Fixed
- **Cmd-Tab visibility** — closing a Shotnix window no longer prematurely drops the app from Cmd-Tab when other Shotnix windows are still open. Replaced hardcoded `NSApp.setActivationPolicy(.prohibited)` calls across the annotation editor, preferences, welcome, history, pinned-window, area-selection, quick-access overlay, and shortcut-permission flows with a centralized helper that only restores background-only mode when no Shotnix windows remain.
- **Annotation editor layout** — the toolbar now reserves space for the macOS traffic-light buttons and enforces a minimum window width, so close/minimize/zoom no longer overlap toolbar controls.
- **Arrow rendering** — arrow shafts now stop short of the arrowhead by half the line width, removing the visible bulge at the tip on thick strokes.

### Changed
- **Multi-screen area capture** — simplified the per-screen freeze-frame capture loop (sequential capture in place of a `TaskGroup`); behavior unchanged but code is easier to follow.

### Internal
- New `ActivationPolicy.swift` helper extends `NSApplication` with `restoreBackgroundOnlyActivationPolicyIfNeeded(excluding:)`, the single source of truth for menu-bar-app activation lifecycle.

## [0.9.6-beta] - 2026-04-29

### Added
- **Fullscreen shortcut alias** — `Cmd + Shift + 3` now triggers Shotnix fullscreen capture when native macOS screenshot shortcuts are disabled, while `Cmd + Shift + 6` remains available.

### Fixed
- **Annotation undo correctness** — moving existing annotations now creates a proper undo checkpoint backed by deep-copied annotation snapshots.
- **Scrolling capture retry after cancel** — canceling scrolling-area selection no longer leaves the controller stuck active.
- **Desktop icon hiding preference** — “Hide desktop icons while capturing” now wraps capture flows and restores Finder state afterward.
- **WebP fallback safety** — unsupported WebP exports now fall back to a real `.png` file instead of writing PNG bytes to a `.webp` filename.

### Changed
- **Performance polish** — reduced annotation redraw work, throttled window-selection hit testing, avoided overlapping scrolling-capture frames, and moved drag file promises off the main queue.
- **Release packaging** — build signing now uses a committed entitlements file with hardened runtime options and no longer strips quarantine from the installed app.

## [0.9.5-beta] - 2026-04-25

### Added
- **Premium branding** — new app icon, menu bar icon, and first-launch welcome screen
- **Adaptive colors** — new `AdaptiveColors` utility for light/dark-aware UI tokens
- **Haptic feedback** — overlay and capture interactions emit subtle haptics on supported trackpads
- **Premium DMG installer** — dark graphite background with inline "INSTALL SHOTNIX" arrow, refined icon spacing, volume icon sourced from `Branding/Shotnix.icns` *(installer-only update; app binary unchanged)*

### Changed
- **Overlay animations** — snappier spring curves and pixel-perfect button alignment
- **Preferences UI** — fully modernized window controller, leaner code, cleaner layout
- **Capture engine** — refactored area/window selection and scrolling capture for clarity and stability
- **History panel** — refined controller and manager (better persistence, smoother grid)
- **Annotation editor** — polished toolbar interactions and window chrome

### Refactored
- **Native macOS APIs** — replaced legacy shell `Process()` calls with native equivalents
- Removed legacy `make-icon.swift` (icon now ships pre-generated under `Branding/`)

## [0.9.4-beta] - 2026-04-14

### Added
- **Numbered step counter annotation** — click-to-place incrementing numbered circles for tutorials and walkthroughs
- `NumberedStepAnnotation` with filled circle, white border, shadow, and centered bold number
- Auto-incrementing via scan of existing steps (`max + 1`); survives undo/redo/delete
- Cached text layout for draw performance
- SF Symbol toolbar icon (`1.circle.fill`) with forgiving circular hit testing

## [0.9.3-beta] - 2026-04-14

### Fixed
- **Annotation editor blank area** — canvas now centers in viewport when window is wider than the image
- **Annotation toolbar clutter** — removed always-visible Undo/Redo/Del buttons (keyboard shortcuts still work: ⌘Z, ⌘⇧Z, Delete); Crop✓ only appears when a crop region is drawn

### Changed
- **Quick access overlay** — refined shadow, corner radius (12px), frosted glass controls, white border for polish
- **Menu bar icon** — switched to `viewfinder` symbol with medium weight for sharper clarity
- **Annotation editor background** — dark gray backdrop instead of system gray for a professional editor feel
- **Overlay context menu** — added Delete option

## [0.9.2-beta] - 2026-04-12

### Fixed
- **Multi-display coordinates** — window capture and coordinate labels now correct on secondary screens
- **Screenshot color accuracy** — uses display's native calibrated ICC profile (matches CleanShot X)
- **DPI metadata** — removed incorrect pHYs chunk; CGImageDestination handles DPI naturally

### Added
- **WebP export** — save screenshots in WebP format (macOS 14+, falls back to PNG on older)
- **First-launch onboarding** — welcome window guides users to grant Screen Recording permission
- **After-capture auto-actions** — auto-copy to clipboard, auto-save to disk (configurable in Preferences)
- **Conditional overlay** — post-capture overlay respects "Show Overlay" preference

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
