import AppKit
import XCTest
@testable import ShotnixCore

/// Driving and photographing recording UI without clicking the real app:
/// synthesized mouse events into offscreen windows, and PNG renders.
@MainActor
enum RecordingUITestSupport {
    /// A point no display covers, so test windows never flash on screen.
    static let offscreen = NSPoint(x: -30_000, y: -30_000)

    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    static func button(labelled label: String, in window: NSWindow) -> NSButton? {
        guard let root = window.contentView else { return nil }
        return allSubviews(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == label && !$0.isHidden }
    }

    /// A real click: mouse-down sent to the window, mouse-up queued for the
    /// button's tracking loop — the path a user's click takes.
    static func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.05, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    static func keyDown(_ characters: String, keyCode: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    static func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Renders a window's content over a dark desktop-like backdrop, 2x.
    @discardableResult
    static func writeSnapshot(of window: NSWindow, name: String) throws -> URL {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.display()
        let size = view.bounds.size
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let padding: CGFloat = 16
        let canvasSize = NSSize(width: (size.width + padding * 2) * scale, height: (size.height + padding * 2) * scale)
        let canvas = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.52, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvasSize).fill()
        rep.draw(in: NSRect(x: padding * scale, y: padding * scale, width: size.width * scale, height: size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-\(name).png")
        let png = try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("SNAPSHOT-\(name.uppercased()): \(url.path)")
        return url
    }
}
