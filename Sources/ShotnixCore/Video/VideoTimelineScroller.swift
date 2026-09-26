import AppKit
import SwiftUI

/// Drives the timeline's horizontal scrolling: zooming stays anchored
/// (under the pointer for ⌘-scroll and pinch, on the playhead for the keys
/// and buttons), and during playback the strip pages along with the
/// playhead until you scroll it yourself.
@MainActor
final class VideoTimelineScroller {
    private(set) weak var scrollView: NSScrollView?
    private weak var model: VideoEditorModel?
    /// Paging after the playhead; off once you scroll by hand, back on the
    /// next time playback starts.
    var followsPlayhead = true
    private nonisolated(unsafe) var scrollMonitor: Any?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Hooks up to the timeline's own scroll view (found from inside it).
    func attach(_ scrollView: NSScrollView?, model: VideoEditorModel) {
        self.model = model
        guard let scrollView, scrollView !== self.scrollView else { return }
        self.scrollView = scrollView
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = [
            // Scrolling by hand (a trackpad, a wheel, the scroller) stops
            // the paging; scrolls made here don't post this.
            NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followsPlayhead = false }
            },
            // The window closing ends the ⌘-scroll monitor with it.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: scrollView.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopMonitoring() }
            },
        ]
        installScrollZoom()
    }

    private func stopMonitoring() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// ⌘-scroll zooms the timeline around the pointer (in this editor's
    /// own window only — two editors can be open).
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] incoming in
            nonisolated(unsafe) let event = incoming
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, let model = self.model, let scrollView = self.scrollView,
                      event.modifierFlags.contains(.command), event.window === scrollView.window else { return false }
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                let factor = pow(1.01, Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 6))
                let visible = scrollView.contentView.bounds
                let x = scrollView.contentView.convert(event.locationInWindow, from: nil).x
                if let time = self.time(atContentX: x) {
                    model.pendingZoomAnchor = (time, x - visible.minX)
                }
                model.zoomTimeline(by: factor)
                return true
            }
            return handled ? nil : incoming
        }
    }

    /// Current points per second and inset, set by the timeline on layout.
    var pointsPerSecond: CGFloat = 1
    var inset: CGFloat = VideoTimelineMetrics.inset

    func time(atContentX x: CGFloat) -> Double? {
        guard pointsPerSecond > 0 else { return nil }
        return max(Double((x - inset) / pointsPerSecond), 0)
    }

    var visible: CGRect { scrollView?.contentView.bounds ?? .zero }

    /// Before the strip gets its new width: which moment should stay where
    /// on screen — the one asked for, else the playhead if it's in view,
    /// else whatever is in the middle.
    func anchor(playhead: Double) -> (time: Double, viewportX: CGFloat) {
        if let pending = model?.pendingZoomAnchor {
            model?.pendingZoomAnchor = nil
            return pending
        }
        let visible = self.visible
        let playheadX = inset + CGFloat(playhead) * pointsPerSecond
        if visible.width > 0, playheadX >= visible.minX, playheadX <= visible.maxX {
            return (playhead, playheadX - visible.minX)
        }
        return (time(atContentX: visible.midX) ?? playhead, visible.width / 2)
    }

    /// After the new width is laid out: puts `anchor` back where it was.
    func restore(_ anchor: (time: Double, viewportX: CGFloat), pointsPerSecond: CGFloat) {
        self.pointsPerSecond = pointsPerSecond
        scroll(toX: inset + CGFloat(anchor.time) * pointsPerSecond - anchor.viewportX)
    }

    func scroll(toX x: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let maxX = max(document.frame.width - scrollView.contentView.bounds.width, 0)
        let target = NSPoint(x: min(max(x, 0), maxX), y: scrollView.contentView.bounds.minY)
        guard abs(target.x - scrollView.contentView.bounds.minX) > 0.5 else { return }
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Playing: when the playhead reaches the right edge (or is off to
    /// either side), the next page comes into view with it near the left.
    func follow(playheadX x: CGFloat) {
        guard followsPlayhead else { return }
        let visible = self.visible
        guard visible.width > 60 else { return }
        if x > visible.maxX - 24 || x < visible.minX {
            scroll(toX: x - 40)
        }
    }
}

/// Finds the timeline's scroll view from inside its content.
struct VideoTimelineScrollFinder: NSViewRepresentable {
    let scroller: VideoTimelineScroller
    let model: VideoEditorModel

    final class Probe: NSView {
        var onMove: ((NSScrollView?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMove?(enclosingScrollView)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.onMove = { [scroller, model] scrollView in
            MainActor.assumeIsolated { scroller.attach(scrollView, model: model) }
        }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        if scroller.scrollView == nil { scroller.attach(probe.enclosingScrollView, model: model) }
    }
}

/// Pages the timeline after the playhead while playing (it watches the
/// clock so the rest of the timeline doesn't have to).
struct VideoTimelinePlayheadFollower: View {
    @ObservedObject var clock: VideoDemoPlaybackClock
    @ObservedObject var model: VideoEditorModel
    let scroller: VideoTimelineScroller
    let x: (Double) -> CGFloat

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: clock.time) { time in
                if model.isPlaying { scroller.follow(playheadX: x(time)) }
            }
            .onChange(of: model.isPlaying) { playing in
                // Each play follows again, from wherever the playhead is.
                if playing {
                    scroller.followsPlayhead = true
                    scroller.follow(playheadX: x(clock.time))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
