#!/usr/bin/env swift
// Generates Shotnix.app icon as an iconset + .icns
// Run: swift make-icon.swift

import AppKit
import CoreGraphics

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let pad = size * 0.12
    let inner = rect.insetBy(dx: pad, dy: pad)
    let radius = size * 0.22

    // --- Background: deep blue-to-purple gradient with Big Sur rounding ---
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    ctx.addPath(path)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.18, green: 0.40, blue: 0.98, alpha: 1), // vivid blue
            CGColor(red: 0.48, green: 0.20, blue: 0.92, alpha: 1), // purple
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: 0),
        options: []
    )

    ctx.resetClip()

    // --- Dashed selection rectangle (screenshot region indicator) ---
    let selPad = size * 0.20
    let selRect = rect.insetBy(dx: selPad, dy: selPad)
    let selRadius: CGFloat = size * 0.06
    let selPath = CGMutablePath()
    selPath.addRoundedRect(in: selRect, cornerWidth: selRadius, cornerHeight: selRadius)

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(size * 0.045)
    ctx.setLineDash(phase: 0, lengths: [size * 0.10, size * 0.06])
    ctx.addPath(selPath)
    ctx.strokePath()

    // --- Corner handles (solid white squares at corners) ---
    ctx.setLineDash(phase: 0, lengths: [])
    let handleSize = size * 0.085
    let handleThick = size * 0.055
    let corners: [(CGFloat, CGFloat)] = [
        (selRect.minX, selRect.minY),
        (selRect.maxX, selRect.minY),
        (selRect.minX, selRect.maxY),
        (selRect.maxX, selRect.maxY),
    ]
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(handleThick)
    ctx.setLineCap(.round)
    for (cx, cy) in corners {
        let dx: CGFloat = cx == selRect.minX ? 1 : -1
        let dy: CGFloat = cy == selRect.minY ? 1 : -1
        // horizontal arm
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + dx * handleSize, y: cy))
        // vertical arm
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy * handleSize))
    }
    ctx.strokePath()

    // --- Crosshair center dot ---
    let dotR = size * 0.045
    let center = CGPoint(x: rect.midX, y: rect.midY)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR*2, height: dotR*2))

    // Crosshair lines
    let crossLen = size * 0.10
    let crossGap = dotR + size * 0.025
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(size * 0.030)
    ctx.setLineCap(.round)
    // horizontal
    ctx.move(to: CGPoint(x: center.x - crossLen - crossGap, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x - crossGap, y: center.y))
    ctx.move(to: CGPoint(x: center.x + crossGap, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + crossLen + crossGap, y: center.y))
    // vertical
    ctx.move(to: CGPoint(x: center.x, y: center.y - crossLen - crossGap))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y - crossGap))
    ctx.move(to: CGPoint(x: center.x, y: center.y + crossGap))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + crossLen + crossGap))
    ctx.strokePath()

    // --- Subtle inner shadow on top edge for depth ---
    ctx.addPath(path)
    ctx.clip()
    let shadowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.18),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(shadowGrad,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.maxY - size * 0.15),
        options: []
    )

    img.unlockFocus()
    return img
}

func pngData(from image: NSImage) -> Data {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(Int, String)] = [
    (16,   "icon_16x16"),
    (32,   "icon_16x16@2x"),
    (32,   "icon_32x32"),
    (64,   "icon_32x32@2x"),
    (128,  "icon_128x128"),
    (256,  "icon_128x128@2x"),
    (256,  "icon_256x256"),
    (512,  "icon_256x256@2x"),
    (512,  "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetDir = URL(fileURLWithPath: "Shotnix.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let img = drawIcon(size: CGFloat(size))
    let data = pngData(from: img)
    let url = iconsetDir.appendingPathComponent("\(name).png")
    try! data.write(to: url)
    print("  wrote \(name).png (\(size)px)")
}

print("▶ Running iconutil…")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "Shotnix.iconset", "-o", "Shotnix.icns"]
try! task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✓ Shotnix.icns created")
} else {
    print("✗ iconutil failed")
    exit(1)
}
