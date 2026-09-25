import AppKit
import SwiftUI

/// Aspect choices while cropping (width / height in pixels; nil = free).
enum VideoCropAspect: String, CaseIterable, Identifiable {
    case free, widescreen, classic, square, vertical

    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "Free"
        case .widescreen: return "16:9"
        case .classic: return "4:3"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .widescreen: return 16 / 9
        case .classic: return 4 / 3
        case .square: return 1
        case .vertical: return 9 / 16
        }
    }
}

extension VideoEditorModel {
    func beginCrop() {
        pause()
        selection = .none
        cropBeforeEditing = project.crop
        projectBeforeCrop = project
        undoDepthBeforeCrop = undoDepth
        isCropping = true
        previewRenderer.invalidate()
    }

    /// Esc: back to the crop you had before.
    func cancelCrop() {
        if let before = cropBeforeEditing, before != project.crop {
            var withOldCrop = project
            withOldCrop.crop = before
            if let snapshot = projectBeforeCrop, withOldCrop == snapshot {
                // Only the crop changed: as if it never did.
                discardEdits(restoring: snapshot, undoDepth: undoDepthBeforeCrop)
            } else {
                setStyle { $0.crop = before }
            }
        }
        cropBeforeEditing = nil
        projectBeforeCrop = nil
        isCropping = false
        endGesture()
        refreshPlan()
    }

    func endCrop() {
        cropBeforeEditing = nil
        projectBeforeCrop = nil
        isCropping = false
        endGesture()
        refreshPlan()
        if !project.crop.isFull {
            showNotice("Cropped — cursor, zooms, and clicks follow", symbol: "crop")
        }
    }

    func setCrop(_ rect: VideoCropRect, coalesce: String = "crop") {
        setStyle(coalesce: coalesce) { $0.crop = rect.normalized }
    }

    func resetCrop() {
        setStyle { $0.crop = .full }
    }

    /// The largest centered crop with the given pixel aspect.
    func applyCropAspect(_ aspect: VideoCropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.ratio else { return }
        let source = project.sourceSize
        guard source.width > 0, source.height > 0 else { return }
        let sourceRatio = source.width / source.height
        var width = 1.0
        var height = 1.0
        if Double(ratio) < Double(sourceRatio) {
            width = Double(ratio / sourceRatio)
        } else {
            height = Double(sourceRatio / ratio)
        }
        let current = project.crop.normalized
        let centerX = current.x + current.width / 2
        let centerY = current.y + current.height / 2
        setCrop(VideoCropRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height), coalesce: "crop-aspect")
        endGesture()
    }
}

/// Crop frame over the full recording: dimmed outside, thirds grid inside,
/// eight handles, drag inside to move.
struct VideoCropOverlay: View {
    @ObservedObject var model: VideoEditorModel
    let viewSize: CGSize

    @State private var origin: VideoCropRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    var body: some View {
        let crop = model.project.crop.normalized
        let rect = CGRect(
            x: CGFloat(crop.x) * viewSize.width,
            y: CGFloat(crop.y) * viewSize.height,
            width: CGFloat(crop.width) * viewSize.width,
            height: CGFloat(crop.height) * viewSize.height
        )
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Thirds grid.
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 1)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .gesture(moveGesture)

            ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
                handleView(handle)
                    .position(position(of: handle, in: rect))
                    .gesture(resizeGesture(handle))
            }

            Text(sizeLabel(crop))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .offset(x: rect.minX + 8, y: rect.minY + 8)
                .allowsHitTesting(false)
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }

    private func sizeLabel(_ crop: VideoCropRect) -> String {
        let width = Int((model.project.sourceWidth * crop.width).rounded())
        let height = Int((model.project.sourceHeight * crop.height).rounded())
        return "\(width) × \(height)"
    }

    private func handleView(_ handle: Handle) -> some View {
        Group {
            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: handle.movesLeft || handle.movesRight ? 6 : 22, height: handle.movesTop || handle.movesBottom ? 6 : 22)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .contentShape(Rectangle().inset(by: -8))
        .onHover { inside in
            guard inside else { NSCursor.arrow.set(); return }
            if handle.isCorner {
                NSCursor.crosshair.set()
            } else if handle.movesLeft || handle.movesRight {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.resizeUpDown.set()
            }
        }
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        let x = handle.movesLeft ? rect.minX : (handle.movesRight ? rect.maxX : rect.midX)
        let y = handle.movesTop ? rect.minY : (handle.movesBottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if origin == nil { origin = model.project.crop.normalized }
                guard let origin else { return }
                NSCursor.closedHand.set()
                let dx = Double(value.translation.width / max(viewSize.width, 1))
                let dy = Double(value.translation.height / max(viewSize.height, 1))
                model.setCrop(VideoCropRect(x: origin.x + dx, y: origin.y + dy, width: origin.width, height: origin.height))
            }
            .onEnded { _ in
                origin = nil
                model.endGesture()
            }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if origin == nil { origin = model.project.crop.normalized }
                guard let origin else { return }
                let dx = Double(value.translation.width / max(viewSize.width, 1))
                let dy = Double(value.translation.height / max(viewSize.height, 1))
                var minX = origin.x
                var minY = origin.y
                var maxX = origin.x + origin.width
                var maxY = origin.y + origin.height
                let side = VideoCropRect.minimumSide
                if handle.movesLeft { minX = min(max(origin.x + dx, 0), maxX - side) }
                if handle.movesRight { maxX = max(min(maxX + dx, 1), minX + side) }
                if handle.movesTop { minY = min(max(origin.y + dy, 0), maxY - side) }
                if handle.movesBottom { maxY = max(min(maxY + dy, 1), minY + side) }
                var rect = VideoCropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if let ratio = model.cropAspect.ratio {
                    rect = locked(rect, ratio: ratio, handle: handle)
                }
                model.setCrop(rect)
            }
            .onEnded { _ in
                origin = nil
                model.endGesture()
            }
    }

    /// Keeps a pixel aspect ratio while resizing, anchored opposite the
    /// dragged handle.
    private func locked(_ rect: VideoCropRect, ratio: CGFloat, handle: Handle) -> VideoCropRect {
        let source = model.project.sourceSize
        guard source.width > 0, source.height > 0 else { return rect }
        // Normalized height for a normalized width at this pixel ratio.
        let factor = Double(source.width / source.height / ratio)
        var width = rect.width
        var height = rect.width * factor
        if !(handle.movesLeft || handle.movesRight) {
            height = rect.height
            width = height / factor
        }
        if width > 1 { width = 1; height = width * factor }
        if height > 1 { height = 1; width = height / factor }
        var x = handle.movesLeft ? rect.x + rect.width - width : rect.x
        var y = handle.movesTop ? rect.y + rect.height - height : rect.y
        if !(handle.movesLeft || handle.movesRight) { x = rect.x + (rect.width - width) / 2 }
        if !(handle.movesTop || handle.movesBottom) { y = rect.y + (rect.height - height) / 2 }
        return VideoCropRect(x: x, y: y, width: width, height: height)
    }
}

/// The controls under the preview while cropping.
struct VideoCropBar: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop")
                .foregroundStyle(VideoEditorTheme.textSecondary)
            VideoSegmented(options: VideoCropAspect.allCases.map { ($0, $0.title) }, selection: Binding(
                get: { model.cropAspect },
                set: { model.applyCropAspect($0) }
            ))
            .frame(width: 300)
            Button {
                model.resetCrop()
                model.cropAspect = .free
            } label: {
                Text("Reset")
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            .disabled(model.project.crop.isFull)
            Button {
                model.endCrop()
            } label: {
                Text("Done")
            }
            .buttonStyle(VideoPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}
