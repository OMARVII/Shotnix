# Changelog

## [Unreleased]

### Added
- **Recording hotkeys** — Record Area, Record Window, Record Fullscreen, and Stop Recording can now be assigned global shortcuts in a new Recording section of the Shortcuts preferences, and Escape stops a recording in progress.
- **Fullscreen display chooser** — on multi-monitor setups, fullscreen screenshot now asks which display to capture, including an All Displays option; single-display capture is instant as before.
- **Custom file names** — a new File Name template in Screenshots preferences (date/time tokens with live preview) names every screenshot, recording, and drag export.
- **Copy Text on the overlay** — extract text from a capture directly from the post-capture thumbnail, and click the post-save toast to reveal the saved file in Finder.
- **All barcode types** — barcode scanning now decodes Code 128, EAN, UPC, Aztec, Data Matrix, PDF417 and more (not just QR), and names the detected type in the results window.
- **Annotation editor upgrades** — pinch/⌘+/⌘−/⌘0 canvas zoom with fit-to-window, Shift/Option drawing constraints (squares, circles, 45° arrows, draw-from-center), arrow-key nudging, ⌘S/⌘C/Escape shortcuts, and the editor now remembers your last tool, color, and line width.
- **Video editor transport** — frame-step (,/.), 1-second jumps (Shift+arrows), Home/End, and J/K/L shuttle controls, with shortcuts listed in the command palette.
- **Edit menu** — standard Edit and Window menus so ⌘X/⌘C/⌘V/⌘A/⌘Z work in text fields and save panels.

### Changed
- **Post-capture UI follows the capture** — the quick-access overlay, toasts, and pinned screenshots now appear on the display where the capture happened, and pins open at the exact spot that was captured.
- **The video "Blur" effect is now "Redact"** — it was always an opaque cover, not a blur; it is now named honestly, fully opaque, and holds hard on/off in exports (no fade leaking the covered content).
- **Preview audio matches export** — muted clips and fade ramps are now silent/ramped during editor preview, and export reports audio problems instead of silently dropping tracks.
- **Captures exclude Shotnix** — pinned screenshots, toasts, and HUDs no longer appear inside new captures.

### Fixed
- **Recordings survive errors** — if the screen-capture stream dies mid-recording (display disconnect, sleep), Shotnix now saves everything captured so far instead of discarding the file; disk-full is detected immediately, and recording refuses to start when the disk is critically low.
- **Clipboard safety** — a failed or empty text extraction no longer erases what you had copied, with distinct messages for "failed" vs "no text found".
- **Permission recovery** — the Screen Recording permission alert now offers Open System Settings and Quit & Reopen instead of a dead-end Quit.
- **Cursor timing in the video editor** — click ripples and cursor motion no longer render late relative to the video.
- **Magnifier accuracy** — the selection loupe now samples the correct pixels on secondary and Retina displays.
- **Multi-display selection speed** — the capture crosshair appears faster on multi-monitor setups (screens are snapshotted in parallel).
- **Shortcut-conflict prompt** — declining the Apple-shortcuts takeover is now remembered, and a Restore Apple Shortcuts button was added to preferences.
- **Menu bar icon preference** — the "Show menu bar icon" toggle now works, with a confirmation explaining how to get back (relaunching opens Preferences).

## [0.17.4-beta] - 2026-06-09

### Added
- **Cursor polish pack** — the video editor gains an adjustable cursor size slider, a click spotlight that dims the frame around each click, and an optional motion-blur trail that smears fast cursor moves while keeping slow moves crisp.

### Changed
- **Editors stay reachable** — opening a photo or video editor now gives Shotnix a Dock icon and a ⌘-Tab entry, so you can switch to another app and always return to the editor. The Dock icon appears while either editor is open and disappears once the last one closes; clicking it restores a minimized editor.

## [0.17.3-beta] - 2026-06-08

### Added
- **Video Demo Editor** — recordings can open into a dedicated video editor with a preview stage, frame presets, backgrounds, trim, and MP4 export.
- **Clip timeline** — split at playhead, delete, ripple delete, undo/redo, and selected-clip trim, with a ruler, video/audio track, zoom lane, trim handles, and a full-height playhead.
- **Per-segment speed controls** — 0.5x, 1x, 1.5x, and 2x per clip, plus clip mute and fade-in/fade-out while preserving recorded audio tracks.
- **Premium effects** — text labels, arrows, highlights, and blur boxes exported as callout layers, with auto zoom presets, effect lane markers, smoother cursor interpolation, and social export polish.
- **Command Center video actions** — open a video file or reopen the last recording directly from the menu bar.

### Changed
- **Export pipeline** — exports now stitch multi-segment compositions with cuts, speed, audio, cursor, and zoom mapping into a single MP4.

## [0.16.0-beta] - 2026-05-31

### Added
- **Command Center** — the menu bar dropdown is now an editor-inspired Shotnix command surface with compact groups for health, capture, recording, tools, utilities, and settings.
- **Health status** — Shotnix now surfaces Screen Recording permission, Apple shortcut conflicts, Sparkle updates, save folder writability, shortcut configuration, and current version/build from the menu bar.

### Changed
- **Modern context menus** — Quick Access, History, and pinned screenshot right-click menus now use the shared premium HUD style with icons, grouping, keyboard navigation, and destructive action styling.
- **Modern preferences** — Preferences now use the same compact HUD visual system, with centered tab navigation, consistent dark surfaces, and custom selector controls.
- **Command Center polish** — Capture Area is visually promoted, Health is more compact, settings actions stay pinned in the footer, and recording setup exposes a clear Cancel Recording action.

### Fixed
- **Recording menu state** — Stop Recording now becomes available during active recordings, while recording setup can be cancelled directly from Command Center.

## [0.15.4-beta] - 2026-05-18

### Changed
- **Quick Access thumbnails** — the post-capture thumbnail now keeps a consistent card size while showing the full screenshot over a darker blurred backdrop for a more premium preview.

### Fixed
- **DisplayLink screenshots** — still captures that come back effectively black now retry through a one-frame ScreenCaptureKit stream path, matching the capture route that works on DisplayLink displays.

## [0.15.3-beta] - 2026-05-17

### Added
- **Bundled capture sound** — screenshot captures now use a bundled Shotnix sound effect instead of relying on a macOS system sound ID.

### Fixed
- **Release sound packaging** — the app bundle now includes SwiftPM resources so the capture sound ships with signed builds.

## [0.15.2-beta] - 2026-05-16

### Fixed
- **Quick Access drag-and-drop** — dragging the post-capture thumbnail now exports reliably to Finder and other apps.
- **Overlay action buttons** — Copy and Save remain clickable while thumbnail drag-and-drop stays available from non-button areas.

## [0.15.1-beta] - 2026-05-16

### Changed
- **Annotation editor launch size** — the editor now opens larger by default so captured images start with less scrolling on normal MacBook and desktop displays.
- **Small-screen sizing safety** — the editor still caps its minimum window size to the visible display, preventing oversized windows on accessibility-scaled or low-resolution screens.

### Fixed
- **Crop apply button** — the Crop confirmation button now has enough toolbar width to appear fully instead of clipping at the right edge.

## [0.15.0-beta] - 2026-05-15

### Added
- **First-run onboarding** — Shotnix now guides Screen Recording permission setup and follows with a native shortcut conflict prompt.
- **Ready confirmation** — after setup is complete, Shotnix shows a menu-bar anchored “Shotnix is ready to use!” confirmation.

### Changed
- **Native screenshot shortcuts** — Shotnix can disable conflicting macOS screenshot shortcuts across user and host preference scopes before registering its own capture hotkeys.
- **Overlay default position** — the quick-access thumbnail now defaults to the left side for fresh installs while preserving existing user preferences.

### Fixed
- **Permission handoff** — Screen Recording prompts no longer mark onboarding complete before macOS has registered the permission flow.

## [0.14.1-beta] - 2026-05-14

### Changed
- **Overlay Save flow** — the quick-access Save action now writes directly to the configured Save Location and uses the same immediate confirmation flow as Copy.
- **Record Window quality** — window recordings now use the sharper display-crop pipeline while targeting only the selected window.

## [0.14.0-beta] - 2026-05-12

### Changed
- **Default screenshot copy** — new screenshots are now copied to the clipboard by default, with a Screenshots preference to disable automatic copying.

## [0.13.0-beta] - 2026-05-11

### Changed
- **Capture History redesign** — the history panel now uses a premium dark-glass layout, compact four-column capture cards, smoother preview framing, and refined hover/card polish.

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
