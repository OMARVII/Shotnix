<p align="center">
  <h1 align="center">Shotnix</h1>
  <p align="center">
    A fast, focused screenshot utility for macOS.<br/>
    Capture, annotate, pin, and extract text — all from your menu bar.
  </p>
  <p align="center">
    <a href="https://github.com/OMARVII/Shotnix/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/OMARVII/Shotnix?label=Download&style=flat-square&color=6C3FE8"/></a>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square"/>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/OMARVII/Shotnix?style=flat-square"/></a>
    <img alt="Swift" src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square"/>
  </p>
</p>

---

<!-- Add a screenshot or GIF here:
<p align="center">
  <img src="assets/screenshot.png" width="720" alt="Shotnix screenshot" />
</p>
-->

## Why Shotnix?

macOS has built-in screenshot tools, but they stop at capture. Shotnix picks up where they leave off — annotate with arrows, blur sensitive info, pin screenshots to your desktop, extract text with OCR, and access everything from a lightweight menu bar app. No subscription. No account. Just a fast tool that stays out of your way.

## Features

**Capture anything**
- **Area** — drag to select any region
- **Window** — click any window to capture it
- **Fullscreen** — grab the entire screen instantly
- **Previous area** — re-capture the last selected region with one shortcut
- **Scrolling** — capture content beyond the visible area
- **OCR** — extract and copy text from any part of the screen

**Annotate and edit**
- Arrows, rectangles, ellipses, lines, freehand drawing
- Text annotations with customizable font and color
- Highlighter for emphasizing content
- Blur and pixelate for redacting sensitive info
- Numbered markers for step-by-step guides
- Crop to resize after capture

**Stay in flow**
- Quick access overlay after every capture — copy, save, edit, or pin
- Pin screenshots to float on your desktop
- Full capture history with grid browser
- Global hotkeys that work from anywhere

## Install

### Download (recommended)

1. Grab the latest `.dmg` from [**Releases**](https://github.com/OMARVII/Shotnix/releases/latest)
2. Open the DMG and drag **Shotnix** to your Applications folder
3. Grant **Screen Recording** permission when prompted

> [!IMPORTANT]
> **macOS will show a warning on first launch** — this is normal for open-source apps that aren't notarized through Apple's $99/year Developer Program. Shotnix is safe and fully open source. Here's how to open it:
>
> **macOS Ventura & Sonoma (13–14):**
> Right-click `Shotnix.app` → click **Open** → click **Open** again in the dialog
>
> **macOS Sequoia (15+):**
> 1. Try to open the app (it will be blocked)
> 2. Go to **System Settings → Privacy & Security**
> 3. Scroll down and click **Open Anyway** next to "Shotnix was blocked"
>
> **Or use Terminal:**
> ```
> xattr -dr com.apple.quarantine /Applications/Shotnix.app
> ```

### Build from source

```bash
git clone https://github.com/OMARVII/Shotnix.git
cd Shotnix
bash build-app.sh
```

This compiles a release build, generates the app icon, ad-hoc signs the binary, and copies `Shotnix.app` to your Desktop.

**Requirements:** macOS 13+, Swift 5.9+

## Hotkeys

| Shortcut | Action |
|---|---|
| `Cmd + Shift + 4` | Area capture |
| `Cmd + Shift + 5` | Window capture |
| `Cmd + Shift + 6` | Fullscreen capture |
| `Cmd + Shift + 7` | Previous area capture |
| `Cmd + Shift + O` | OCR text extraction |
| `Cmd + Shift + S` | Scrolling capture |

## Architecture

Shotnix is a Swift Package Manager project — no `.xcodeproj`, no storyboards. Pure AppKit, built from the terminal.

```
Sources/Shotnix/
├── App/           Application lifecycle, menu bar, preferences
├── Capture/       Screenshot engine (ScreenCaptureKit + CGWindow fallback)
├── Annotation/    Editor with 12 drawing tools and undo/redo
├── History/       Persistent capture history (~Library/Application Support/)
├── Hotkeys/       Global shortcuts via HotKey package
├── OCR/           Text recognition via Vision framework
├── Overlay/       Quick access thumbnail, pinned windows, toasts
└── Utilities/     Image export, permissions, desktop icon toggle
```

## Dependencies

| Package | Purpose |
|---|---|
| [HotKey](https://github.com/soffes/HotKey) | Global keyboard shortcuts |

That's it. One dependency.

## Roadmap

- [ ] Customizable hotkeys
- [ ] Multi-display capture fixes
- [ ] First-launch onboarding
- [ ] Auto-update mechanism
- [ ] Developer signing + notarization

## Contributing

Contributions are welcome. Open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
