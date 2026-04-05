#!/usr/bin/env swift
// Generates the DMG installer background image.
// Run: swift make-dmg-bg.swift

import AppKit
import CoreGraphics

let width: CGFloat = 1200  // 600pt window × 2x retina
let height: CGFloat = 800  // 400pt window × 2x retina

let img = NSImage(size: NSSize(width: width, height: height))
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: width, height: height)

// --- Dark gradient background matching app theme ---
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.10, green: 0.08, blue: 0.18, alpha: 1),  // deep dark purple
        CGColor(red: 0.14, green: 0.10, blue: 0.22, alpha: 1),  // slightly lighter
        CGColor(red: 0.10, green: 0.08, blue: 0.16, alpha: 1),  // back to dark
    ] as CFArray,
    locations: [0, 0.5, 1]
)!
ctx.drawRadialGradient(
    bgGradient,
    startCenter: CGPoint(x: width * 0.5, y: height * 0.55),
    startRadius: 0,
    endCenter: CGPoint(x: width * 0.5, y: height * 0.55),
    endRadius: width * 0.7,
    options: [.drawsAfterEndLocation]
)

// --- Subtle grid pattern for texture ---
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.02))
ctx.setLineWidth(0.5)
let gridSpacing: CGFloat = 40
var x: CGFloat = 0
while x < width {
    ctx.move(to: CGPoint(x: x, y: 0))
    ctx.addLine(to: CGPoint(x: x, y: height))
    x += gridSpacing
}
var y: CGFloat = 0
while y < height {
    ctx.move(to: CGPoint(x: 0, y: y))
    ctx.addLine(to: CGPoint(x: width, y: y))
    y += gridSpacing
}
ctx.strokePath()

// --- Arrow from app icon area to Applications area ---
// Icon centers: app at 150pt (300px), Applications at 450pt (900px), both at 185pt (370px) from top
let arrowY: CGFloat = height - 370  // flip for bottom-left origin
let arrowStartX: CGFloat = 380     // after app icon
let arrowEndX: CGFloat = 820       // before Applications icon

// Arrow body - gradient line
ctx.setLineCap(.round)
let arrowGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.40, green: 0.55, blue: 1.0, alpha: 0.6),
        CGColor(red: 0.60, green: 0.35, blue: 0.95, alpha: 0.6),
    ] as CFArray,
    locations: [0, 1]
)!

// Draw arrow shaft as a thick line
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.50, green: 0.45, blue: 0.95, alpha: 0.35))
ctx.setLineWidth(3)
ctx.setLineDash(phase: 0, lengths: [12, 8])
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 20, y: arrowY))
ctx.strokePath()
ctx.restoreGState()

// Arrow head
ctx.setFillColor(CGColor(red: 0.50, green: 0.45, blue: 0.95, alpha: 0.45))
ctx.setLineDash(phase: 0, lengths: [])
let headSize: CGFloat = 16
ctx.move(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - headSize, y: arrowY + headSize * 0.6))
ctx.addLine(to: CGPoint(x: arrowEndX - headSize, y: arrowY - headSize * 0.6))
ctx.closePath()
ctx.fillPath()

// --- App name at top ---
let titleFont = NSFont.systemFont(ofSize: 36, weight: .bold)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.85),
]
let title = NSAttributedString(string: "Shotnix", attributes: titleAttrs)
let titleSize = title.size()
title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 100))

// --- Tagline ---
let tagFont = NSFont.systemFont(ofSize: 18, weight: .regular)
let tagAttrs: [NSAttributedString.Key: Any] = [
    .font: tagFont,
    .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.4),
]
let tag = NSAttributedString(string: "Drag to Applications to install", attributes: tagAttrs)
let tagSize = tag.size()
tag.draw(at: NSPoint(x: (width - tagSize.width) / 2, y: height - 145))

// --- Subtle glow behind icon positions ---
func drawGlow(at center: CGPoint, radius: CGFloat, color: CGColor) {
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color, CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

// Glow behind app icon position
drawGlow(at: CGPoint(x: 300, y: arrowY), radius: 140,
         color: CGColor(red: 0.30, green: 0.40, blue: 0.98, alpha: 0.12))

// Glow behind Applications position
drawGlow(at: CGPoint(x: 900, y: arrowY), radius: 140,
         color: CGColor(red: 0.48, green: 0.30, blue: 0.92, alpha: 0.08))

img.unlockFocus()

// Save as PNG
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let pngData = rep.representation(using: .png, properties: [:])!
let outputURL = URL(fileURLWithPath: "dmg-background.png")
try! pngData.write(to: outputURL)
print("✓ dmg-background.png created (\(Int(width))×\(Int(height)))")
