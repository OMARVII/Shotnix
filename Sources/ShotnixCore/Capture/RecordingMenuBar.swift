import AppKit

/// The right side of the menu bar in a display recording.
///
/// Since macOS 26 every menu bar item is a window of Control Center, the
/// ones apps put there included. Leaving Shotnix out of a recording no
/// longer leaves out its own item (the timer that counts while recording),
/// and what macOS shows while the screen is being recorded is there too: an
/// indicator of Control Center's, and a dot of the Window Server's beside
/// Control Center's icon.
///
/// A recording keeps all three out of the video window by window. With
/// "Hide menu bar icons" on, Control Center itself is left out, with
/// everything it shows and opens later. Both are in place before the first
/// frame: RecordingIndicatorWarmUp has macOS show its indicators first.
enum RecordingMenuBar {

    static let controlCenterBundleID = "com.apple.controlcenter"

    /// The item macOS adds while the screen, the camera or a microphone is in use.
    static let systemIndicatorName = "AudioVideoModule"

    /// The dot beside Control Center's icon while one of them is in use, and
    /// who it belongs to. Neither name is shown to anyone or translated.
    static let privacyDotName = "StatusIndicator"
    static let windowServerName = "Window Server"

    /// The window layer menu bar items sit on.
    static let itemLayer = Int(CGWindowLevelForKey(.statusWindow))

    /// What a display recording does with Control Center's windows.
    enum Treatment: Equatable {
        /// Recorded as they are.
        case shown
        /// Shotnix's own item and what macOS shows while recording stay out.
        case withoutRecorderItems
        /// Everything Control Center shows stays out: the icons, the clock,
        /// and the panels that open from them.
        case withoutIcons
    }

    /// One of Control Center's windows on screen.
    struct Window: Equatable {
        let id: CGWindowID
        let layer: Int
        let name: String
        /// CG space (top-left origin).
        let frame: CGRect
    }

    /// Whether Control Center hosts every menu bar item on this macOS. Before
    /// macOS 26 an app's item is its own window, so leaving Shotnix out
    /// already leaves its timer out, and other apps' items can't be left out
    /// by leaving out one app.
    static var controlCenterHostsEveryItem: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The treatment for a recording. `reachesMenuBar`: the recorded part of
    /// the screen includes some of the menu bar. One that doesn't is left
    /// alone, so Control Center's panels show in it as they always did.
    nonisolated static func treatment(hidesIcons: Bool, reachesMenuBar: Bool, controlCenterHostsEveryItem: Bool) -> Treatment {
        guard reachesMenuBar, controlCenterHostsEveryItem else { return .shown }
        return hidesIcons ? .withoutIcons : .withoutRecorderItems
    }

    /// Whether `rect` (AppKit space) takes in some of the menu bar of the
    /// screen it's on. `barHeight` is the bar's height there.
    nonisolated static func reachesMenuBar(_ rect: CGRect, screenFrame: CGRect, barHeight: CGFloat) -> Bool {
        rect.intersects(screenFrame) && rect.maxY > screenFrame.maxY - barHeight
    }

    /// Control Center's windows in an on-screen window list
    /// (CGWindowListCopyWindowInfo), front to back.
    nonisolated static func windows(in windowList: [[String: Any]], controlCenter: pid_t) -> [Window] {
        windowList.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == controlCenter,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return Window(
                id: CGWindowID(number),
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                name: info[kCGWindowName as String] as? String ?? "",
                frame: bounds ?? .zero
            )
        }
    }

    /// The Window Server's dots in an on-screen window list, one per display.
    nonisolated static func privacyDots(in windowList: [[String: Any]]) -> Set<CGWindowID> {
        Set(windowList.compactMap { info in
            guard info[kCGWindowName as String] as? String == privacyDotName,
                  info[kCGWindowOwnerName as String] as? String == windowServerName,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return CGWindowID(number)
        })
    }

    /// The items a recording never shows: the system's recording indicator
    /// and Shotnix's own item. On the menu bar that hosts it, Shotnix's item
    /// is the one where AppKit puts it (`ownItemFrames`, CG space); on the
    /// other displays' bars macOS names each copy after its app.
    nonisolated static func recorderItems(among windows: [Window], ownBundleID: String?, ownItemFrames: [CGRect]) -> Set<CGWindowID> {
        indicators(among: windows)
            .union(ownItems(among: windows, named: ownBundleID))
            .union(ownItems(among: windows, at: ownItemFrames))
    }

    /// The system's recording indicator, by its name.
    nonisolated static func indicators(among windows: [Window]) -> Set<CGWindowID> {
        Set(windows.filter { $0.layer == itemLayer && $0.name == systemIndicatorName }.map(\.id))
    }

    /// Shotnix's item on the bars that show copies, named after their app.
    nonisolated static func ownItems(among windows: [Window], named ownBundleID: String?) -> Set<CGWindowID> {
        guard let ownBundleID, !ownBundleID.isEmpty else { return [] }
        return Set(windows.filter { $0.layer == itemLayer && $0.name == ownBundleID }.map(\.id))
    }

    /// Shotnix's item on the bar that hosts it: the window where AppKit has it.
    nonisolated static func ownItems(among windows: [Window], at ownItemFrames: [CGRect]) -> Set<CGWindowID> {
        func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxY - b.maxY) <= 1
        }
        return Set(windows.filter { window in
            window.layer == itemLayer && ownItemFrames.contains { !$0.isEmpty && sameFrame($0, window.frame) }
        }.map(\.id))
    }

    /// Which windows are the recorder's, over a recording: Shotnix's item,
    /// the system's indicator and its dots. Names are certain and kept for
    /// good. A frame is only where the item is right now: icons slide past
    /// each other when one changes size, so a different window turning up
    /// where Shotnix's item is has to be seen twice before it replaces the
    /// one known.
    struct RecorderItems: Equatable {
        private(set) var named: Set<CGWindowID> = []
        private(set) var atOwnFrame: Set<CGWindowID> = []
        private var contender: Set<CGWindowID> = []

        var all: Set<CGWindowID> { named.union(atOwnFrame) }

        /// `windows`: Control Center's, on screen now. `dots`: the Window
        /// Server's, on screen now. `ownItemFrames`: where AppKit has
        /// Shotnix's item now (CG space).
        mutating func look(at windows: [Window], dots: Set<CGWindowID> = [], ownBundleID: String?, ownItemFrames: [CGRect]) {
            named.formUnion(dots)
            named.formUnion(RecordingMenuBar.indicators(among: windows))
            named.formUnion(RecordingMenuBar.ownItems(among: windows, named: ownBundleID))
            let matched = RecordingMenuBar.ownItems(among: windows, at: ownItemFrames)
            let onScreen = Set(windows.map(\.id))
            if atOwnFrame.isDisjoint(with: onScreen) {
                // None known, or its window is gone: whatever is there now.
                if !matched.isEmpty { atOwnFrame = matched }
                contender = []
            } else if matched.isEmpty || matched == atOwnFrame {
                // Mid-resize nothing matches for a moment: the one known stands.
                contender = []
            } else if contender == matched {
                atOwnFrame = matched
                contender = []
            } else {
                contender = matched
            }
        }
    }

    // MARK: What the filter does

    /// What a display filter does with the menu bar's windows.
    struct Filter: Equatable {
        /// Control Center is left out as an app, with whatever it opens
        /// later. It can only be while the window list names it, which is
        /// while one of its windows is on screen.
        var leavesOutControlCenter = false
        /// With Control Center left out: its windows let back in.
        var letIn: Set<CGWindowID> = []
        /// Left out one by one: windows of apps that are in the video.
        var leftOut: Set<CGWindowID> = []
    }

    /// A recording that keeps the recorder's items out opens with Control
    /// Center left out and its other windows let back in: should macOS put
    /// up its indicator in a new window as the recording starts, it never
    /// gets a frame. Once that moment is over only the recorder's windows
    /// are left out, so a panel Control Center opens is in the video the
    /// moment it's on screen.
    enum Phase: Equatable {
        case launch
        case steady
    }

    /// How long a recording stays in its launch phase. The indicator is up
    /// within a third of a second of a capture starting.
    static let launchSeconds: TimeInterval = 1.2

    /// The filter a recording wants for what's on screen now.
    /// `canLeaveOutControlCenter`: as an app, which takes the window list
    /// naming it (RecordingCaptureFilter). `onScreen`: Control Center's
    /// windows on screen.
    nonisolated static func filter(
        for treatment: Treatment,
        phase: Phase,
        canLeaveOutControlCenter: Bool,
        onScreen: Set<CGWindowID>,
        recorderItems: Set<CGWindowID>,
        dots: Set<CGWindowID>
    ) -> Filter {
        switch treatment {
        case .shown:
            return Filter()
        case .withoutIcons:
            if canLeaveOutControlCenter {
                return Filter(leavesOutControlCenter: true, leftOut: dots)
            }
            // Its windows one by one, then: what it opens next is left out
            // once it's seen.
            return Filter(leftOut: onScreen.union(dots))
        case .withoutRecorderItems:
            if phase == .launch, canLeaveOutControlCenter {
                return Filter(leavesOutControlCenter: true, letIn: onScreen.subtracting(recorderItems), leftOut: dots)
            }
            return Filter(leftOut: recorderItems.union(dots))
        }
    }

    /// Whether the filter in effect no longer does what the recording
    /// wants, and has to be rebuilt. `givenUp`: windows on screen that the
    /// capture's window list keeps leaving out, so no filter can name them.
    nonisolated static func isOutOfStep(
        _ inEffect: Filter,
        treatment: Treatment,
        phase: Phase,
        onScreen: Set<CGWindowID>,
        recorderItems: Set<CGWindowID>,
        dots: Set<CGWindowID>,
        givenUp: Set<CGWindowID> = []
    ) -> Bool {
        guard treatment != .shown else { return false }
        if !dots.subtracting(givenUp).isSubset(of: inEffect.leftOut) { return true }
        switch treatment {
        case .shown:
            return false
        case .withoutIcons:
            if inEffect.leavesOutControlCenter { return false }
            // Left out window by window: the list didn't name Control
            // Center when the filter was built (the menu bar was hidden),
            // or it was relaunched since.
            return !onScreen.subtracting(givenUp).isSubset(of: inEffect.leftOut)
        case .withoutRecorderItems:
            if inEffect.leavesOutControlCenter {
                // The launch filter: over when the launch is, and never
                // with one of the recorder's windows let in.
                return phase == .steady || !inEffect.letIn.isDisjoint(with: recorderItems)
            }
            return !recorderItems.intersection(onScreen).subtracting(givenUp).isSubset(of: inEffect.leftOut)
        }
    }

    /// Windows a filter should name that the capture's window list leaves
    /// out. One that just came on screen is in the next list. One that
    /// several lists in a row leave out is let be for a while, or every look
    /// at the menu bar would rebuild the filter for nothing, and asked for
    /// again later, each time after a longer rest.
    struct Unlisted: Equatable {
        static let attempts = 3
        static let firstRest: TimeInterval = 2
        static let longestRest: TimeInterval = 30

        private var misses: [CGWindowID: Int] = [:]
        private var restingUntil: [CGWindowID: CFTimeInterval] = [:]
        private var rests: [CGWindowID: Int] = [:]

        /// Not asked for at the moment.
        func givenUp(at now: CFTimeInterval) -> Set<CGWindowID> {
            Set(restingUntil.filter { $0.value > now }.keys)
        }

        /// After a filter was built: `unlisted` were wanted, on screen, and
        /// not in its list.
        mutating func note(_ unlisted: Set<CGWindowID>, at now: CFTimeInterval) {
            restingUntil = restingUntil.filter { $0.value > now }
            // Listed in between: counted from the start if it goes missing again.
            misses = misses.filter { unlisted.contains($0.key) }
            for window in unlisted where restingUntil[window] == nil {
                misses[window, default: 0] += 1
                guard misses[window, default: 0] >= Self.attempts else { continue }
                let rest = min(Self.firstRest * pow(2, Double(rests[window, default: 0])), Self.longestRest)
                restingUntil[window] = now + rest
                rests[window, default: 0] += 1
                misses[window] = nil
            }
        }
    }

    // MARK: Live

    /// Control Center's process, nil when it isn't running.
    @MainActor
    static func controlCenterProcessID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: controlCenterBundleID).first?.processIdentifier
    }

    /// Control Center's windows on screen now.
    nonisolated static func windowsOnScreen(controlCenter: pid_t) -> [Window] {
        look(controlCenter: controlCenter).controlCenter
    }

    /// The menu bar's windows on screen, from one window list.
    struct Look: Equatable {
        var controlCenter: [Window] = []
        /// The Window Server's dots.
        var dots: Set<CGWindowID> = []
    }

    /// What's on screen now. Takes about a millisecond.
    nonisolated static func look(controlCenter: pid_t?) -> Look {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Look(
            controlCenter: controlCenter.map { windows(in: windowList, controlCenter: $0) } ?? [],
            dots: privacyDots(in: windowList)
        )
    }

    /// Where AppKit has Shotnix's menu bar item (CG space): the window that
    /// stands in for it in this process. Empty when macOS has it hidden.
    @MainActor
    static func ownItemFrames() -> [CGRect] {
        NSApp.windows.compactMap { window -> CGRect? in
            guard window.className == "NSStatusBarWindow", window.isVisible, window.occlusionState.contains(.visible) else { return nil }
            return ScreenCoordinates.cgRect(fromAppKit: window.frame)
        }
    }

    /// The items to keep out of a recording made now.
    @MainActor
    static func recorderItems(among windows: [Window]) -> Set<CGWindowID> {
        recorderItems(among: windows, ownBundleID: Bundle.main.bundleIdentifier, ownItemFrames: ownItemFrames())
    }

    /// The tallest a Mac's menu bar gets (beside a notch).
    static let tallestBar: CGFloat = 38

    /// How far down from the top of `screen` the menu bar can reach. With
    /// the bar set to show only on hover the screen reports no bar at all,
    /// and guessing low would let the icons into an area just under it; a
    /// few points too many only means an area that doesn't quite reach the
    /// bar is treated like one that does.
    @MainActor
    static func barHeight(on screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, tallestBar)
    }
}
