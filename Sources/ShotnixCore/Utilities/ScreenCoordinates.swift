import AppKit
import ScreenCaptureKit

/// Conversions between the two global coordinate spaces on macOS:
///
/// - **AppKit** (`NSScreen.frame`, selection rects): origin at the
///   bottom-left of the primary display, Y grows upward.
/// - **CoreGraphics / ScreenCaptureKit** (`SCDisplay.frame`,
///   `SCWindow.frame`, `CGWindowListCreateImage`): origin at the top-left
///   of the primary display, Y grows downward.
///
/// The two spaces coincide only on the primary display, so any comparison
/// or capture that mixes them silently works single-display and breaks on
/// externals (typically as a black image from an out-of-bounds sourceRect).
@MainActor
enum ScreenCoordinates {

    /// Both spaces flip around the primary display's height. The primary
    /// display is always `NSScreen.screens[0]`.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitRect(fromCG rect: CGRect) -> CGRect {
        // The flip is its own inverse.
        cgRect(fromAppKit: rect)
    }

    /// The SCDisplay backing an NSScreen. Matches by display ID — never by
    /// geometry, since SCDisplay frames are CG-space and NSScreen frames
    /// are AppKit-space. Falls back to a CG-space geometric match only if
    /// the ID lookup fails (e.g. the display list changed mid-capture).
    static func display(for screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        if let id = screen.displayID, let match = displays.first(where: { $0.displayID == id }) {
            return match
        }
        let cgFrame = cgRect(fromAppKit: screen.frame)
        return displays
            .map { (display: $0, overlap: $0.frame.intersection(cgFrame)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .display
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
