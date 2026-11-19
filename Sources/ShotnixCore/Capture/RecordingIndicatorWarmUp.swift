import AppKit
import ScreenCaptureKit

/// Has macOS show what it shows while the screen is captured before a
/// recording's first frame.
///
/// The indicator in the menu bar and the dot beside Control Center's icon
/// only come up once a capture runs, and the icons slide aside for the
/// indicator as it does. A recording that keeps them out of the video can
/// only leave out windows that exist. So a capture of a few pixels, thrown
/// away, runs while the recording is set up: by the time the recording's
/// own stream starts, the windows are there to be left out and the icons
/// have stopped moving. macOS keeps the same windows when that stream takes
/// over and this one stops.
@MainActor
final class RecordingIndicatorWarmUp {

    /// The longest a recording waits for the indicators, from when the
    /// capture was asked for.
    nonisolated static let longestWait: TimeInterval = 0.5
    /// And for the menu bar to have settled around them.
    nonisolated static let longestSettledWait: TimeInterval = 0.8
    /// How long the icons have to stay put to count as settled.
    nonisolated static let settledFor: TimeInterval = 0.15
    /// And how long after the last thing that moves them (the timer taking
    /// the place of Shotnix's icon, a microphone or camera joining the
    /// indicator) they are given to start moving.
    nonisolated static let settlesAfter: TimeInterval = 0.25

    private var stream: SCStream?
    private let output = Output()
    private var starting: Task<Void, Never>?
    private var began: CFTimeInterval = 0
    private var hasEnded = false

    /// Starts the capture and returns at once: it comes up while the
    /// recording is set up.
    func begin(on display: SCDisplay) {
        guard stream == nil, !hasEnded else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = 16
        configuration.height = 16
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: nil
        )
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        } catch {
            print("[Shotnix] Recording indicator warm-up couldn't be set up: \(error)")
            return
        }
        self.stream = stream
        began = CACurrentMediaTime()
        let box = WarmUpStream(stream: stream)
        starting = Task {
            do {
                try await box.stream.startCapture()
            } catch {
                print("[Shotnix] Recording indicator warm-up didn't start: \(error)")
            }
        }
    }

    /// Waits until the dot and the indicator are on screen and, with
    /// `settled`, the icons are where they stay. `lastChange`: when the
    /// recording last did something that moves them. Gives up at a fixed
    /// time after that and after the capture was asked for: a recording
    /// starts either way, and what shows up later is left out as soon as
    /// it's seen.
    func waitForIndicators(settled: Bool, controlCenter: pid_t?, lastChange: CFTimeInterval? = nil) async {
        guard stream != nil, !hasEnded else { return }
        let since = max(began, lastChange ?? began)
        let deadline = settled ? since + Self.longestSettledWait : began + Self.longestWait
        var lastFrames: [CGRect]?
        var stableSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline, !hasEnded {
            let look = RecordingMenuBar.look(controlCenter: controlCenter)
            let now = CACurrentMediaTime()
            if Self.indicatorsAreUp(look, settled: settled, lastFrames: &lastFrames, stableSince: &stableSince, since: since, now: now) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// One look at the menu bar while waiting. `lastFrames` and
    /// `stableSince` carry over from look to look; `since` is when the
    /// icons were last given a reason to move.
    nonisolated static func indicatorsAreUp(
        _ look: RecordingMenuBar.Look,
        settled: Bool,
        lastFrames: inout [CGRect]?,
        stableSince: inout CFTimeInterval,
        since: CFTimeInterval = 0,
        now: CFTimeInterval
    ) -> Bool {
        let frames = look.controlCenter.filter { $0.layer == RecordingMenuBar.itemLayer }.map(\.frame)
        if frames != lastFrames {
            lastFrames = frames
            stableSince = now
        }
        guard !look.dots.isEmpty, !RecordingMenuBar.indicators(among: look.controlCenter).isEmpty else { return false }
        return !settled || (now - since >= settlesAfter && now - stableSince >= settledFor)
    }

    /// Stops the capture: the recording's own stream runs now, or isn't
    /// going to.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        guard let stream else { return }
        self.stream = nil
        let box = WarmUpStream(stream: stream)
        let starting = starting
        self.starting = nil
        Task {
            // A stream that's still starting can't be stopped yet.
            await starting?.value
            try? await box.stream.stopCapture()
        }
    }

    private final class Output: NSObject, SCStreamOutput {
        let queue = DispatchQueue(label: "com.shotnix.recording.indicator-warm-up", qos: .utility)

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
    }
}

private struct WarmUpStream: @unchecked Sendable {
    let stream: SCStream
}
