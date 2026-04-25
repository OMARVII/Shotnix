#!/usr/bin/env swift
import AppKit
import CoreGraphics

// The window is 600x400 points. We MUST generate a 600x400 image so create-dmg
// maps it 1:1 to the window coordinate system.
let width: CGFloat = 600
let height: CGFloat = 400

let img = NSImage(size: NSSize(width: width, height: height))
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// --- Deep Space Background ---
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0),
        CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    bgGradient,
    startCenter: CGPoint(x: width * 0.5, y: height * 0.4),
    startRadius: 0,
    endCenter: CGPoint(x: width * 0.5, y: height * 0.4),
    endRadius: width * 0.8,
    options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
)

// --- Spotlight effect from bottom ---
let spotlight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    spotlight,
    startCenter: CGPoint(x: width * 0.5, y: -50),
    startRadius: 0,
    endCenter: CGPoint(x: width * 0.5, y: -50),
    endRadius: height * 0.8,
    options: [.drawsAfterEndLocation]
)

// Add noise texture
if let noiseImg = CGImage.createNoiseImage(width: Int(width), height: Int(height)) {
    ctx.setBlendMode(.screen)
    ctx.setAlpha(0.02)
    ctx.draw(noiseImg, in: CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setBlendMode(.normal)
    ctx.setAlpha(1.0)
}

// --- Warp-style Inline Arrow ---
// create-dmg places icons at Y=175pt from top.
// Center of 128pt image is ~164pt from top.
// CoreGraphics Y is from bottom: 400 - 164 = 236
let arrowY: CGFloat = 236
let text = "INSTALL SHOTNIX"

let font = NSFont.systemFont(ofSize: 11, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.4),
    .kern: 1.5
]
let attrText = NSAttributedString(string: text, attributes: attributes)
let textSize = attrText.size()

// Positions
let centerX = width / 2
let textPadding: CGFloat = 12
let textX = centerX - (textSize.width / 2)
// Adjust textY to optically center it vertically with the line
// CoreGraphics Y is from bottom, so subtracting moves it DOWN
let textY = arrowY - (textSize.height / 2) - 2

let leftLineStart: CGFloat = 200
let leftLineEnd = textX - textPadding

let rightLineStart = textX + textSize.width + textPadding
let rightLineEnd: CGFloat = 400

ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.3))
ctx.setLineWidth(1.5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Left line segment
ctx.move(to: CGPoint(x: leftLineStart, y: arrowY))
ctx.addLine(to: CGPoint(x: leftLineEnd, y: arrowY))
ctx.strokePath()

// Right line segment
ctx.move(to: CGPoint(x: rightLineStart, y: arrowY))
ctx.addLine(to: CGPoint(x: rightLineEnd, y: arrowY))
ctx.strokePath()

// Arrow head
let headSize: CGFloat = 6
ctx.move(to: CGPoint(x: rightLineEnd, y: arrowY))
ctx.addLine(to: CGPoint(x: rightLineEnd - headSize, y: arrowY + headSize * 0.8))
ctx.move(to: CGPoint(x: rightLineEnd, y: arrowY))
ctx.addLine(to: CGPoint(x: rightLineEnd - headSize, y: arrowY - headSize * 0.8))
ctx.strokePath()

// Draw Text
attrText.draw(at: NSPoint(x: textX, y: textY))

// --- Icon Glows ---
func drawGlow(at center: CGPoint, radius: CGFloat, color: CGColor) {
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color, CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

// Glow under icons
drawGlow(at: CGPoint(x: 120, y: arrowY), radius: 80,
         color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08))
drawGlow(at: CGPoint(x: 480, y: arrowY), radius: 80,
         color: CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.06))

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let pngData = rep.representation(using: .png, properties: [:])!
let outputURL = URL(fileURLWithPath: "dmg-background.png")
try! pngData.write(to: outputURL)
print("✓ dmg-background.png created (600x400)")

extension CGImage {
    static func createNoiseImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        for i in 0..<(width * height) {
            buffer[i] = UInt8.random(in: 0...255)
        }
        return context.makeImage()
    }
}
