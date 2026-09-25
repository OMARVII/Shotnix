import CoreGraphics
import Foundation

/// Vertical (and square) exports of a landscape recording: the scene is
/// rendered filling the frame's height and a frame-shaped window pans
/// across it, following the pointer — calmly (a dead zone, a spring, a
/// small look-ahead) but never letting the pointer leave the frame.
struct VideoReframe {
    static let sampleRate = 30.0

    /// Window width as a fraction of the scene's width.
    let windowFraction: CGFloat
    /// Scene-normalized x of the window's center, per sample.
    let centers: [Double]
    let duration: Double

    /// Window center (scene-normalized x) at a timeline moment.
    func center(at time: Double) -> CGFloat {
        guard centers.count > 1 else { return CGFloat(centers.first ?? 0.5) }
        let position = min(max(time, 0), duration) * Self.sampleRate
        let lower = min(Int(position), centers.count - 1)
        let upper = min(lower + 1, centers.count - 1)
        let fraction = position - Double(lower)
        return CGFloat(centers[lower] + (centers[upper] - centers[lower]) * fraction)
    }

    /// Left edge of the window in scene pixels for a scene `width` wide.
    func windowOrigin(at time: Double, sceneWidth: CGFloat) -> CGFloat {
        let windowWidth = sceneWidth * windowFraction
        let x = center(at: time) * sceneWidth - windowWidth / 2
        return min(max(x, 0), sceneWidth - windowWidth)
    }

    /// Whether reframing applies: the output must be noticeably narrower
    /// than the recording.
    static func windowFraction(outputAspect: CGFloat, sceneAspect: CGFloat) -> CGFloat? {
        guard outputAspect > 0, sceneAspect > 0, outputAspect < sceneAspect * 0.92 else { return nil }
        return outputAspect / sceneAspect
    }

    static func build(
        windowFraction: CGFloat,
        camera: VideoCameraTrack,
        cursorTrack: VideoCursorTrack?,
        segments: [VideoDemoTimelineSegment],
        canvas: CGSize,
        stage: CGRect,
        crop: VideoCropRect,
        duration: Double
    ) -> VideoReframe {
        let count = max(Int((duration * sampleRate).rounded(.up)) + 1, 2)
        let half = Double(windowFraction) / 2
        func clamp(_ x: Double) -> Double { min(max(x, half), 1 - half) }

        /// Where the pointer appears in the rendered scene (0…1), if shown.
        func pointerX(atTimeline time: Double) -> Double? {
            guard let cursorTrack else { return nil }
            let source = VideoDemoProject.sourceTime(forTimelineTime: time, segments: segments)
            guard let raw = cursorTrack.visiblePosition(at: source) else { return nil }
            let inCrop = crop.map(raw)
            let canvasX = Double(stage.minX + stage.width * inCrop.x) / Double(max(canvas.width, 1))
            let state = camera.state(at: time)
            return (canvasX - state.centerX) * state.scale + 0.5
        }

        var centers = [Double](repeating: 0.5, count: count)
        let start = pointerX(atTimeline: 0.3) ?? 0.5
        var position = clamp(start)
        var velocity = 0.0
        var leash = position
        let dead = Double(windowFraction) * 0.18
        let omega = 3.6
        let dt = 1 / sampleRate
        for index in 0..<count {
            let t = Double(index) * dt
            // Look a little ahead so the frame is already moving when the
            // pointer gets there.
            if let ahead = pointerX(atTimeline: min(t + 0.25, duration)) {
                if ahead > leash + dead { leash = ahead - dead }
                if ahead < leash - dead { leash = ahead + dead }
            }
            let target = clamp(leash)
            let acceleration = omega * omega * (target - position) - 2 * omega * velocity
            velocity += acceleration * dt
            position += velocity * dt
            // Hard rule: the pointer never leaves the frame.
            if let now = pointerX(atTimeline: t) {
                let margin = Double(windowFraction) * 0.08
                if now > position + half - margin { position = now - half + margin; velocity = 0 }
                if now < position - half + margin { position = now + half - margin; velocity = 0 }
            }
            position = clamp(position)
            centers[index] = position
        }
        return VideoReframe(windowFraction: windowFraction, centers: centers, duration: duration)
    }
}
