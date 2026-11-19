import AppKit

/// A display's picture from the moment an area selection began. With
/// "Freeze the screen while selecting" on, the selection is made on this
/// still instead of the live screen, and the shot is cut from it: what was
/// on screen at the shortcut is what gets captured, however long selecting
/// takes.
struct FrozenScreen {
    /// At the display's pixel size, top row first.
    let image: CGImage
    /// The screen it shows, in AppKit space, when it was taken.
    let screenFrame: CGRect

    /// The part of the still `rect` (AppKit space) covers, on the same
    /// whole pixels a live capture of `rect` takes, and its size in points.
    /// nil when `rect` isn't on this screen.
    func cut(_ rect: CGRect) -> (image: CGImage, logicalSize: NSSize)? {
        let rect = rect.intersection(screenFrame)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / screenFrame.width
        let scaleY = CGFloat(image.height) / screenFrame.height
        // On whole pixels the way CaptureEngine puts a live capture (the
        // corner down to one, the size up): a fractional edge would have to
        // be interpolated.
        let x = floor((rect.minX - screenFrame.minX) * scaleX)
        let bottom = floor((rect.minY - screenFrame.minY) * scaleY)
        let width = ceil(rect.width * scaleX)
        let height = ceil(rect.height * scaleY)
        // The still's rows run from the top, AppKit's from the bottom.
        let pixels = CGRect(x: x, y: CGFloat(image.height) - bottom - height, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let cut = image.cropping(to: pixels) else { return nil }
        return (Self.ownPixels(cut) ?? cut, NSSize(width: pixels.width / scaleX, height: pixels.height / scaleY))
    }

    /// The same picture on pixels of its own. A crop shares the whole
    /// display's picture and keeps all of it in memory for as long as the
    /// shot lives, which in History is a long time.
    private static func ownPixels(_ image: CGImage) -> CGImage? {
        let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        let alpha: CGImageAlphaInfo = opaque.contains(image.alphaInfo) ? .noneSkipFirst : .premultipliedFirst
        guard let space = image.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue
              ) else { return nil }
        // Pixel for pixel, in the still's own color space: nothing is converted.
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
