import AppKit

struct ScreenshotBackgroundOptions: Equatable {
    enum Style: String {
        case solid
        case gradient
        case image
    }

    var isEnabled: Bool
    var style: Style
    var presetName: String
    var colorHex: String
    var gradientStartHex: String
    var gradientEndHex: String
    var accentHexes: [String]
    var customImageData: Data?
    var customImageName: String?
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: CGFloat

    static let imagePresets: [ScreenshotBackgroundImagePreset] = [
        .init(name: "Amber Fold", startHex: "#1c0b0f", endHex: "#f46f2f", accentHexes: ["#ffb45a", "#7b2dff", "#f93673"]),
        .init(name: "Cobalt Drapes", startHex: "#071425", endHex: "#1b6dff", accentHexes: ["#ff7a3d", "#8cb7ff", "#3514b8"]),
        .init(name: "Crimson Ridge", startHex: "#250617", endHex: "#f05b55", accentHexes: ["#ffb24a", "#7a2cff", "#ff4fa3"]),
        .init(name: "Night Current", startHex: "#050714", endHex: "#4656c6", accentHexes: ["#c33a5d", "#0f2149", "#5b8dff"]),
        .init(name: "Tide Glass", startHex: "#0a2432", endHex: "#5fb6d9", accentHexes: ["#f0664f", "#103b66", "#b4e8ff"]),
        .init(name: "Desert Violet", startHex: "#261126", endHex: "#dc6b8d", accentHexes: ["#ff8d4a", "#7d3cff", "#f6d6b7"]),
        .init(name: "Rose Smoke", startHex: "#381631", endHex: "#f095bb", accentHexes: ["#ffcfcc", "#8033a8", "#f1597f"]),
        .init(name: "Lime Signal", startHex: "#0c1710", endHex: "#9fd72a", accentHexes: ["#25a36f", "#f2ff8a", "#395ed8"]),
        .init(name: "Violet Bloom", startHex: "#10081e", endHex: "#8d4cff", accentHexes: ["#f06ab9", "#6645ff", "#f0ddff"]),
        .init(name: "Canyon Silk", startHex: "#2b150d", endHex: "#e8a75d", accentHexes: ["#f66547", "#ffd4a8", "#6067ff"]),
        .init(name: "Pine Dusk", startHex: "#081a1f", endHex: "#173b3d", accentHexes: ["#88a9a5", "#0d2d38", "#1a535c"]),
        .init(name: "Aqua Marble", startHex: "#dff9f4", endHex: "#efc6d8", accentHexes: ["#61d1ca", "#ff8dac", "#ffffff"]),
        .init(name: "Sky Wash", startHex: "#cbe8ff", endHex: "#f0c28a", accentHexes: ["#6db4ff", "#f27b5b", "#ffffff"]),
        .init(name: "Carbon Arc", startHex: "#06070d", endHex: "#202944", accentHexes: ["#d3345d", "#4c73ff", "#ffb16f"]),
        .init(name: "Prism Sweep", startHex: "#07151c", endHex: "#f5d765", accentHexes: ["#20c7b4", "#f9687d", "#397cff"])
    ]

    static let editorDefault = ScreenshotBackgroundOptions(
        isEnabled: false,
        style: .gradient,
        presetName: "Neo Pop",
        colorHex: "#f4eadb",
        gradientStartHex: "#6a2cff",
        gradientEndHex: "#ffd36a",
        accentHexes: ["#ff7ac8", "#6af7ff", "#fff6b0"],
        customImageData: nil,
        customImageName: nil,
        padding: 72,
        cornerRadius: 18,
        shadow: 0.32
    )
}

struct ScreenshotBackgroundImagePreset: Equatable {
    let name: String
    let startHex: String
    let endHex: String
    let accentHexes: [String]
}

enum ScreenshotBackgroundComposer {

    static func composeIfNeeded(_ image: NSImage, options: ScreenshotBackgroundOptions) -> NSImage {
        guard options.isEnabled else { return image }
        guard let source = image.bestCGImage else { return image }

        let sourcePointSize = image.size
        guard sourcePointSize.width > 0, sourcePointSize.height > 0 else { return image }

        let scale = max(
            CGFloat(source.width) / sourcePointSize.width,
            CGFloat(source.height) / sourcePointSize.height,
            1
        )
        let padding = clamped(options.padding, min: 0, max: 240)
        let outputPointSize = NSSize(
            width: sourcePointSize.width + padding * 2,
            height: sourcePointSize.height + padding * 2
        )
        let pixelWidth = max(1, Int(ceil(outputPointSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(outputPointSize.height * scale)))

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)

        let outputRect = CGRect(origin: .zero, size: outputPointSize)
        drawBackground(in: context, rect: outputRect, options: options)

        let imageRect = pixelAligned(CGRect(origin: CGPoint(x: padding, y: padding), size: sourcePointSize), scale: scale)
        let radius = cornerRadius(for: imageRect, options: options)
        drawShadow(in: context, container: outputRect, rect: imageRect, radius: radius, intensity: clamped(options.shadow, min: 0, max: 1))

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.addPath(roundedPath(for: imageRect, radius: radius))
        context.clip()
        context.draw(source, in: imageRect)
        context.restoreGState()
        drawEdgeStroke(in: context, rect: imageRect, radius: radius, scale: scale)

        guard let composed = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: composed)
        rep.size = outputPointSize
        let output = NSImage(size: outputPointSize)
        output.addRepresentation(rep)
        return output
    }

    static func previewImage(options: ScreenshotBackgroundOptions, size: NSSize) -> NSImage {
        let pixelWidth = max(1, Int(ceil(size.width * 2)))
        let pixelHeight = max(1, Int(ceil(size.height * 2)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        context.scaleBy(x: 2, y: 2)
        context.interpolationQuality = .high
        drawBackground(in: context, rect: CGRect(origin: .zero, size: size), options: options)

        guard let preview = context.makeImage() else { return NSImage(size: size) }
        let rep = NSBitmapImageRep(cgImage: preview)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func drawBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions) {
        if options.style == .image {
            drawImageBackground(in: context, rect: rect, options: options)
            drawVignette(in: context, rect: rect)
            return
        }

        if options.style == .gradient {
            let start = color(from: options.gradientStartHex)
            let end = color(from: options.gradientEndHex)
            let colors = [start.cgColor, end.cgColor] as CFArray
            let colorSpace = start.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.minY),
                    end: CGPoint(x: rect.maxX, y: rect.maxY),
                    options: []
                )
                drawProceduralBlooms(in: context, rect: rect, options: options, start: start, end: end)
                drawVignette(in: context, rect: rect)
                return
            }
        }

        context.setFillColor(color(from: options.colorHex).cgColor)
        context.fill(rect)
        drawVignette(in: context, rect: rect)
    }

    private static func drawImageBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions) {
        if let data = options.customImageData,
           let image = NSImage(data: data),
           let cgImage = image.bestCGImage {
            context.draw(cgImage, in: aspectFillRect(for: CGSize(width: cgImage.width, height: cgImage.height), in: rect))
            return
        }

        let preset = ScreenshotBackgroundOptions.imagePresets.first { $0.name == options.presetName }
            ?? ScreenshotBackgroundOptions.imagePresets[0]
        drawPresetImageBackground(in: context, rect: rect, preset: preset)
    }

    private static func drawPresetImageBackground(in context: CGContext, rect: CGRect, preset: ScreenshotBackgroundImagePreset) {
        let start = color(from: preset.startHex)
        let end = color(from: preset.endHex)
        let colorSpace = start.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [start.cgColor, end.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        } else {
            context.setFillColor(start.cgColor)
            context.fill(rect)
        }

        let accents = preset.accentHexes.map(color(from:))
        for (index, accent) in accents.enumerated() {
            let center = presetCenter(in: rect, index: index)
            let radius = max(rect.width, rect.height) * (index == 0 ? 0.72 : 0.52)
            drawGradientGlow(in: context, rect: rect, color: accent, center: center, radius: radius, alpha: index == 0 ? 0.38 : 0.28)
        }

        for index in 0..<3 {
            drawSilkBand(in: context, rect: rect, color: accents[index % max(accents.count, 1)], index: index)
        }
    }

    private static func presetCenter(in rect: CGRect, index: Int) -> CGPoint {
        let centers = [
            CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.78),
            CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.24),
            CGPoint(x: rect.minX + rect.width * 0.56, y: rect.minY + rect.height * 0.58),
            CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.18)
        ]
        return centers[index % centers.count]
    }

    private static func drawSilkBand(in context: CGContext, rect: CGRect, color: NSColor, index: Int) {
        let offset = CGFloat(index) * rect.height * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX - rect.width * 0.18, y: rect.midY - rect.height * 0.18 + offset))
        path.addCurve(
            to: CGPoint(x: rect.maxX + rect.width * 0.18, y: rect.midY + rect.height * 0.06 + offset),
            control1: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY - rect.height * 0.10 + offset),
            control2: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY + rect.height * 0.18 + offset)
        )
        path.addLine(to: CGPoint(x: rect.maxX + rect.width * 0.18, y: rect.midY + rect.height * 0.34 + offset))
        path.addCurve(
            to: CGPoint(x: rect.minX - rect.width * 0.18, y: rect.midY + rect.height * 0.08 + offset),
            control1: CGPoint(x: rect.midX + rect.width * 0.16, y: rect.maxY + rect.height * 0.42 + offset),
            control2: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.24 + offset)
        )
        path.closeSubpath()

        context.saveGState()
        context.addPath(path)
        context.setFillColor(color.withAlphaComponent(0.16).cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func aspectFillRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func drawProceduralBlooms(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions, start: NSColor, end: NSColor) {
        let fallback = [end, start]
        let accents = options.accentHexes.isEmpty ? fallback : options.accentHexes.map(color(from:))
        let centers = [
            CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.78),
            CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.22),
            CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.92),
            CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.18)
        ]

        for (index, color) in accents.prefix(4).enumerated() {
            let radius = max(rect.width, rect.height) * (index == 0 ? 0.68 : 0.48)
            drawGradientGlow(in: context, rect: rect, color: color, center: centers[index], radius: radius, alpha: index == 0 ? 0.34 : 0.24)
        }
    }

    private static func drawGradientGlow(in context: CGContext, rect: CGRect, color: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let colors = [
            color.withAlphaComponent(alpha).cgColor,
            color.withAlphaComponent(0).cgColor
        ] as CFArray
        let colorSpace = color.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
    }

    private static func drawVignette(in context: CGContext, rect: CGRect) {
        let colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.12).cgColor
        ] as CFArray
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.52, 1]) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: min(rect.width, rect.height) * 0.14,
            endCenter: center,
            endRadius: max(rect.width, rect.height) * 0.72,
            options: .drawsAfterEndLocation
        )
    }

    private static func drawShadow(in context: CGContext, container: CGRect, rect: CGRect, radius: CGFloat, intensity: CGFloat) {
        guard intensity > 0 else { return }

        let path = roundedPath(for: rect, radius: radius)
        let outerRect = container.insetBy(dx: -120, dy: -120)
        let shadowClip = CGMutablePath()
        shadowClip.addRect(outerRect)
        shadowClip.addPath(path)

        context.saveGState()
        context.addPath(shadowClip)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: CGSize(width: 0, height: -18 * intensity),
            blur: 42 * intensity,
            color: NSColor.black.withAlphaComponent(0.45 * intensity).cgColor
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawEdgeStroke(in context: CGContext, rect: CGRect, radius: CGFloat, scale: CGFloat) {
        let lineWidth = CGFloat(1) / max(scale, 1)
        let strokeRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let strokeRadius = max(0, radius - lineWidth / 2)

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.addPath(roundedPath(for: strokeRect, radius: strokeRadius))
        context.strokePath()
        context.restoreGState()
    }

    private static func color(from hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        }
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private static func cornerRadius(for rect: CGRect, options: ScreenshotBackgroundOptions) -> CGFloat {
        min(clamped(options.cornerRadius, min: 0, max: 36), min(rect.width, rect.height) / 2)
    }

    private static func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }
}
