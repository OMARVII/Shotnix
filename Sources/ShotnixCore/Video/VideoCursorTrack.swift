import CoreGraphics
import Foundation

/// The rendered pointer path for a recording: resampled to 120Hz, smoothed
/// with a zero-lag spring (a forward pass and a backward pass, so the
/// pointer glides without trailing behind the real one), pinned exactly to
/// the recorded position whenever a button is down (clicks land where they
/// landed), and faded out when idle or outside the captured area.
/// Indexed by SOURCE time.
final class VideoCursorTrack: @unchecked Sendable {
    static let sampleRate = 120.0
    /// Idle time before the pointer fades away (when hiding is on).
    static let idleDelay = 1.6

    let duration: Double
    /// When set, the pointer stopped here (its final dash to the Stop
    /// button is hidden) — clicks after it aren't drawn either.
    let endTime: Double?
    private let xs: [Float]
    private let ys: [Float]
    private let alphas: [Float]

    init(duration: Double, xs: [Float], ys: [Float], alphas: [Float], endTime: Double? = nil) {
        self.duration = duration
        self.xs = xs
        self.ys = ys
        self.alphas = alphas
        self.endTime = endTime
    }

    /// Video-normalized, y down.
    func position(at time: Double) -> CGPoint {
        let (lower, upper, fraction) = indices(time)
        return CGPoint(
            x: Double(xs[lower]) + Double(xs[upper] - xs[lower]) * fraction,
            y: Double(ys[lower]) + Double(ys[upper] - ys[lower]) * fraction
        )
    }

    func alpha(at time: Double) -> Double {
        let (lower, upper, fraction) = indices(time)
        return Double(alphas[lower]) + Double(alphas[upper] - alphas[lower]) * fraction
    }

    /// Video-normalized units per second.
    func velocity(at time: Double) -> CGVector {
        let dt = 1 / Self.sampleRate
        let a = position(at: time - dt)
        let b = position(at: time + dt)
        return CGVector(dx: (b.x - a.x) / (2 * dt), dy: (b.y - a.y) / (2 * dt))
    }

    /// Pointer for the camera to follow: nil while hidden.
    func visiblePosition(at time: Double) -> CGPoint? {
        alpha(at: time) > 0.05 ? position(at: time) : nil
    }

    private func indices(_ time: Double) -> (Int, Int, Double) {
        let position = min(max(time, 0), duration) * Self.sampleRate
        let lower = min(max(Int(position), 0), xs.count - 1)
        let upper = min(lower + 1, xs.count - 1)
        return (lower, upper, position - Double(lower))
    }

    // MARK: Building

    static func build(
        samples rawSamples: [VideoDemoCursorSample],
        clicks: [VideoDemoClickEvent],
        smoothing: VideoCursorSettings.Smoothing,
        hideWhenIdle: Bool,
        tidyEnding: Bool = false,
        duration: Double
    ) -> VideoCursorTrack? {
        let samples = rawSamples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.time < $1.time }
        guard !samples.isEmpty, duration > 0 else { return nil }

        let count = Int((duration * sampleRate).rounded(.up)) + 1
        var rawX = [Double](repeating: 0, count: count)
        var rawY = [Double](repeating: 0, count: count)

        // Linear resample of the recorded path.
        var cursor = 0
        for index in 0..<count {
            let t = Double(index) / sampleRate
            while cursor + 1 < samples.count, samples[cursor + 1].time <= t { cursor += 1 }
            let a = samples[cursor]
            if t <= a.time || cursor + 1 >= samples.count {
                rawX[index] = a.x
                rawY[index] = a.y
            } else {
                let b = samples[cursor + 1]
                let span = max(b.time - a.time, 0.0001)
                let f = (t - a.time) / span
                rawX[index] = a.x + (b.x - a.x) * f
                rawY[index] = a.y + (b.y - a.y) * f
            }
        }

        var smoothX = rawX
        var smoothY = rawY
        if let stiffness = smoothing.stiffness {
            smoothX = zeroLagSpring(rawX, omega: stiffness)
            smoothY = zeroLagSpring(rawY, omega: stiffness)
        }

        // While a button is down the drawn pointer IS the recorded one — the
        // press lands on the exact spot clicked, and drags track exactly.
        // Blends in and out over a short window so nothing snaps.
        let blend = 0.18
        var pinWeight = [Double](repeating: 0, count: count)
        for click in clicks {
            let start = click.time
            let end = click.time + click.pressDuration
            let from = max(Int(((start - blend) * sampleRate).rounded(.down)), 0)
            let to = min(Int(((end + blend) * sampleRate).rounded(.up)), count - 1)
            guard from <= to else { continue }
            for index in from...to {
                let t = Double(index) / sampleRate
                let weight: Double
                if t < start {
                    weight = smoothstep((t - (start - blend)) / blend)
                } else if t <= end {
                    weight = 1
                } else {
                    weight = smoothstep(1 - (t - end) / blend)
                }
                pinWeight[index] = max(pinWeight[index], weight)
            }
        }
        for index in 0..<count where pinWeight[index] > 0 {
            let w = pinWeight[index]
            smoothX[index] += (rawX[index] - smoothX[index]) * w
            smoothY[index] += (rawY[index] - smoothY[index]) * w
        }

        // Visibility target: outside the captured area → hidden; idle → hidden.
        var target = [Double](repeating: 1, count: count)
        var lastActivity = -Double.infinity
        var clickIndex = 0
        let sortedClicks = clicks.sorted { $0.time < $1.time }
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let inside = rawX[index] >= -0.005 && rawX[index] <= 1.005 && rawY[index] >= -0.005 && rawY[index] <= 1.005
            if index > 0 {
                let dx = rawX[index] - rawX[index - 1]
                let dy = rawY[index] - rawY[index - 1]
                if dx * dx + dy * dy > 0.0006 * 0.0006 { lastActivity = t }
            } else {
                lastActivity = 0
            }
            while clickIndex < sortedClicks.count, sortedClicks[clickIndex].time <= t {
                lastActivity = max(lastActivity, sortedClicks[clickIndex].time + sortedClicks[clickIndex].pressDuration)
                clickIndex += 1
            }
            var value = inside ? 1.0 : 0.0
            if hideWhenIdle, t - lastActivity > idleDelay {
                value = 0
            }
            target[index] = value
        }

        // Tidy ending: every recording ends with a dash to the Stop button
        // (out of the frame, or up to the menu bar). Freeze the pointer
        // where that dash began and let it fade.
        var endTime: Double?
        if tidyEnding, count > 10 {
            endTime = finalDashStart(rawX: rawX, rawY: rawY, duration: duration)
            if let endTime {
                let from = min(max(Int((endTime * sampleRate).rounded()), 0), count - 1)
                for index in from..<count {
                    smoothX[index] = smoothX[from]
                    smoothY[index] = smoothY[from]
                    target[index] = 0
                }
            }
        }

        // Fade out forward in time (0.35s); fade in BACKWARD in time (0.12s)
        // so the pointer is already there the moment it starts moving.
        var alpha = target
        let fadeOutStep = 1 / (0.35 * sampleRate)
        for index in 1..<count where alpha[index] < alpha[index - 1] {
            alpha[index] = max(alpha[index], alpha[index - 1] - fadeOutStep)
        }
        let fadeInStep = 1 / (0.12 * sampleRate)
        if count > 1 {
            for index in stride(from: count - 2, through: 0, by: -1) where alpha[index] < alpha[index + 1] {
                alpha[index] = max(alpha[index], alpha[index + 1] - fadeInStep)
            }
        }

        return VideoCursorTrack(
            duration: duration,
            xs: smoothX.map { Float($0) },
            ys: smoothY.map { Float($0) },
            alphas: alpha.map { Float(min(max($0, 0), 1)) },
            endTime: endTime
        )
    }

    /// Start of the pointer's final dash to stop the recording, if the
    /// recording ends with one: within the last 2.5s the pointer leaves the
    /// frame for good, or races up to the top edge (the menu bar).
    static func finalDashStart(rawX: [Double], rawY: [Double], duration: Double) -> Double? {
        let count = rawX.count
        guard count > 2 else { return nil }
        func inside(_ index: Int) -> Bool {
            rawX[index] >= -0.005 && rawX[index] <= 1.005 && rawY[index] >= -0.005 && rawY[index] <= 1.005
        }
        var end: Int
        if !inside(count - 1) {
            // Last moment it was still inside the frame.
            guard let lastInside = (0..<count).last(where: inside) else { return nil }
            end = lastInside
        } else if rawY[count - 1] < 0.04 {
            end = count - 1
        } else {
            return nil
        }
        guard duration - Double(end) / sampleRate < 2.5 else { return nil }
        // Walk back while the pointer was moving fast.
        var start = end
        let minimumSpeed = 0.25 // frame-widths per second
        while start > 1 {
            let dx = rawX[start] - rawX[start - 1]
            let dy = rawY[start] - rawY[start - 1]
            let speed = (dx * dx + dy * dy).squareRoot() * sampleRate
            if speed < minimumSpeed { break }
            start -= 1
            if Double(end - start) / sampleRate > 1.5 { break }
        }
        guard end - start >= 3 else { return nil }
        return Double(start) / sampleRate
    }

    /// Critically-damped spring run forward, then backward over the result:
    /// the two passes cancel each other's lag.
    private static func zeroLagSpring(_ input: [Double], omega: Double) -> [Double] {
        guard input.count > 2 else { return input }
        let forward = spring(input, omega: omega)
        let backward = spring(Array(forward.reversed()), omega: omega)
        return Array(backward.reversed())
    }

    private static func spring(_ input: [Double], omega: Double) -> [Double] {
        var output = input
        var position = input[0]
        var velocity = 0.0
        let substeps = 4
        let h = 1 / (sampleRate * Double(substeps))
        for index in 0..<input.count {
            let target = input[index]
            for _ in 0..<substeps {
                let acceleration = omega * omega * (target - position) - 2 * omega * velocity
                velocity += acceleration * h
                position += velocity * h
            }
            output[index] = position
        }
        return output
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
