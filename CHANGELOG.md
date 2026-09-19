# Changelog

## [0.21.1-beta] - 2026-09-19

### Changed
- **The Select tool got a proper pointer icon** — the old diagonal-arrows glyph read as "resize", so nobody recognized it as Select.

### Fixed
- **Switching tools no longer spawns a surprise text annotation** — an in-progress text field from the Text tool used to stay open across a tool switch and silently commit on the next canvas click, so clicking with Select appeared to create a text out of nowhere. The field now commits (or, if empty, disappears) the moment the tool changes.

## [0.21.0-beta] - 2026-09-19

### Added
- **Recorded clicks are now editable** — a new Clicks lane on the editor timeline shows every recorded click: tap a marker to select it (and jump there), drag to retime it, press Delete to remove it (undoable). Ripples, spotlights, and the next Auto Zoom run follow the edited list.
- **Preview mute button** — a speaker toggle next to the timeline zoom controls silences the editor preview while you review a recording. It never touches the export audio or per-clip mutes. Press M (with no clip selected) to toggle it from the keyboard.
- **Callouts are editable right on the video stage** — highlight, arrow, text, and redact overlays were render-only: clicking one just seeked the video, and position/size could only be nudged from inspector sliders. Now clicking a callout selects it (dashed border + corner handles), dragging moves it, dragging a corner resizes it with the opposite corner anchored, and Delete removes it — each gesture is a single undo step, clamped to the stage, and the preview position matches the export exactly.
- **Effects lane shows duration pills** — each callout is now a color-coded block spanning exactly when it's on screen, instead of a dot at its start time. Drag the pill to move the whole window, drag either edge grip to set when it appears and disappears (snapping to clips, clicks, and other effects), click to select and jump there. One undo step per gesture; timing survives cuts and clip speed changes because windows are stored in source time.

### Removed
- **Copy-video-path button** — the doc-on-doc icon next to Reveal Video in the editor header copied the raw source file path, which nobody needs; Reveal in Finder covers the real use case.

### Changed
- **Timeline redesigned as a pro editing surface** — the boxy per-lane containers and label column are gone; the timeline is now a flat surface with self-describing blocks. Zoom moves are labeled blocks ("1.8×") you drag directly, with compact "1×" chips where the camera resets; callouts are color-coded duration pills; clicks are dots on a hairline; and the big clip strip anchors the bottom under a cleaner ruler and a proper playhead grabber. Rows appear only when they have content, so a simple recording gets a simple timeline, and every marker explains itself on hover.
- **Timeline drags are now precise and undoable** — dragging a zoom block or click dot used to compound its own movement mid-drag (the further you dragged, the faster it ran away) and left nothing on the undo stack. Drags now measure from the gesture's origin and each full drag is exactly one ⌘Z step.
- **Dragging no longer shakes** — while an object moved, snapping still counted the object's own start/end as snap targets, so every tick pulled it back toward where it already was and the drag visibly juddered. A dragged object's own snap points are now excluded; snapping to clips, clicks, and *other* effects still works.
- **Callouts live on real timeline lanes** — overlapping effects used to render on top of each other; now each callout has its own lane, and you can drag a pill up or down to move it to another lane deliberately. Lanes are stable while you drag horizontally (no more re-shuffling under the cursor — the source of the shaking and flashing), conflicts spread onto free lanes and empty lanes compact away when you let go, and the timeline grows to fit. Old drafts pick up lanes automatically on load.
- **Annotations are grabbable with any tool** — clicking an existing highlight, arrow, box, or step while a drawing tool is active now selects and moves it (with resize/endpoint handles), instead of silently drawing a new shape on top — no need to find the Select tool first. Newly drawn annotations select themselves so their handles are visible immediately. Drawing still starts anywhere that isn't an object; freehand always draws, and the text/step tools only grab their own kind so you can still place labels inside shapes.
- **The annotation editor shows you what's draggable** — hovering any annotation outlines it faintly and switches the pointer to an open hand (closed hand while dragging, resize arrows over edge handles, a pointing hand over arrow/line endpoints). Double-clicking a text annotation reopens it for editing in place, keeping its color and size — clearing the text deletes it. The first click into an unfocused editor window now acts immediately instead of just focusing the window.

### Fixed
- **Pressing ⌘X/⌘C with the post-capture thumbnail focused froze the entire app** — the Edit menu's key replay could bounce a shortcut back into menu routing forever when a window was its own key responder, livelocking the main thread until force-quit. The replay now refuses window-as-responder targets and guards against re-entry.
- **Shotnix can screenshot its own windows again** — excluding the app's floating chrome (toasts, overlays, pins) from captures also made the video editor, annotation editor, history, and preferences windows invisible to screenshots. Real titled windows are now excepted back into the capture; only the chrome stays excluded.
- **Area recordings no longer look blurry in the editor and exports** — small recordings (especially from non-Retina displays) were stretched to fill a fixed 1920×1080 canvas, and auto-zoom magnified the stretch further. The canvas now shrinks to match small sources so the video renders at native 1:1 pixels; large captures keep the full canvas as before.
- **Capture feedback appears before you move the mouse** — pressing a capture hotkey now immediately shows the crosshair (or the window highlight) at the cursor's current position and switches the pointer to a crosshair. Previously everything waited for the first mouse movement, so a stationary user saw nothing and assumed capture hadn't started.

## [0.20.5-beta] - 2026-09-14

### Added
- **Menu bar overflow rescue** — on crowded menu bars (especially notched MacBooks) macOS silently hides status icons, and Shotnix looked like it never launched. Now the app detects it: a one-time toast explains the icon is hidden and that hotkeys still work (click it for the menu), relaunching the app from Spotlight/Finder opens the command center as a floating panel instead of doing nothing, and a new assignable "Open Command Center" shortcut summons the menu without the icon at all.

## [0.20.4-beta] - 2026-09-14

### Changed
- **Command center opens instantly** — the menu's interface is built once at launch and reused (instead of rebuilt on every open), and the popover's sluggish zoom animation is gone: click the icon and the menu is simply there. Problem tiles carry proper warning badges (yellow triangle / red octagon) with state-tinted styling instead of a recolored feature icon.
- **Command center slimmed down and smoothed out** — the Health section collapses to a single quiet "Everything is ready" line when nothing needs attention, and problem tiles now span the full menu width so nothing truncates ("Apple Sho…", "Conflict det…", "Updat…" are gone). The always-disabled Cancel Recording row and closed-editor rows are hidden until they're actionable, Capture All Displays no longer takes a menu row, and the thick legacy scrollbar is gone for good — the menu scrolls bar-free with native elastic feel and soft edge fades (an AppKit-level fix, since macOS ignores SwiftUI's indicator hiding whenever a mouse is connected).

### Fixed
- **Exported cursor now follows the recorded timestamps** — with Smooth Cursor on, exports animated the cursor in "paced" mode, which ignores keyframe timing entirely and drifted the cursor uniformly across the clip, out of sync with clicks, zooms, and the preview. Smoothing now uses cubic interpolation that honors the real timeline. Found by frame-diffing a real exported file against the editor preview.
- **Export save panel default filename** no longer reads "Shotnix Demo Shotnix …".

## [0.20.3-beta] - 2026-09-14

### Fixed
- **Health no longer nags about optional shortcuts** — the menu bar Health tile showed a permanent yellow "7/12 configured · Fix" because Timed Capture and the four Recording shortcuts ship unassigned by design. Opt-in shortcuts no longer count against health: a fresh install now reads green "Ready · 5 optional off", and yellow only appears when a core shortcut with a factory default is actually missing.

## [0.20.2-beta] - 2026-09-14

### Changed
- **Post-capture thumbnail fills the card** — the quick-access preview now shows the capture edge-to-edge in a fixed-size card: center-cropped when the shape differs, zoomed to fill when the capture is small. Previews are pre-scaled with high-quality interpolation in the capture's own color space, so small text in menus and dialogs stays crisp instead of going soft.
- **Thumbnail floats higher** — the post-capture overlay now sits comfortably above the bottom edge of the screen instead of hugging the corner.

## [0.20.1-beta] - 2026-09-14

### Fixed
- **Zoom rebuilt on a single scene-camera model** — the editor preview and the export used two different zoom systems (the preview anchor-scaled the video in place, the export re-centered it), so the preview never showed where the camera was going and exports zoomed somewhere else. Both now share one model: the camera zooms the whole composed scene (background and video together), so the point you pick genuinely centers — the background fills the slack near edges — and black regions are impossible. The export animates the identical eased path the preview shows, sampled at 30Hz through cuts and speed changes.
- **Auto-zoom camera no longer darts** — the shot planner allowed transitions as short as 0.18 seconds and pumped the scale down and back up between nearby click bursts, producing quick, jerky camera actions. Every move now gets a real duration (zoom-ins 0.65s, pans 0.55–1.2s scaled by distance — settling a beat late instead of whipping), clicks close together on screen merge into one held shot instead of re-aiming the camera, back-to-back shots glide directly between focus points at hold scale, and zoom-outs are a single smooth motion instead of a two-step stutter.

## [0.20.0-beta] - 2026-09-13

### Added
- **Recordings open already produced** — a fresh recording now lands in the editor with auto-zoom applied: the camera zooms in and follows your recorded clicks with zero editing, ready to export. Undoable, tweakable in the Zoom panel, and can be turned off in Preferences → Recording.
- **GIF export** — the export panel now offers GIF alongside MP4: 15 fps, capped at 1280px wide, looping forever — the format READMEs, pull requests, and chat apps actually embed.
- **Export options** — format, frame rate (30/60 fps), and size (Full/Half) live in the export save panel and are remembered between exports.
- **"Made with Shotnix" end card** — an optional 1.6-second outro on MP4 exports (toggle in the export panel).

### Changed
- **Exports finally match the preview** — video exports now render the same gradient backgrounds the editor shows (instead of a flat color), respect the background blur slider, clip the video to the same rounded corners, and size text callouts with the same width-proportional formula as the preview.

### Fixed
- **Zoom can no longer reveal black beyond the video's edge** — zooming toward a click near a corner used to slide the video inward and expose empty black regions. The camera now clamps to the frame edge (in preview and export), so the zoomed view is always full content.

## [0.19.2-beta] - 2026-09-13

### Added
- **GitHub star nudge** — after the tenth screenshot, a one-time clickable toast asks "Enjoying Shotnix? Click to star it on GitHub". From then on a dismissible line sits at the top of the history panel with Star on GitHub and Not now; either choice retires the nudge for good. The count and state live in UserDefaults and nothing is sent anywhere.

## [0.19.1-beta] - 2026-09-13

### Fixed
- **The app crashed instantly on launch on every Mac except the machine it was built on** (reported as issue #25 against 0.18.0; present in all recent releases). SwiftPM's generated resource-bundle accessor only searched the .app root and the build machine's absolute `.build` path, so the capture-sound bundle lookup fatalErrored at startup for everyone else — local testing never caught it because the build-path fallback exists on the build machine. Shotnix now locates its resource bundle in `Contents/Resources` directly and degrades gracefully if it's missing. The KeyboardShortcuts dependency is vendored with the same one-line fix, since its localization lookup would have hit the identical crash in the Shortcuts preferences pane.

## [0.19.0-beta] - 2026-09-12

### Added
- **True window capture** — window mode now captures the clicked window itself (isolated, nothing overlapping bakes in) with optional CleanShot-style transparent padding and drop shadow (Preferences → Screenshots).
- **Timed capture** — select an area, then a cancellable 3/5/10-second countdown runs before the shot; in the menu, with an assignable shortcut, delay configurable in Preferences.
- **Space-drag selection** — holding Space while drag-selecting moves the selection instead of resizing it, matching the native macOS screenshot tool.
- **Menu bar recording indicator** — while recording, the menu bar icon becomes a red dot with a live elapsed timer; left-click stops the recording, right-click still opens the menu.
- **Setup checklist onboarding** — the welcome window is now a live three-step checklist (grant Screen Recording with Quit & Reopen built in, free up Apple's shortcuts, take a test screenshot). It tracks real state, reappears until setup is done or skipped, and finishes by pointing at the menu bar icon.
- **History search** — a search field in the history panel filters captures live by the text inside them (screenshots are OCR-indexed in the background) and by date.
- **Undo delete in history** — deleting a capture moves it to a trash kept for 7 days, with a click-to-undo toast; Clear All is undoable the same way.

### Changed
- **~80ms faster shutter** — the selection overlay no longer waits for the dimming to leave the screen before capturing (Shotnix's own windows are already excluded from captures on macOS 14+). Applies to area, OCR, and barcode captures.
- **Rock-solid recording pipeline** — video and audio buffers are now written on a dedicated queue instead of hopping through the main thread at up to 60fps. Recording no longer stutters or drops frames when you open the menu, hover UI, or the app is otherwise busy.
- **Smooth history scrolling** — grid thumbnails decode off the main thread with an in-memory cache, so scrolling a large library never hitches; the open panel also updates live when captures are added, deleted, or restored anywhere in the app.
- **Video editor scrubbing feels like a real editor** — dragging the playhead now uses chained, keyframe-tolerant seeks (exact on release), the 30Hz playback clock no longer re-renders the entire editor every tick, and timeline snap points are cached instead of recomputed per frame.
- **Screenshots no longer steal focus** — the post-capture overlay is now a non-activating panel: it slides in without interrupting typing in the app you're using. Hovering it engages ⌘C/⌘S/⌘E/Esc without activating Shotnix, and moving the mouse away hands keyboard focus straight back.
- **The crosshair appears instantly** — the selection overlay no longer waits for the frozen screen snapshots; they load in the background and only the magnifier loupe appears a beat later. Window-selection mode skips the snapshots entirely.
- **Smoother post-capture** — clipboard copy and auto-save now encode off the main thread, so the overlay's entrance animation no longer stutters on large captures.
- **Faster window captures** — the isolated window capture reuses the cached window list (refetching only when stale) instead of a fresh 30–100ms system query per shot.
- **⌘⇧3 fullscreen capture is instant again** — no display chooser: it immediately captures the display you're working on (where the mouse is). On multi-monitor setups, "Capture All Displays" is its own menu action.
- **Faster recording window picker** — window previews are captured in parallel instead of one at a time.
- **Choosers open where you are** — the display and window pickers appear on the screen with the mouse instead of always the main display.
- **All Displays capture plays one shutter sound** instead of one per screen.
- **Scrolling capture dedup** — duplicate frames are now detected with a small luminance fingerprint instead of comparing full frame buffers: faster, lighter, and it also catches near-duplicates (cursor blink) the old exact compare missed.

### Fixed
- **History grid corruption after deletes** — recycled tiles no longer carry stale hover effects, and the grid layout is properly invalidated after items are removed.
- **Window-mode selection on secondary displays** — clicking a highlighted window on a non-primary screen captured the wrong region (view-local vs global coordinates).

## [0.18.1-beta] - 2026-09-12

### Fixed
- **Black screenshots on external displays** — capturing an area, window, or fullscreen on a secondary monitor no longer produces an empty black image. The capture engine matched displays by comparing rectangles from two different coordinate systems (AppKit bottom-left vs CoreGraphics top-left), which only agree on the primary display; displays are now matched by their display ID. The same fix applies to screen recordings, scrolling capture, OCR/barcode capture, and the frozen selection preview.

## [0.18.0-beta] - 2026-07-18

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
