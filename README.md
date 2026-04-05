# Shotnix

A fast, focused screenshot utility for macOS.

Capture, annotate, pin, and extract text — all from your menu bar.

## Features

- **Area capture** — drag to select any region of the screen
- **Window capture** — click any window to capture it
- **Fullscreen capture** — grab the entire screen instantly
- **Previous area** — re-capture the last selected region
- **Scrolling capture** — capture content beyond the visible area
- **OCR text extraction** — copy text from any part of the screen
- **Annotation editor** — arrows, rectangles, ellipses, lines, freehand, text, highlighter, blur, pixelate, numbering, crop
- **Quick access overlay** — floating thumbnail with actions after each capture
- **Pin screenshots** — keep captures floating on your desktop
- **History panel** — browse and manage all past captures
- **Global hotkeys** — trigger any capture mode from anywhere

## Requirements

- macOS 13+
- Swift 5.9+

## Build

```
git clone https://github.com/OMARVII/Shotnix.git
cd shotnix
bash build-app.sh
```

`build-app.sh` compiles a release build, assembles the .app bundle, generates the app icon, ad-hoc signs it, and copies `Shotnix.app` to your Desktop.

For a debug build during development:

```
swift build
```

## Default Hotkeys

| Shortcut | Action |
|---|---|
| Cmd+Shift+4 | Area capture |
| Cmd+Shift+5 | Window capture |
| Cmd+Shift+6 | Fullscreen capture |
| Cmd+Shift+7 | Previous area capture |
| Cmd+Shift+O | OCR text extraction |
| Cmd+Shift+S | Scrolling capture |

## License

MIT — see [LICENSE](LICENSE) for details.
