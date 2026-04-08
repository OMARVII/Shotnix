# Contributing to Shotnix

Thanks for your interest in contributing! Here's how to get started.

## Process

1. **Open an issue first** to discuss what you'd like to change
2. Fork the repo and create a branch from `main`
3. Make your changes
4. Test manually (build and run the app)
5. Submit a pull request

## Development Setup

```bash
git clone https://github.com/OMARVII/Shotnix.git
cd Shotnix
swift build          # Debug build
bash build-app.sh    # Full .app bundle (release + icon + codesign)
```

**Requirements:** macOS 13+, Swift 5.9+

No Xcode project — everything builds from the terminal via Swift Package Manager.

## Code Style

- All UI code is `@MainActor`
- AppKit only (no SwiftUI)
- No force unwraps (`!`) without a documented reason
- No `// TODO` or `// HACK` — fix it or file an issue
- Match existing patterns in the file you're editing

## What We're Looking For

Check the [Roadmap](README.md#roadmap) for planned features. Bug fixes, performance improvements, and accessibility enhancements are always welcome.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
