# Changelog

## [0.24.0-beta] - 2026-09-26

**Three changes to know about:**
- **Esc no longer stops a recording from other apps.** Closing a dialog or leaving full-screen video used to end the take. Press ⌃⌘Esc to stop from anywhere, Esc while Shotnix is in front, or use the HUD or menu-bar timer.
- **Scrolling Capture and Capture Text have no shortcut on new installs.** ⌘⇧S and ⌘⇧O are Save As and Open in most apps, and a global shortcut takes them away everywhere. If you already use them, they stay. Assign any shortcut in Settings → Shortcuts.
- **Recordings move to 60 fps once.** Pressing Record used to save whatever the recording bar showed, so many people stayed at 30 fps without choosing it. If you want 30 fps, pick it again in Settings → Recording; Shotnix won't change it after this.

### Screenshots

#### Added
- **New tools in the screenshot editor:** Spotlight (S) dims everything except what matters, Callout (O) adds a speech bubble that points at something, the freehand highlighter (⇧H) marks up anything, and ⌥R draws rectangles with rounded corners.
- **Text that fits:** any size from 10 to 96 pt, bold or regular, several lines (Return adds a line, ⌘Return finishes), and double-click to edit again.
- **Adjust a selection before the shot.** Hold ⇧ as you let go (or turn off Settings → Screenshots → "Capture immediately after selecting") and the selection stays on screen: drag its edges or corners, drag inside to move it, nudge with the arrow keys (⇧ for 10 pt), then press Return or click Capture.
- **Capture All Displays** takes every connected display at once, one image each, from the menu or a shortcut you assign.
- **Scrolling capture stitches for real.** Scroll a long page and Shotnix lines up each frame with the last, so the result is the page itself: no repeated bands, sticky headers and footers shown once, and no blank strip from a trackpad bounce at the end. Press Esc or the shortcut again to finish from any app; very long pages stop at a safe size and say so.
- **Text recognition keeps the layout.** Columns come out in reading order, tables can be copied as tab-separated rows (paste straight into a spreadsheet), and links and email addresses in the result can be opened or copied. Choose the languages and Accurate or Fast in Settings → Screenshots; Chinese, Japanese, Korean, Thai and Arabic mix correctly with English, slightly tilted text still reads line by line, and Hebrew and Arabic read right to left. Capture Text also saves the image to History.
- **History that stays tidy.** Keep captures forever (the default), for 7, 30 or 90 days, or only the last 100, 500 or 1,000. Settings shows how much space History uses and has a Clean Up button. Filter by capture type, select with the keyboard or ⌘-click, press ⌫ to delete and ⌘Z to undo (even after the notice is gone), drag captures out as their original PNG under their capture-time name, and just start typing to search.
- **Edits show up in History.** Saving or copying an edited screenshot updates its History entry; the original capture is kept beside it.
- **Quitting asks about unsaved screenshot edits.** One editor asks Save / Cancel / Don't Save; with several, you can review them one by one or discard them all.

#### Changed
- **The screenshot editor is a normal window.** It no longer floats above every other app.
- **Crop can be undone and changed later.** Cropping no longer flattens your annotations into the picture: they stay editable, and Return applies the crop.
- **Saved at full resolution on any display.** A Retina capture edited on a non-Retina monitor used to save at half size.
- **Hiding desktop icons no longer restarts Finder.** Shotnix covers the icons with your desktop picture for the moment of the capture, so Finder windows stay open and the shot never fires before the icons are gone.
- **Pinned screenshots** take keyboard focus without bringing Shotnix forward: Esc closes one and ⌘C copies it.
- **File ▸ Close Window (⌘W)** closes the editor, History, Settings, pins and the thumbnail.
- **WebP** is only offered when macOS can write it (current macOS versions can't); a saved WebP setting falls back to PNG.
- **Shortcut hints name your real shortcuts**, and shortcuts work on non-Latin keyboard layouts (Russian, Greek, Hebrew and others).

#### Fixed
- **Blur and pixelate fully cover what's under them.** Text could show through at the edges, and blur was half as strong on Retina displays. There's now a strength slider, and pixelate uses real mosaic blocks.
- **Two screenshots taken in the same second no longer overwrite each other** when auto-saving; each gets its own numbered file, and a failed auto-save says why and how to fix it.
- **Exports never include the dashed hover outline or selection handles** from the editor.
- **"Copied" appears only when the copy worked.**
- **Clicks pick the annotation you see on top.** Blur, pixelate and spotlight draw beneath other annotations, so clicking a label inside a spotlight edits the label.
- **The editor works with VoiceOver**, and so do History and the capture tools.

### Recording

#### Added
- **Pause and resume** from the HUD, the menu, or a shortcut you assign. Paused time is cut from the video, the voice and the camera.
- **Discard a take** from the HUD, with a confirmation.
- **Countdown:** an optional 3, 5 or 10 seconds before recording starts.
- **Recordings survive crashes.** If Shotnix quits unexpectedly or the Mac loses power, the recording (and your camera) is recovered the next time Shotnix opens. Quitting, logging out or installing an update stops and saves first.
- **A dashed outline** shows the area being recorded, and the recording bar and Settings show an estimated size per minute.
- **More in the recording bar:** a "…" menu with camera choice, the editable cursor, "open editor after recording", and the countdown. The controls work with the keyboard and VoiceOver, and Return starts recording.

#### Changed
- **Shotnix's own toasts, menus, timer, HUD and camera bubble never appear in recordings.** Its editor and Settings windows still record normally.
- **Window recordings show the window you picked with its menus, popovers and sheets**, leave the app's other windows out, and follow the window when you move or resize it, even onto another display.
- **The HUD never takes focus** from the app you're recording, remembers where you put it, and keeps off the recorded area. It shows the camera and shortcut state, warns about dropped frames and low disk space, and says "Saving…" while it saves.
- **5K, 6K and "More Space" displays record in HEVC** (H.264 can't encode frames that large), and 60 fps recordings get a bitrate to match.
- **Sizes are shown in pixels.**

#### Fixed
- **The voice lines up with the picture from the first frame.** Sound captured just before the first frame was played at the start and pushed the rest late.
- **A microphone that drops out or is unplugged** no longer shifts the rest of the audio; Shotnix switches to another microphone and tells you.
- **Recording with no microphone connected works** and says so, instead of failing with a message about permissions and leaving a broken file.
- **A full disk stops the recording cleanly** and keeps what was recorded, and slow saves are never cancelled. Recording only starts when there's room for it, and says how much space it needs.
- **The display no longer sleeps mid-recording.**
- **Starting a new recording while the last one saves** waits for the save instead of failing.
- **The saved-recording panel** has a close button, closes with Esc, and appears on the screen you recorded.

### Video editor

#### Added
- **Add a logo, watermark or screenshot over your video:** place it, resize it, set its opacity, snap it to a corner, and time it on the timeline.
- **Background music** with volume, fades, looping, a start point, and automatic ducking under your voice (detected on your Mac). It plays across the title cards and fades out at the very end.
- **Intro and outro title cards** on your project's background.
- **Transitions:** Dissolve and Dip to black between clips, for every cut or one at a time, plus fades in from and out to black.
- **Click sounds**, if you want them.
- **Several recordings in one video:** append more recordings, then reorder or remove them. Each keeps its own cursor, clicks, keystrokes and camera.
- **Caption looks:** Classic, Bold outline, Minimal and Highlight, with your own highlight color; choose whether captions are burned into the video, and save WebVTT (.vtt) subtitles as well as .srt.
- **Translate captions on your Mac** (macOS 15 and later, with the language installed in System Settings). Nothing is uploaded.
- **A Spotlight annotation** (rectangle or ellipse), arrows that point any way (drag either end, or Turn Around), and a size control for text.
- **Select several items** with ⇧- or ⌘-click and move or delete them together; **drag clips to reorder** them; give **just part of a clip** its own speed or mute.
- **Exports run in the background:** progress and Cancel sit in the toolbar, exports queue up, you can keep editing (Esc hides the export sheet), and quitting asks first. Export a selection or an In/Out range, then Share or Reveal in Finder straight away.
- **A File menu** with Export Video… (⌘E), Save Subtitles and Recent Exports (also in the command palette).
- **Settings → Recording shows how much space video data uses**, with a Clean Up button; leftovers of deleted recordings are also cleaned once a day.

#### Changed
- **M mutes only the preview.** Exports keep their sound, and the export sheet warns (with a Turn On button) if an export would be silent.
- **The Script tab is now Captions**, and narrated recordings suggest transcribing with a banner.
- **Selecting something keeps the inspector's tabs in place**, and the tab keeps its scroll position.
- **The timeline zooms to frame level on any length**, keeps your spot when zooming, follows playback page by page, and groups crowded cut markers. Every bar snaps to the others.
- **Exports and subtitles are named after the recording** ("Demo (edited).mp4"), even after renaming it.
- **Undo says what it undoes** ("Undo Delete Zoom") and survives closing and reopening the editor until you quit.
- **Transcription shows its progress**, and editing a caption keeps the timing of the words you didn't change.
- **The tips bar has more pages, the shortcut list is complete, and ⌘F finds in the transcript.** ⌥← and ⌥→ step through the timeline's items.
- **Safer exports:** a failed export never damages an existing file, free space is checked first, error messages say what to do next, GIFs too large to finish are caught before they start, and there's a note that some browsers and Windows PCs can't play HEVC.

#### Fixed
- **Captions come from your voice alone**, not from music or the computer's sound.
- **Shorten Pauses and Speed Up Idle leave typing, scrolling and keyboard shortcuts alone.**
- **Clicking an annotation on the video selects it** (drag to move it, double-click text to type) instead of playing or pausing.
- **The keyboard works inside the export sheet**, and messages show on top of it.
- **Quitting during an export, transcription or voice cleanup asks first**, and your last edits are always saved.
- **Enhance voice reached the export again.** The cleaned-up voice could be missing from exported videos.
- **Long recordings stay smooth:** trimming, transcript edits and 4K previews no longer stall the editor, and closed editors free their memory.
- **Files that can't open explain why** and offer to open another, show it in Finder, or close.
- **Every timeline item works with VoiceOver.**

## [0.23.1-beta] - 2026-09-26

### Changed
- **Recordings default to 60 fps.** Scrolling, animations, and video in your recordings now stay smooth in the editor's 60 fps exports. If you picked 30 fps in Settings → Recording or the recording bar, Shotnix keeps it.

### Fixed
- **Captions keep sentences together.** When a long sentence has to split across two caption lines, its last word no longer rides along into the next sentence.

## [0.23.0-beta] - 2026-09-26

**Updating from an earlier version on macOS 26?** If installing stops with "An error occurred while running the updater", download Shotnix from shotnix.com and replace the app in Applications — your recordings and settings stay. Updates install normally from this version on.

### Changed
- **The video editor, rebuilt from the ground up.** A new layout: a big preview, a tabbed inspector (Style · Cursor · Zoom · Camera · Script · Audio) whose panel turns into a dedicated editor when you select something, and a full-width timeline. The toolbar lives in the title bar with crop, aspect ratio, undo/redo, commands, and Export.
- **One renderer for preview and export.** Every preview frame and every exported frame is drawn by the same Core Image pipeline at the output's own resolution, so what you see is exactly what you get — crisp text (proper downscaling of Retina recordings), squircle corners, soft layered shadows, and camera/cursor motion that runs at the display's refresh rate (and at the export frame rate, even for 30 fps recordings).
- **Zooms are blocks, not keyframes.** Each zoom is one block on the Zoom track: hover the track and click to add one (or press Z), drag to move, drag an edge to change how long it lasts, click to edit. The camera eases in at the block's start and is fully back out by its end; blocks close together chain into a smooth pan instead of zooming out and back in. Transitions are paced by depth, zoom in log space, and motion-blur like a real camera. Edges snap to the playhead, clip boundaries, clicks, and other zooms when you let go.
- **The camera can follow your cursor.** A zoom set to "Follow cursor" keeps the pointer in view and glides after it with a calm dead zone; "Aim by hand" shows the whole frame with a draggable target rectangle — drag it to aim, drag a corner to zoom in or out.
- **Auto Zoom lands before the click.** Fresh recordings open already produced: each burst of clicks gets its own zoom, timed so the camera has arrived before you click, following the cursor in between. Re-running Auto Zoom keeps zooms you placed by hand, and "Remove all zooms" clears them in one step.
- **Timeline editing, done right.** Split (S), drag clip edges to trim (the preview shows the exact edge frame while you drag), ⇧-drag to select a range and cut it, speed from 0.5× to 16×, per-clip mute and fades, and yellow markers where material was removed — click one to put it back. Real thumbnails and an audio waveform on every clip, a ghost playhead that follows the mouse, and pinch or ⌘-scroll to zoom the timeline. Drags follow the pointer exactly and snap when you let go.
- **Annotations stack like layers.** The timeline stacks the way the picture does: captions and keyboard shortcuts on top (they always draw in front), then annotation lanes (the highest lane draws in front), the camera moves, and the recording at the base. A new annotation that overlaps others goes on top, and dragging a bar up brings it forward.
- **Undo covers everything** — every edit, and each drag or slider scrub is exactly one step.
- **Timed-capture countdown redesigned** — the number sits optically centered in the circle, an accent ring depletes smoothly across the wait, each tick lands with a soft pop, and the cancel hint moved into a readable capsule below the circle.

### Added
- **A smooth, real macOS cursor.** Recordings now capture the pointer as data (on by default — Settings → Recording → Editable cursor), including the actual system cursor artwork at high resolution, so the editor redraws the real arrow, hand, and text beam crisply at any size and zoom. Zero-lag smoothing (Off / Light / Smooth / Silky) that still lands exactly on every click, sizes from 0.6× to 4×, motion blur, hide when idle, click effects (ripple or a springy press), "always show the arrow", and "hide the move to Stop" — the final dash to the Stop button disappears. The pointer is sampled at 60 Hz with button presses and releases.
- **Backgrounds:** 12 built-in gradient wallpapers, 8 gradients, solid colors plus a custom color picker, your own image, and the desktop pictures on your Mac — with blur, padding, roundness, shadow, and an edge highlight. "Full frame" drops the background in one click, a dice shuffles it, and "Use for new recordings" saves your look for every future recording.
- **Aspect ratios:** Auto, 16:9, 4:3, 1:1, 4:5, and 9:16. Tall recordings open in their own shape.
- **Annotations:** text, arrows, highlights, and a real blur that keeps private details hidden even through zooms — all draggable and resizable right on the preview. The tools sit in a dock centered above the preview (Text · Arrow · Highlight · Blur · Zoom): one click adds the effect at the playhead, in view even while zoomed in, ready to drag into place. Double-click text on the preview to type, and ⌘D duplicates. Give arrows, highlights, and text tags any color (swatches or the full color picker) and a thin, regular, or bold line; text can drop its tag for plain lettering with a soft shadow, and light tags switch to dark lettering on their own. New annotations start with the color and weight you used last.
- **Export sheet:** MP4 (720p, 1080p, 1440p, 4K · 24/30/60 fps · Web/Social/Studio quality · H.264 or HEVC, hardware-encoded) or GIF (small/medium/large, 10–24 fps), exact pixel size and a size estimate before you export, a warning when the output is larger than the recording, live progress with time remaining, cancel, and **Copy** — export straight to the clipboard to paste into chat or mail. The optional end card now plays after your video on your own background instead of covering its last moments.
- **Speed Up Idle** fast-forwards stretches where nothing happens (no movement, no clicks, no sound).
- **Keyboard-first:** Space, J/K/L, frame stepping, S, Z, T/H/A/B, I/O, 1–5 for zoom levels, ⌘D, ⌘C to copy the current frame, ⌘E to export, ⌘K for every command, and ? for the shortcut sheet.
- **Open videos in Shotnix** — "Open With" in Finder (or dropping a video on the app) opens it in the editor, portrait phone clips included.
- **Your camera, as its own layer.** Turn on the camera in the recording bar (or Settings → Recording → Camera) and a round live preview floats on screen while you record — it never appears in the screen capture. The camera is saved as a separate track that follows every cut and speed change, so in the editor's Camera tab you can pick a circle, rounded, or wide bubble, resize it, mirror it, drag it anywhere on the preview (it snaps into one of eight spots), let it shrink out of the way during zooms, or hide it.
- **Captions from your voice, made on your Mac.** The Script tab transcribes the narration on-device — nothing is uploaded — and times every word: short, readable lines that follow your cuts, with words lighting up as they're spoken. Edit any line (timing adapts), drag or trim caption chips on their own timeline lane, add lines by hand, pick size and position, choose the language, and save a subtitles file (.srt) that matches the edited video exactly.
- **Keyboard shortcuts on screen.** With "Show keyboard shortcuts" on (the ⌘ button in the recording bar), the shortcuts you press appear in the video as keycaps — ⇧ ⌘ 4 — with repeats stacking into "⌘Z ×3". Only ⌘ and ⌃ combinations (and ⌥ with keys that don't type, like arrows), Esc, and function keys are recorded; plain typing never is, including characters typed with ⌥. Hide any single shortcut (a stray ⌘Tab) from its chip on the timeline. Needs Accessibility access, which Shotnix asks for the first time — the button switches on by itself once you allow it.
- **Edit the video by editing its words.** In the Script tab's "Edit by text", select words in the transcript and press ⌫ to cut them from the video (⌫ again on crossed-out words puts them back); click a word to jump there, ⌘F to find. **Remove ums** cuts every um and uh in one click (in the transcript's own language), and **Shorten pauses** trims long silences to a breath — but only where nothing happens on screen, so the time you spend clicking through the demo is never cut. Captions drop the words you cut.
- **Better sound.** Separate **Voice** and **Computer sound** levels when you recorded both (so your narration sits over the app's sound), **Enhance voice** (removes background noise and hum and evens out your level, processed on this Mac and kept in sync with the picture), and **Even out loudness** on export (the whole mix lands at −16 LUFS without clipping). Volume and mute changes apply instantly without interrupting the preview.
- **More ways to show your camera.** Blur or remove what's behind you (your video's own background shows through), a **Cutout** look with just you over the screen, and **camera layouts** on their own timeline lane: **Full camera** for talking points (the bubble grows to fill the frame), **Side by side** with the screen, and **Camera hidden** — each eases in and out. One click adds a full-camera intro and outro.
- **Vertical videos that follow you.** Switch a screen recording to 9:16, 4:5, or 1:1 and it fills the frame instead of shrinking into a letterbox: the view pans with your cursor (calmly, and never losing it), while the camera, captions, and shortcuts stay put in the vertical frame. Turn it off from the aspect menu.
- **Crop.** Trim browser chrome or a busy desktop out of any recording: drag the crop frame (with a thirds grid, eight handles, and Free/16:9/4:3/1:1/9:16 locks) over the full, uncropped recording. Cursor, clicks, and zooms follow the crop automatically. Esc cancels, Return keeps it.
- **Start over anytime.** ⌘K → "Start Over from the Original Recording" clears every edit — and ⌘Z brings them all back.
- **Long recordings stay fast.** A 30-minute take with hundreds of zooms, captions, and shortcuts edits as smoothly as a short one.

### Fixed
- **Recordings keep their data when you rename or move them.** Renaming or moving a recording in Finder lost its editable cursor, clicks, shortcuts, camera, and every edit. They now travel with the file. Recordings saved in deep folders (long or non-English paths) no longer lose them either.
- **The editor stays in front after a recording.** It could open, then slip behind the app you'd been recording and need reopening from the menu bar. Opening the Shotnix menu, taking a screenshot, or opening Settings while an editor is open also no longer removes the editor's Dock icon and ⌘-Tab entry.
- **Recordings keep their exact colors.** Reds, greens, and brand colors were slightly shifted when encoded; they now match the screen. Area recordings capture whole pixels at exactly the recorded size (no soft or empty edge on odd-sized selections).
- **Exports look like the preview.** Mid-tones came out lighter than in the editor; exported videos now match it.
- **GIF export works at any length.** It failed with "Could not write the GIF" unless the video's length happened to be a whole number of frames.
- **Updates install again on macOS 26.** After downloading an update, installing could fail with "An error occurred while running the updater": Shotnix's identifier ends in ".app", so macOS mistook the updater's working folder for an app and blocked the installer from writing to it. The built-in updater (now Sparkle 2.10) uses a folder macOS doesn't confuse with an app. If an older version still fails to update, download the latest version from shotnix.com and replace the app.

## [0.22.0-beta] - 2026-09-19

### Added
- **Post-capture thumbnails stack** — take several screenshots in a row and the thumbnails pile into a tidy column instead of covering each other: each new capture lands on top of the pile. Dismiss any card (timeout, swipe, Esc, or an action) and the cards above drop down into the freed space with a soft landing. Each screen keeps its own pile, capped at five — beyond that the oldest card bows out. Hover-pause still works per card, even when a card slides under (or away from) a stationary cursor.

### Fixed
- **Swipe-dismiss actually slides now** — the overlay's swipe-away animation silently never moved the window (only the fade ran) because window origin isn't animatable on macOS; the card now visibly slides off toward the swipe direction.

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
- **True window capture** — window mode now captures the clicked window itself (isolated, nothing overlapping bakes in) with optional transparent padding and a drop shadow (Settings → Screenshots).
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
- **Screenshot color accuracy** — uses the display's native calibrated ICC profile
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
