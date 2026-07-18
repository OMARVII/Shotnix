# Shotnix Roadmap

Baseline: **v0.17.4-beta** · Generated from a full-source audit (all 42 Swift files, ~20k lines) on 2026-07-10.

**Ordering principle: easiest first.** Within each phase, items are sorted so the smallest effort with the highest impact ships first. Each phase is roughly one release. Check items off as they land; every item carries `file:line` evidence so a fresh session can jump straight in.

Effort key: **S** = hours to a day · **M** = 1–3 days · **L** = a week+

---

## Phase 1 — Quick-Fix Sprint (target: v0.18) — all Small effort

Everything here is shippable in one or two sessions. Do the reliability fixes first: they turn data loss into saved files.

### 1A. Reliability fixes (do these first)

- [x] **Salvage recordings when SCStream errors** — S / HIGH
  On display disconnect/sleep, `finishWriting` completes and a playable MP4 exists, but the error branch orphans it and shows "Recording stopped unexpectedly." Check `writerStatus == .completed` in the error branch and fall through to the success path with a softer toast.
  `RecordingEngine.swift:465-473`

- [x] **Stop OCR clobbering the clipboard on failure** — S / HIGH
  Vision errors and empty regions both return `""`, and the caller unconditionally does `clearContents()` + `setString`. Return an optional, only touch the pasteboard when text is non-empty, and split the "failed" vs "no text found" toasts.
  `OCREngine.swift:18-21, 35-38` · `CaptureEngine.swift:498-503, 707-711`

- [x] **Fix the permission-denied dead end** — S / HIGH
  `didRequestScreenRecordingPermission` is set before the result is known; denied users only ever see "quit and reopen" with a Quit button. Add "Open System Settings" and a Quit & Reopen that actually relaunches.
  `PermissionsManager.swift:13, 42-56`

- [x] **Exclude Shotnix's own windows from still captures** — S / MED
  `SCContentFilter(display:excludingWindows: [])` lets pinned shots, toasts, and the scrolling HUD appear inside new captures. The processID filter already exists for the recording picker — reuse it.
  `CaptureEngine.swift:612` (empty list) vs `:271` (existing filter)

- [x] **Surface capture failures** — S / MED
  `captureRect` guard-returns on nil with no toast or log; the SCK catch discards the error before a deprecated fallback that can also return nil. Add a "Capture failed" toast + `os_log` of the underlying error.
  `CaptureEngine.swift:546-547, 648-650, 658-661`

- [x] **Detect writer failure mid-recording + preflight disk space** — S / MED
  Disk-full puts the writer in `.failed` but the HUD timer keeps running; user learns only on stop. Check `writer.status` on append failure and finish immediately; add a `volumeAvailableCapacity` check in `startRecording`. Cap the unbounded pre-first-frame audio buffers while there.
  `RecordingEngine.swift:389-394, 746-756, 397-405`

- [x] **Fix cursor/click metadata timeline offset** — S / MED
  Metadata recording starts before `stream.startCapture()` returns, but video t=0 is the first delivered frame — every click ripple renders late in the editor. Offset metadata by the wall-clock time of the first appended frame.
  `RecordingEngine.swift:98-104, 377-379, 518-519` · `VideoDemoRecordingMetadata.swift:179, 231-233`

- [x] **Fix magnifier loupe on secondary displays** — S / MED
  The loupe crops per-screen images with *global* coordinates (wrong pixels + wrong hex readout on any non-primary display) and uses point-space rects against 2x pixel images. Convert to screen-local coords × backing scale; branch on `alphaInfo` for byte order.
  `AreaSelectionWindow.swift:252-271, 364-379`

- [x] **Show overlays/toasts on the display where capture happened** — S / MED
  `QuickAccessWindow.positionOverlay()`, `ToastWindow`, and `PinnedWindow.center()` all use `NSScreen.main`. The capture rect is already threaded through — derive the screen from it. Also fix the post-recording panel's hardcoded 7s close that ignores hover and `overlayTimeout`.
  `QuickAccessOverlay.swift:390` · `ToastWindow.swift:64, 146` · `PinnedWindow.swift:67` · `VideoDemoPostRecordingPanel.swift:97-104`

- [x] **Add an Edit menu + wire the dead "Show menu bar icon" toggle** — S / MED
  Without an Edit menu, ⌘X/C/V/A/Z have no responder route — breaks paste into text-annotation fields and save panels (classic LSUIElement gotcha). The General-pane menu-bar-icon toggle is read by nothing; wire it with an escape hatch (the status item is the app's only entry point).
  `AppDelegate.swift:98-126, 140-151` · `Settings.swift:68-74` · `PreferencesWindowController.swift:443-447`

- [x] **Stop the native-shortcut prompt nagging every launch** — S / MED
  `promptIfNeeded` removes its own "didPrompt" key whenever Apple's shortcuts are still enabled — declining users see the modal forever. Add decline-and-remember, dedupe the `killall cfprefsd` calls, get `waitUntilExit` off the main thread.
  `NativeShortcutManager.swift:77-79, 100-115, 120-128, 175-177`

- [x] **Preview audio: respect mute/fades, stop swallowing export audio errors** — S / MED
  Muted clips still play audio in preview (set `player.volume` per active segment in the existing time observer); export inserts audio with `try?`, so a failed insert yields a "successful" export with missing audio.
  `VideoDemoEditor.swift:1924, 983-1062, 998, 2769-2812`

- [x] **Rename video "Blur" effect → "Redact"** — S / MED (honesty fix; real blur is in Phase 4)
  The effect renders an opaque dark rectangle in preview *and* export — nothing is blurred. Users hiding secrets will assume pixel obfuscation. Rename now so behavior matches the label.
  `VideoDemoEditor.swift:100-124, 1468-1476, 4257-4265`

### 1B. Small features & polish

- [x] **Global hotkeys for start/stop recording + Escape on the HUD** — S / HIGH ← *single highest-value item in Phase 1*
  All seven shortcuts are still-capture; recording is mouse-only. The HUD sets `canBecomeKey = false` so even Escape can't stop it. Add `ShotnixShortcut` cases, `HotkeyManager` registrations, a Recording section in the Shortcuts pane, and a key path on the HUD.
  `HotkeyManager.swift:8-48` · `ShotnixShortcut.swift:8-16` · `RecordingHUDWindow.swift:92, 143-145` · `AppDelegate.swift:160-163, 239-250`

- [x] **Persist last-used annotation color, line width, and tool** — S / HIGH
  Editor always reopens on red arrow 3pt; the color popover resets to red each time. Add Settings keys, restore at init.
  `AnnotationCanvas.swift:19-20` · `AnnotationWindowController.swift:465, 516, 1145`

- [x] **Annotation editor shortcuts: ⌘S save, ⌘C copy, Escape cancel/deselect** — S / HIGH
  Save/Copy are toolbar-only (no main menu over an LSUIElement editor). Escape should cancel in-progress crop → clear selection → optionally close.
  `AnnotationCanvas.swift:839-875` · `AnnotationWindowController.swift:141-171, 204-219`

- [x] **Fullscreen display chooser + capture-all-displays** — S / MED
  Stills hardcode `NSScreen.main`; recording already has `RecordingScreenChooserWindow` for >1 screen — reuse it, plus an all-displays variant (one file per screen).
  `CaptureEngine.swift:156-168` vs `:230-256`

- [x] **Customizable filename template** — S / MED
  One function feeds all 7 call sites, so a Settings-backed template (prefix, date tokens, counter) propagates everywhere. ⚠️ `Settings.latestRecordingURL` discovers recordings by the literal `"Shotnix "` prefix + `.mp4` — fix that discovery when templating.
  `ImageExporter.swift:45-53` · `Settings.swift:253-257`

- [x] **Pin screenshots at their original capture location** — S / MED
  CleanShot's signature "freeze part of the screen" behavior. `HistoryItem.captureRect` is already persisted and available at both pin call sites — add an optional rect param with center fallback.
  `PinnedWindow.swift:10-14, 67` · `QuickAccessOverlay.swift:589-598` · `HistoryPanelController.swift:538-541`

- [x] **Overlay quick actions: "Copy Text" (OCR) + post-save "Reveal in Finder"** — S / MED
  OCREngine already ships and works; save currently succeeds silently. A Copy Text pill + a post-save toast with Reveal is cheap.
  `QuickAccessOverlay.swift:154-172, 295-298, 528-540`

- [x] **Decode all barcode symbologies, not just QR** — S / MED
  `VNDetectBarcodesRequest` filters to `.qr` in two places; EAN/UPC/Code128/Aztec/DataMatrix/PDF417 yield "No QR code found." Widen the list, carry the symbology name into the result-window title.
  `QRCodeEngine.swift:28, 40` · `CaptureEngine.swift:534`

- [x] **Canvas zoom in the annotation editor** — S / MED
  `allowsMagnification` is never set — a 5K capture pans at 1:1 only. Enable with limits + pinch + ⌘+/− + fit-on-open; the canvas is already the scroll view's documentView.
  `AnnotationWindowController.swift:101-128` · `AnnotationCanvas.swift:59, 97-98`

- [x] **Shift/Option drawing constraints + arrow-key nudging** — S / MED
  No Shift for squares/circles/45° arrows, no Option draw-from-center, no arrow-key nudge (1px / Shift 10px). Geometry helpers already exist.
  `AnnotationCanvas.swift:391-413, 693-708, 839-875`

- [x] **Parallelize per-screen frozen captures** — S / MED
  `prepareAndShow` awaits each display serially before the crosshair appears (30–100ms each per the file's own comment). `async let` / TaskGroup divides latency by display count.
  `AreaSelectionWindow.swift:29-38` · `CaptureEngine.swift:60-64`

- [x] **Video-editor transport shortcuts** — S / LOW
  Frame-accurate `,`/`.` step, Shift-arrow coarse jump, Home/End, J/K/L shuttle; fill the empty shortcut strings in the command palette.
  `VideoDemoEditor.swift:2591-2668, 3961-3972`

---

## Phase 2 — Core UX Upgrades (target: v0.19) — Medium effort, ordered by impact

- [ ] **Non-activating quick-access overlay** — M / HIGH
  Every screenshot yanks focus from the app the user is in (`NSApp.activate` on show + on every hover-enter, plus two retry timers). Convert to `NSPanel` with `.nonactivatingPanel`; the local key monitor is already hover-gated so ⌘C/⌘S/⌘E/Esc keep working.
  `QuickAccessOverlay.swift:103-117, 404-424, 87-100`

- [ ] **True window capture with shadow/padding/styling** — M / HIGH
  Window mode is a screen-rect crop — overlapping windows and notifications get baked in; no shadow, transparent padding, or rounded corners (Xnapper's core value prop, and an unchecked item in your own README). `SCContentFilter(desktopIndependentWindow:)` is already used for recording previews — carry the `SCWindow` through instead of a `CGRect`, add include-shadow/padding options.
  `CaptureEngine.swift:133-152` vs `:325-341` · `AreaSelectionWindow.swift:636-671`

- [ ] **Pause/resume recording (+ cancel/discard on the HUD, persist HUD position)** — M / HIGH
  Frames are already retimed against `firstPresentationTime` — pause = drop samples while paused + subtract accumulated pause duration in `relativePresentationTime`.
  `RecordingEngine.swift:26-27, 384-387` · `RecordingHUDWindow.swift:84-89, 113-125`

- [ ] **Editable text annotations + real text options** — M / HIGH
  Committed text can never be edited (no double-click path); entry is a fixed 200×30 single-line field hardcoded to bold 18pt. Add double-click re-edit, font size/style controls, multi-line.
  `AnnotationCanvas.swift:730-758, 359-389` · `AnnotationObject.swift:516`

- [ ] **Extend video-editor undo to all mutations** — M / HIGH
  Fades, zoom-keyframe sliders, effect bindings, moveZoom drags, aspect/background presets all mutate with no snapshot — ⌘Z then reverts the last *timeline* edit instead. Route everything through one `mutate(undoable:)` helper with drag coalescing (the `beginTimelineTrim`/`finishTimelineTrim` pattern already exists).
  `VideoDemoEditor.swift:2275-2287, 2441-2474, 2505-2525, 3710-3721, 2601-2603`

- [ ] **Move sample-buffer appends off the main actor** — M / HIGH
  All three `process*SampleBuffer` paths hop every buffer to the main actor despite SCStream delivering on `writerQueue` — 60fps of full-res appends on the UI thread, buffer-pool starvation whenever the main thread is busy (e.g. while opening the menu to stop). Append directly on `writerQueue` with queue-confined timing state.
  `RecordingEngine.swift:9, 144-171, 193-196, 386`

- [ ] **Window recordings follow window move/resize** — M / HIGH
  Source rect resolved once at start; `updateConfiguration` never called — move the window mid-demo and it slides out of frame (cursor metadata `captureRect` goes stale the same way).
  `RecordingEngine.swift:267-295, 341` · `VideoDemoRecordingMetadata.swift:236`

- [ ] **Non-destructive, undoable crop** — M / HIGH
  `applyCrop()` flattens all annotations into the bitmap and deletes the objects with no undo snapshot; the unsaved-work warning also stops firing after. Snapshot pre-crop state, or keep crop as a live rect applied at export (like the background options).
  `AnnotationWindowController.swift:249-260, 271-280` · `AnnotationCanvas.swift:823-829`

- [ ] **Decouple export resolution from display backing scale** — M / HIGH
  `flatten()` uses `cacheDisplay` — a Retina capture edited on a 1x monitor exports at half resolution; nil-window fallback hardcodes scale 2. Render into an offscreen `NSBitmapImageRep` sized to source pixels.
  `AnnotationCanvas.swift:912-934, 92-96, 888-908`

- [ ] **WYSIWYG: make video export match preview** — M / HIGH
  Preview shows gradient background + blur slider; export paints flat color, never applies blur. Preview text is 16pt; export uses `max(width*0.026, 26)`. Fix export (CAGradientLayer + CIGaussianBlur) and match preview text sizing to the export formula.
  `VideoDemoEditor.swift:4153-4174` vs `:1306-1321` · `:4238` vs `:1431-1432`

- [ ] **Timer/delayed capture (3/5/10s) + pre-recording countdown** — M / MED
  No delay path exists anywhere (only way to capture menus/hover states; Apple's built-in tool has it). Recordings also start instantly, capturing the user releasing the mouse. One countdown overlay serves both, Escape aborts.
  `CaptureEngine.swift:107-543` · `RecordingEngine.swift:62-105` · `Settings.swift`

- [ ] **Stack simultaneous overlays** — M / HIGH
  `openWindows` supports multiple overlays but `positionOverlay()` puts every one at the identical corner origin — the older capture is unreachable. Offset by existing heights, re-flow on close.
  `QuickAccessOverlay.swift:20, 389-400`

- [ ] **History retention policy + orphan cleanup** — M / HIGH
  Full-res PNG + thumbnail per capture, forever; `load()` drops index entries with missing PNGs but never deletes orphaned PNGs. Ship "keep N days / max N items," a startup sweep, and a "History is using X MB" readout.
  `HistoryManager.swift:36-66, 109-119`

- [ ] **History panel correctness batch** — M / HIGH
  (1) `isSelectable = false` blocks NSCollectionView item drags entirely — the header's "drag any card to Finder" promise is broken; (2) `items` isn't `@Published`, so an open panel never shows new captures; (3) sync `NSImage(contentsOfFile:)` during cell population; drags re-encode the PNG and strip Spotlight xattrs — copy the file instead; (4) deletes call `reloadData()` (grid flash; likely the known mid-grid corruption) — use `performBatchUpdates` + grace-period undo (file removal is already deferred).
  `HistoryPanelController.swift:124-125, 240-250, 332, 356-367, 446` · `HistoryManager.swift:6-8, 82-92`

- [ ] **Fix pre-existing AppKit-vs-CG coordinate mismatch in fullscreen capture of non-primary displays** — S / MED *(found during the Phase-1 review, pre-dates Phase 1)*
  `CaptureEngine.swift` intersects an AppKit bottom-left-origin rect against `SCDisplay.frame` (CG top-left-origin), and `fallbackCapture` passes the AppKit rect to `CGWindowListCreateImage` (CG space) — full-frame captures of non-primary displays in vertically-arranged setups can select the wrong display or fail. Convert explicitly between coordinate spaces at both sites.

- [ ] **Desktop-icon hiding without restarting Finder** — M / HIGH
  Currently terminates and relaunches Finder *twice per capture* (closing the user's Finder windows, ~2s), and returns before icons actually disappear, so the shot can fire too early. Replace with per-screen wallpaper-colored overlay windows (CleanShot's approach).
  `DesktopIconsManager.swift:43-65, 6` · `CaptureEngine.swift:48-56`

- [ ] **Move image encoding/IO off the main actor** — M / MED
  PNG-encoding a 5K capture + atomic write happens synchronously on the main actor exactly while the overlay animates in. Detached task, completion posted back; `bestCGImage` is already cached.
  `ImageExporter.swift:34-43, 129-163` · `CaptureEngine.swift:553-563`

- [ ] **Video-editor scrubbing responsiveness** — M / MED
  Every drag tick issues a zero-tolerance seek (use chained-seek: one in-flight, loose tolerance while dragging, exact on release). The 30Hz time observer publishes on the ObservableObject driving the whole editor — move the clock to a separate observable; stop recomputing `timelineSnapPoints()` inside a ForEach.
  `VideoDemoEditor.swift:1985, 4377-4386, 4499-4530, 2769-2783, 4450`

---

## Phase 3 — Flagship Repairs (target: v0.20) — Large effort, fixes advertised features

- [ ] **Real scrolling-capture stitcher** — L / HIGH ← *the most broken advertised feature*
  `FrameStitcher.stitch` only drops byte-identical frames (full-buffer memcmp vs the immediate predecessor) and stacks every frame at full height — output contains large repeated bands. Frames accumulate unbounded (~17 MB / 300ms); the only stop is a HUD button that can sit off-screen, no Escape.
  Fix: row-signature/cross-correlation search for where the previous frame's bottom rows reappear; frame-count cap + downsampled-hash dedup; Escape/hotkey stop; `visibleFrame`-clamp the HUD.
  `ScrollingCaptureController.swift:156-204, 163-173, 64-79, 44-62, 256-259`

- [ ] **Export sheet: GIF + fps + resolution + HEVC** — L / HIGH ← *loudest competitive gap (3 analyzers)*
  Recorder hardcodes H.264/MP4; editor exports fixed 30fps `AVAssetExportPresetHighestQuality` MP4, silently downsampling 60fps recordings (the sidecar's fps field is never read); zero GIF code exists. v1: format (MP4/GIF), fps (source/30/60), resolution scale; GIF via AVAssetReader → CGImageDestination; HEVC toggle rides along (~40% smaller, hardware-encoded).
  `RecordingEngine.swift:199, 606-621, 746-756` · `VideoDemoEditor.swift:1018, 1051-1056, 2727-2730` · `VideoDemoRecordingMetadata.swift:68`

- [ ] **Adjustable selection stage** — L / HIGH
  Corner handles are decorative — `mouseUp` captures instantly; a mis-dragged edge means starting over. Add a post-drag stage: edges/corners hit-test and drag, arrow-key nudge (Shift 10px), Enter/click confirms, Shift/Option/Space modifiers during drag. Dimension label + frozen-image loupe already exist.
  `AreaSelectionWindow.swift:550-561, 399-421, 524-548, 617-621, 13-21`

---

## Phase 4 — Strategic Bets (v0.21+) — Large effort, one per release

Ordered by expected payoff; pick based on where you want Shotnix positioned.

- [ ] **Cloud upload + instant share links** — L / HIGH ← *the single biggest feature gap*
  No share flow exists anywhere (no NSSharingService, no destinations tab). Account-free version — user-configured S3/R2/Imgur/custom endpoint, link auto-copied — fits the "No subscription. No account." positioning. Even a minimal `NSSharingServicePicker` on the last capture is a big step.
  `README.md:28` · `PreferencesWindowController.swift:7-33` · `AppDelegate.swift:230-271`

- [ ] **Webcam overlay for recordings** — L / HIGH
  Table stakes for the tutorial audience the demo editor targets (Loom/CleanShot/Screen Studio all have it). An `AVCaptureSession` already runs mic-only; add a floating circular preview window excluded from capture via the HUD's existing exclusion pattern, recorded as a separate track, composited in the editor via the sidecar architecture.
  `RecordingEngine.swift:540-560, 73` · `VideoDemoRecordingMetadata.swift`

- [ ] **Layout-aware OCR: copy-as-table, link detection, language settings** — L / HIGH
  `recognizeText` joins `topCandidates(1)` with newlines and discards every bounding box — multi-column text interleaves, tables lose alignment. Keeping observations + boxes unlocks column detection, copy-as-table, tappable links (Shottr's headline feature). Language/accuracy settings ride along.
  `OCREngine.swift:22-30` · `CaptureEngine.swift:498-503`

- [ ] **History search, filtering, and capture metadata** — L / HIGH
  `HistoryItem` stores only id/date/paths/rect — a 200-item history is unnavigable. Minimal: NSSearchField + a `captureType` field recorded at `add()`. Big unlock: store OCR text at capture time → full-text search of past captures.
  `HistoryItem.swift:3-12` · `HistoryPanelController.swift:70-149` · `HistoryManager.swift:36-47`

- [ ] **New annotation tools: spotlight, callout bubble, freehand highlighter, rounded rect** — L / HIGH
  Spotlight is closest to free — `drawCropOverlay` already implements the outside-dimming rendering. Freehand highlighter = `FreehandAnnotation`'s point array + the highlighter's 0.4-alpha butt-cap stroke.
  `AnnotationObject.swift:5-7, 396-440` · `AnnotationCanvas.swift:338-355`

- [ ] **Real video blur (replaces the Phase-1 "Redact" rename)** — L / MED
  Region blur/pixelation over video needs a custom `AVVideoCompositing` pass (CIGaussianBlur/CIPixellate per frame). Also add intensity controls to the annotation editor's blur/pixelate (hardcoded radius 12 / scale 10 — weak blur can leak text).
  `VideoDemoEditor.swift:1468-1476, 4257-4265` · `AnnotationObject.swift:450, 482`

- [ ] **Localization + accessibility pass** — L / LOW (urgency) — but cost grows with every custom-HUD surface shipped; budget it before 1.0.

---

## Suggested release mapping

| Release | Theme | Contents |
|---|---|---|
| v0.18 | "It never loses your work" | Phase 1 (all small — 1A reliability first, then 1B features) |
| v0.19 | "It feels professional" | Phase 2 (focus-stealing, true window capture, pause/resume, undo, WYSIWYG) |
| v0.20 | "The features are real" | Phase 3 (scrolling stitcher, export sheet with GIF, adjustable selection) |
| v0.21+ | "The bets" | Phase 4, one per release — cloud share first if positioning against CleanShot, webcam first if positioning against Loom/Screen Studio |
