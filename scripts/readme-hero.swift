import AppKit
import Foundation

// The README's hero, one frame at a time: the editor render (playhead
// hidden) with the exported demo playing in its preview, the playhead moving
// along the timeline, the running timecode and the pause icon, as the editor
// looks during playback. scripts/readme-hero.sh runs it and encodes the result.
//
// usage: readme-hero <shotnix-editor-frame.png> <demo-frames-dir> <out-dir> <width> [fps]
// Geometry is in points of the 1512 × 944 window, as measured by
// scripts/website-editor-demo.py.

let args = CommandLine.arguments
let base = NSImage(contentsOfFile: args[1])!
let framesDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let outWidth = CGFloat(Double(args[4])!)

let window = CGSize(width: 1512, height: 944)
let preview = CGRect(x: 141, y: 135, width: 912, height: 513)
let timelineTop: CGFloat = 716, timelineBottom: CGFloat = 944
let originX: CGFloat = 17.75, pointsPerSecond: CGFloat = 118.6
let timeLabel = CGRect(x: 52.5, y: 681.75, width: 47.5, height: 22)
let playButton = CGRect(x: 14, y: 680, width: 30, height: 26)
let fps = args.count > 5 ? Double(args[5])! : 30

let scale = outWidth / window.width
let pixelSize = CGSize(width: outWidth.rounded(), height: (window.height * scale).rounded())

// Draw in the render's own color space, and fill with its exact pixels, so
// patched areas can't differ from the render around them.
let baseImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
let basePixels: [UInt8] = {
    let w = baseImage.width, h = baseImage.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    return data
}()

func baseColor(at point: CGPoint) -> NSColor {
    let s = CGFloat(baseImage.width) / window.width
    let i = (Int(point.y * s) * baseImage.width + Int(point.x * s)) * 4
    let rgb = [basePixels[i], basePixels[i + 1], basePixels[i + 2]].map { CGFloat($0) / 255 }
    return NSColor(cgColor: CGColor(colorSpace: colorSpace, components: rgb + [1])!)!
}

let labelBackground = baseColor(at: CGPoint(x: timeLabel.minX - 2, y: timeLabel.midY))
let buttonFill = baseColor(at: CGPoint(x: playButton.minX + 4, y: playButton.midY))

// VideoEditorTheme.playhead and .textPrimary; the transport bar's timecode
// font. The 2-point nudge and 13.5-point symbol match the render pixel for
// pixel (it was drawn at 2× and scaled down).
let playhead = NSColor(srgbRed: 1.0, green: 0.31, blue: 0.43, alpha: 1)
let textPrimary = NSColor(white: 1, alpha: 0.93)
let timecodeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
let timecodeNudge: CGFloat = 2
let pause: NSImage = {
    let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [textPrimary]))
    return NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}()

func timecode(_ seconds: Double) -> String {
    String(format: "%d:%02d.%d", Int(seconds) / 60, Int(seconds) % 60, Int((seconds - Double(Int(seconds))) * 10))
}

/// VideoTimelineView's PlayheadKnob, in a flipped context.
func knob(in rect: CGRect) -> NSBezierPath {
    let r: CGFloat = 3
    let path = NSBezierPath()
    path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + r), controlPoint1: CGPoint(x: rect.maxX, y: rect.minY), controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
    path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
    path.line(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.line(to: CGPoint(x: rect.minX, y: rect.maxY - 6))
    path.line(to: CGPoint(x: rect.minX, y: rect.minY + r))
    path.curve(to: CGPoint(x: rect.minX + r, y: rect.minY), controlPoint1: CGPoint(x: rect.minX, y: rect.minY), controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
    path.close()
    return path
}

func render(time: Double, video: NSImage) -> CGImage {
    let cg = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.interpolationQuality = .high
    cg.translateBy(x: 0, y: pixelSize.height)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    base.draw(in: CGRect(origin: .zero, size: window), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    video.draw(in: preview, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

    labelBackground.setFill()
    timeLabel.fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: timecodeFont, .foregroundColor: textPrimary]
    let text = timecode(time) as NSString
    let size = text.size(withAttributes: attributes)
    text.draw(at: CGPoint(x: timeLabel.minX + timecodeNudge, y: timeLabel.midY - size.height / 2), withAttributes: attributes)

    buttonFill.setFill()
    CGRect(x: playButton.midX - 8, y: playButton.midY - 8, width: 16, height: 16).fill()
    pause.draw(in: CGRect(x: playButton.midX - pause.size.width / 2, y: playButton.midY - pause.size.height / 2, width: pause.size.width, height: pause.size.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

    let x = originX + CGFloat(time) * pointsPerSecond
    playhead.setFill()
    CGRect(x: x - 1, y: timelineTop, width: 2, height: timelineBottom - timelineTop).fill()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    knob(in: CGRect(x: x - 6.5, y: timelineTop, width: 13, height: 17)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return cg.makeImage()!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let frames = try FileManager.default.contentsOfDirectory(atPath: framesDir.path).filter { $0.hasSuffix(".png") }.sorted()
for (index, name) in frames.enumerated() {
    autoreleasepool {
        let image = render(time: Double(index) / fps, video: NSImage(contentsOf: framesDir.appendingPathComponent(name))!)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try! data.write(to: outDir.appendingPathComponent(String(format: "h%04d.png", index + 1)))
    }
}
print("\(frames.count) frames at \(Int(pixelSize.width))×\(Int(pixelSize.height))")
