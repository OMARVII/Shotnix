import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// The picture an image annotation shows: a logo, a watermark, a
/// screenshot. It's pinned to the frame (zooms don't move it), sized as a
/// fraction of the frame's width, and kept at its own shape.
struct VideoOverlayImage: Codable, Equatable {
    /// Shotnix's own copy (Application Support), so moving or deleting the
    /// original never breaks the draft.
    var path: String
    /// The file name it was added from.
    var name: String
    /// Width / height.
    var aspect: Double
    var opacity: Double = 1

    init(path: String, name: String, aspect: Double, opacity: Double = 1) {
        self.path = path
        self.name = name
        self.aspect = aspect
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey { case path, name, aspect, opacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

/// Where an image can snap to.
enum VideoImagePlacement: String, CaseIterable, Identifiable {
    case topLeft, topRight, center, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .center: return "circle.dotted"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }

    /// Center (output-normalized, y down) for an image `width` wide (a
    /// fraction of the frame's width) with a margin of 4% of the short side.
    func center(width: Double, aspect: Double, canvas: CGSize) -> CGPoint {
        guard canvas.width > 0, canvas.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let margin = Double(min(canvas.width, canvas.height)) * 0.04
        let w = Double(canvas.width) * width
        let h = w / max(aspect, 0.01)
        let left = (margin + w / 2) / Double(canvas.width)
        let right = 1 - left
        let top = (margin + h / 2) / Double(canvas.height)
        let bottom = 1 - top
        switch self {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }
}

extension VideoDemoOverlayEffect {
    /// An image annotation's rect in an output frame of `size` pixels
    /// (bottom-left origin).
    func imageRect(in size: CGSize) -> CGRect {
        let aspect = CGFloat(max(image?.aspect ?? 1, 0.01))
        let w = size.width * CGFloat(min(max(width, 0.02), 1))
        let h = w / aspect
        let cx = size.width * CGFloat(x)
        let cy = size.height * (1 - CGFloat(y))
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Stored copies

/// Pictures and music added to a video are copied here, so the draft keeps
/// working when the originals move.
enum VideoAssetStore {
    static var folder: URL {
        VideoStorageLocation.root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoAssets", isDirectory: true)
    }

    /// Copies `url` in (a clone on the same disk, so it's instant and takes
    /// no extra space there). Files already inside are returned as-is.
    static func importFile(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        if source.deletingLastPathComponent().path == folder.standardizedFileURL.resolvingSymlinksInPath().path {
            return source
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try fileManager.copyItem(at: source, to: destination)
        // A copy keeps the original's date: stamp it, so the cleanup's grace
        // day covers edits no draft has saved yet.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return destination
    }

    static func isStored(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }
}

// MARK: - Rendering

enum VideoImageOverlayRenderer {
    private static let cache = NSCache<NSString, CIImage>()

    /// The picture, decoded once (at most 2048 px on its long side) with
    /// its alpha kept.
    static func picture(path: String) -> CIImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Pixel size (upright) of the picture at `url`.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The image placed into `rect` (output pixels), faded to `opacity`.
    static func placed(_ picture: CIImage, in rect: CGRect, opacity: Double) -> CIImage {
        let extent = picture.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0.5, rect.height > 0.5 else { return CIImage.empty() }
        let sx = rect.width / extent.width
        let sy = rect.height / extent.height
        var image = picture.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if sy < 0.75 {
            // Big pictures shrunk a lot get a proper filter (no shimmer):
            // Lanczos scales y by the scale, x by scale × aspect ratio.
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            let scaled = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: rect.minX - scaled.minX, y: rect.minY - scaled.minY))
        } else {
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(opacity, 0)))])
        }
        return image
    }
}

// MARK: - Editing

extension VideoEditorModel {
    /// Picks a picture and adds it at the playhead.
    func chooseImageOverlay() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a logo, watermark, or screenshot to place on the video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addImageOverlay(from: url)
    }

    @discardableResult
    func addImageOverlay(from url: URL, at time: Double? = nil) -> UUID? {
        guard let size = VideoImageOverlayRenderer.pixelSize(of: url),
              let stored = try? VideoAssetStore.importFile(url) else {
            showNotice("Couldn't open that image", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        let aspect = Double(size.width / size.height)
        let at = time ?? clock.time
        let sourceStart = placementSourceTime(forTimeline: at)
        let sourceEnd = sourceTime(forTimeline: min(at + 5, timelineDuration))
        let canvas = project.canvasSize()
        // Small pictures are logos (a corner); big ones are screenshots (centered).
        let isLogo = size.width <= 900 && size.height <= 900
        let width = isLogo ? 0.14 : 0.5
        let placement: VideoImagePlacement = isLogo ? .topRight : .center
        let center = placement.center(width: width, aspect: aspect, canvas: canvas)
        var effect = VideoDemoOverlayEffect(
            kind: .image,
            time: sourceStart,
            duration: max(sourceEnd - sourceStart, 0.5),
            x: Double(center.x),
            y: Double(center.y),
            width: width,
            height: width * Double(canvas.width) / aspect / Double(max(canvas.height, 1)),
            text: url.deletingPathExtension().lastPathComponent
        )
        effect.image = VideoOverlayImage(path: stored.path, name: url.lastPathComponent, aspect: aspect)
        let overlapping = project.overlayEffects.filter { $0.time < effect.time + effect.duration && $0.time + $0.duration > effect.time }
        effect.layer = (overlapping.map(\.layer).max() ?? -1) + 1
        mutate { project in
            project.overlayEffects.append(effect)
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        }
        selection = .overlay(effect.id)
        return effect.id
    }

    func setImageOpacity(_ id: UUID, _ opacity: Double) {
        updateOverlay(id, coalesce: "image-opacity-\(id)") { effect in
            effect.image?.opacity = min(max(opacity, 0.05), 1)
        }
    }

    func setImageWidth(_ id: UUID, _ width: Double) {
        updateOverlay(id, coalesce: "image-size-\(id)") { effect in
            effect.width = min(max(width, 0.04), 1)
        }
    }

    func placeImage(_ id: UUID, _ placement: VideoImagePlacement) {
        guard let effect = project.overlayEffects.first(where: { $0.id == id }), let image = effect.image else { return }
        let center = placement.center(width: effect.width, aspect: image.aspect, canvas: project.canvasSize())
        updateOverlay(id) { effect in
            effect.x = Double(center.x)
            effect.y = Double(center.y)
        }
    }

    /// Shows the image from the first moment of the video to the last.
    func showImageForWholeVideo(_ id: UUID) {
        guard let first = segments.first, let last = segments.last else { return }
        updateOverlay(id) { effect in
            effect.time = first.clip.sourceStart
            effect.duration = max(last.clip.sourceEnd - first.clip.sourceStart, 0.2)
        }
    }

    func replaceImage(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let size = VideoImageOverlayRenderer.pixelSize(of: url),
              let stored = try? VideoAssetStore.importFile(url) else { return }
        updateOverlay(id) { effect in
            let opacity = effect.image?.opacity ?? 1
            effect.image = VideoOverlayImage(path: stored.path, name: url.lastPathComponent, aspect: Double(size.width / size.height), opacity: opacity)
            effect.text = url.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - Preview handles

/// Move and resize handles for the selected image, in frame space (zooms
/// don't move it). Corners resize around the opposite corner, keeping the
/// picture's shape.
struct VideoImageOverlayHandles: View {
    @ObservedObject var model: VideoEditorModel
    let effect: VideoDemoOverlayEffect
    let viewSize: CGSize

    @State private var origin: VideoDemoOverlayEffect?

    private var rect: CGRect {
        let r = effect.imageRect(in: viewSize)
        return CGRect(x: r.minX, y: viewSize.height - r.maxY, width: r.width, height: r.height)
    }

    var body: some View {
        let frame = rect
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(Color.white.opacity(0.001))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if origin?.id != effect.id { origin = effect }
                            guard let origin else { return }
                            NSCursor.closedHand.set()
                            model.updateOverlay(effect.id, coalesce: "image-move-\(effect.id)") { overlay in
                                overlay.x = origin.x + Double(value.translation.width / max(viewSize.width, 1))
                                overlay.y = origin.y + Double(value.translation.height / max(viewSize.height, 1))
                            }
                        }
                        .onEnded { _ in
                            origin = nil
                            model.endGesture()
                        }
                )
                .help("Drag to move; drag a corner to resize")

            ForEach(0..<4, id: \.self) { corner in
                let isRight = corner == 1 || corner == 3
                let isBottom = corner >= 2
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .contentShape(Circle().inset(by: -7))
                    .offset(x: (isRight ? frame.maxX : frame.minX) - 5.5, y: (isBottom ? frame.maxY : frame.minY) - 5.5)
                    .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if origin?.id != effect.id { origin = effect }
                                guard let origin else { return }
                                resize(from: origin, isRight: isRight, isBottom: isBottom, translation: value.translation)
                            }
                            .onEnded { _ in
                                origin = nil
                                model.endGesture()
                            }
                    )
            }
        }
    }

    private func resize(from origin: VideoDemoOverlayEffect, isRight: Bool, isBottom: Bool, translation: CGSize) {
        let aspect = CGFloat(max(origin.image?.aspect ?? 1, 0.01))
        let start = origin.imageRect(in: viewSize)
        // Top-left space: the corner opposite the one dragged stays put.
        let startTop = CGRect(x: start.minX, y: viewSize.height - start.maxY, width: start.width, height: start.height)
        let fixed = CGPoint(x: isRight ? startTop.minX : startTop.maxX, y: isBottom ? startTop.minY : startTop.maxY)
        let dragged = CGPoint(x: (isRight ? startTop.maxX : startTop.minX) + translation.width, y: (isBottom ? startTop.maxY : startTop.minY) + translation.height)
        // Follow whichever direction moved further, at the picture's shape.
        let widthFromX = abs(dragged.x - fixed.x)
        let widthFromY = abs(dragged.y - fixed.y) * aspect
        let width = max(max(widthFromX, widthFromY), viewSize.width * 0.04)
        let height = width / aspect
        let minX = isRight ? fixed.x : fixed.x - width
        let minY = isBottom ? fixed.y : fixed.y - height
        model.updateOverlay(effect.id, coalesce: "image-resize-\(effect.id)") { overlay in
            overlay.width = Double(width / max(viewSize.width, 1))
            overlay.x = Double((minX + width / 2) / max(viewSize.width, 1))
            overlay.y = Double((minY + height / 2) / max(viewSize.height, 1))
        }
    }
}

// MARK: - Inspector

struct VideoImageOverlayInspector: View {
    @ObservedObject var model: VideoEditorModel
    let overlay: VideoDemoOverlayEffect

    var body: some View {
        if let image = overlay.image {
            VideoInspectorSection("Image") {
                HStack(spacing: 10) {
                    thumbnail(image)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(image.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VideoEditorTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Replace…") { model.replaceImage(overlay.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                if !FileManager.default.fileExists(atPath: image.path) {
                    Label("The picture's file is gone — choose it again with Replace.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VideoSliderRow(
                    title: "Opacity",
                    value: Binding(get: { image.opacity }, set: { model.setImageOpacity(overlay.id, $0) }),
                    range: 0.05...1,
                    defaultValue: 1,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoSliderRow(
                    title: "Size",
                    value: Binding(get: { overlay.width }, set: { model.setImageWidth(overlay.id, $0) }),
                    range: 0.04...1,
                    defaultValue: nil,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    detail: "Of the frame's width.",
                    onEditingEnded: { model.endGesture() }
                )
            }
            VideoInspectorSection("Position") {
                HStack(spacing: 6) {
                    ForEach(VideoImagePlacement.allCases) { placement in
                        Button {
                            model.placeImage(overlay.id, placement)
                        } label: {
                            Image(systemName: placement.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                        }
                        .buttonStyle(VideoSecondaryButtonStyle())
                        .help(placement.title)
                        .accessibilityLabel(placement.title)
                    }
                }
                Text("Or drag it on the preview. Images stay put while the camera zooms.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VideoInspectorSection("Timing") {
                Button {
                    model.showImageForWholeVideo(overlay.id)
                } label: {
                    Label("Show for the whole video", systemImage: "arrow.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                Text("Or drag its bar on the timeline.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: VideoOverlayImage) -> some View {
        let picture = VideoBackgroundRenderer.thumbnail(path: image.path, maxPixel: 120)
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
        }
        .frame(width: 52, height: 40)
    }
}
