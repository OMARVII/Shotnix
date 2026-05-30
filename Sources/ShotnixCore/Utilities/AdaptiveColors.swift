import AppKit

enum ShotnixColors {

    static let overlayTint = NSColor(name: "overlayTint") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.06)
        default:        return NSColor.black.withAlphaComponent(0.08)
        }
    }

    /// Solid fill behind the capture thumbnail in QuickAccessOverlay.
    /// Needs to be opaque enough to read as a proper container when the
    /// image is letterboxed inside the fixed overlay size.
    static let overlayContainerFill = NSColor(name: "overlayContainerFill") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(white: 0.11, alpha: 0.96)
        default:        return NSColor(white: 0.18, alpha: 0.96)
        }
    }

    static let overlayBorder = NSColor(name: "overlayBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.25)
        default:        return NSColor.black.withAlphaComponent(0.12)
        }
    }

    static let cornerButtonBackground = NSColor(name: "cornerButton") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.18)
        default:        return NSColor.black.withAlphaComponent(0.12)
        }
    }

    static let cornerButtonHover = NSColor(name: "cornerButtonHover") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.35)
        default:        return NSColor.black.withAlphaComponent(0.22)
        }
    }

    static let cornerButtonPressed = NSColor(name: "cornerButtonPressed") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.45)
        default:        return NSColor.black.withAlphaComponent(0.30)
        }
    }

    static let pillButtonBackground = NSColor(name: "pillButton") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.92)
        default:        return NSColor.white.withAlphaComponent(0.95)
        }
    }

    static let pillButtonHover = NSColor(name: "pillButtonHover") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white
        default:        return NSColor.white
        }
    }

    static let pillButtonPressed = NSColor(name: "pillButtonPressed") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.75)
        default:        return NSColor.white.withAlphaComponent(0.75)
        }
    }

    static let pillButtonText = NSColor(name: "pillButtonText") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.85)
        default:        return NSColor.black.withAlphaComponent(0.85)
        }
    }

    static let progressBackground = NSColor(name: "progressBg") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.15)
        default:        return NSColor.black.withAlphaComponent(0.15)
        }
    }

    static let pinnedBorder = NSColor(name: "pinnedBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.12)
        default:        return NSColor.black.withAlphaComponent(0.08)
        }
    }

    static let canvasBackground = NSColor(name: "canvasBackground") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(white: 0.12, alpha: 1.0)
        default:        return NSColor(white: 0.22, alpha: 1.0)
        }
    }

    static let editorStageTop = NSColor(name: "editorStageTop") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(calibratedRed: 0.045, green: 0.049, blue: 0.062, alpha: 1)
        default:        return NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        }
    }

    static let editorStageBottom = NSColor(name: "editorStageBottom") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(calibratedRed: 0.105, green: 0.096, blue: 0.13, alpha: 1)
        default:        return NSColor(calibratedRed: 0.28, green: 0.28, blue: 0.31, alpha: 1)
        }
    }

    static let editorChromeBorder = NSColor(name: "editorChromeBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.10)
        default:        return NSColor.white.withAlphaComponent(0.20)
        }
    }

    static let editorDockBorder = NSColor(name: "editorDockBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.18)
        default:        return NSColor.white.withAlphaComponent(0.28)
        }
    }

    static let editorActionBackground = NSColor(name: "editorActionBackground") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.13)
        default:        return NSColor.black.withAlphaComponent(0.10)
        }
    }

    static let selectionDim = NSColor(name: "selectionDim") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.45)
        default:        return NSColor.black.withAlphaComponent(0.3)
        }
    }

    static let labelPillBackground = NSColor(name: "labelPill") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.75)
        default:        return NSColor.black.withAlphaComponent(0.65)
        }
    }
}
