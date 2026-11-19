import AppKit
import XCTest
@testable import ShotnixCore

/// Which of the menu bar's items a display recording leaves out
/// (RecordingMenuBar): since macOS 26 they're all Control Center's windows,
/// Shotnix's recording timer included.
final class RecordingMenuBarTests: XCTestCase {

    private let controlCenter: pid_t = 620
    private let layer = RecordingMenuBar.itemLayer

    private func info(_ id: Int, pid: pid_t, layer: Int, name: String?, x: CGFloat, width: CGFloat, y: CGFloat = 0, height: CGFloat = 30) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation,
        ]
        if let name { info[kCGWindowName as String] = name }
        return info
    }

    private func item(_ id: CGWindowID, _ name: String, x: CGFloat, width: CGFloat, layer: Int? = nil) -> RecordingMenuBar.Window {
        RecordingMenuBar.Window(id: id, layer: layer ?? self.layer, name: name, frame: CGRect(x: x, y: 0, width: width, height: 30))
    }

    // MARK: Reading the window list

    func testOnlyControlCentersWindowsAreRead() {
        let list = [
            info(48, pid: controlCenter, layer: layer, name: "Clock", x: 2402, width: 158),
            info(60397, pid: controlCenter, layer: layer, name: "Item-0", x: 1704, width: 63),
            info(60047, pid: 401, layer: layer - 1, name: "Menubar", x: 0, width: 2560),
            info(900, pid: 1234, layer: 0, name: "A document", x: 100, width: 800, y: 80, height: 600),
            info(61000, pid: controlCenter, layer: 101, name: nil, x: 2200, width: 340, y: 34, height: 420),
        ]
        let windows = RecordingMenuBar.windows(in: list, controlCenter: controlCenter)
        XCTAssertEqual(windows.map(\.id), [48, 60397, 61000], "in the list's order, nobody else's")
        XCTAssertEqual(windows[1], item(60397, "Item-0", x: 1704, width: 63))
        XCTAssertEqual(windows[2].name, "", "a window without a name reads as an empty one")
        XCTAssertEqual(windows[2].layer, 101, "its panels count too: they have to be let back in")
    }

    // MARK: The items that never show

    func testTheRecordingIndicatorAndShotnixsOwnItemStayOut() {
        let windows = [
            item(60411, "AudioVideoModule", x: 1656, width: 48),
            item(60397, "Item-0", x: 1704, width: 63), // Shotnix's timer, where AppKit has it
            item(60222, "Item-0", x: 1767, width: 38), // another app's
            item(47, "Battery", x: 2216, width: 42),
            item(48, "Clock", x: 2402, width: 158),
        ]
        let out = RecordingMenuBar.recorderItems(among: windows, ownBundleID: "com.shotnix.app", ownItemFrames: [CGRect(x: 1704, y: 0, width: 63, height: 30)])
        XCTAssertEqual(out, [60411, 60397])
    }

    func testOnAnotherDisplaysBarShotnixsItemGoesByItsBundleIdentifier() {
        // The bar of a second display: copies named after their apps,
        // system ones unnamed.
        let windows = [
            item(60154, "com.shotnix.app", x: -607, width: 38),
            item(60136, "com.stablyai.orca", x: -462, width: 38),
            item(60093, "", x: -156, width: 158),
        ]
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: "com.shotnix.app", ownItemFrames: []), [60154])
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: nil, ownItemFrames: []), [], "no identifier (a test runner): nothing is taken for it")
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: "", ownItemFrames: []), [], "an empty identifier never matches the unnamed items")
    }

    func testAnItemIsTakenForShotnixsOnlyWhereItsFrameIs() {
        let windows = [
            item(1, "Item-0", x: 1704, width: 63),
            item(2, "Item-0", x: 1767, width: 63), // same size, next to it
            item(3, "Item-0", x: 1700, width: 63), // 4 pt off
        ]
        let own = [CGRect(x: 1704.5, y: 0, width: 63, height: 30)]
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: nil, ownItemFrames: own), [1], "half a point of rounding still matches, a neighbor doesn't")
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: nil, ownItemFrames: [.zero]), [], "an item macOS has hidden has no frame to go by")
    }

    func testOnlyMenuBarItemsCanBeRecorderItems() {
        // A panel that happens to carry the indicator's name, or to sit
        // where the item is, isn't an item.
        let windows = [
            item(1, "AudioVideoModule", x: 1656, width: 48, layer: 101),
            item(2, "com.shotnix.app", x: 1704, width: 63, layer: 0),
        ]
        XCTAssertEqual(RecordingMenuBar.recorderItems(among: windows, ownBundleID: "com.shotnix.app", ownItemFrames: [CGRect(x: 1704, y: 0, width: 63, height: 30)]), [])
    }

    // MARK: Over a recording

    func testNamedItemsAreKeptForGood() {
        var items = RecordingMenuBar.RecorderItems()
        items.look(at: [item(60411, "AudioVideoModule", x: 1656, width: 48), item(60154, "com.shotnix.app", x: -607, width: 38)], ownBundleID: "com.shotnix.app", ownItemFrames: [])
        XCTAssertEqual(items.all, [60411, 60154])
        // The indicator's window goes out of sight between captures and is used again.
        items.look(at: [item(47, "Battery", x: 2216, width: 42)], ownBundleID: "com.shotnix.app", ownItemFrames: [])
        XCTAssertEqual(items.all, [60411, 60154])
    }

    func testTheItemAtShotnixsFrameIsTakenAtOnceAndKeptWhileItChangesSize() {
        var items = RecordingMenuBar.RecorderItems()
        let neighbor = item(2, "Item-0", x: 1767, width: 38)
        // The idle icon, before the recording.
        items.look(at: [item(1, "Item-0", x: 1729, width: 38), neighbor], ownBundleID: nil, ownItemFrames: [CGRect(x: 1729, y: 0, width: 38, height: 30)])
        XCTAssertEqual(items.all, [1], "at first sight")
        // It becomes the timer: for a moment AppKit and Control Center disagree on where it is.
        items.look(at: [item(1, "Item-0", x: 1729, width: 38), neighbor], ownBundleID: nil, ownItemFrames: [CGRect(x: 1704, y: 0, width: 63, height: 30)])
        XCTAssertEqual(items.all, [1], "nothing matches: the one known stands")
        items.look(at: [item(1, "Item-0", x: 1704, width: 63), neighbor], ownBundleID: nil, ownItemFrames: [CGRect(x: 1704, y: 0, width: 63, height: 30)])
        XCTAssertEqual(items.all, [1])
    }

    func testANeighborSlidingIntoShotnixsPlaceIsNotTakenForIt() {
        var items = RecordingMenuBar.RecorderItems()
        let own = CGRect(x: 1729, y: 0, width: 38, height: 30)
        items.look(at: [item(1, "Item-0", x: 1729, width: 38), item(2, "Item-0", x: 1767, width: 38)], ownBundleID: nil, ownItemFrames: [own])
        // Another icon appeared further right: everything shifts one slot,
        // and for one look the neighbor sits where AppKit still has Shotnix's.
        items.look(at: [item(1, "Item-0", x: 1691, width: 38), item(2, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [own])
        XCTAssertEqual(items.all, [1], "seen once: not believed")
        items.look(at: [item(1, "Item-0", x: 1691, width: 38), item(2, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [CGRect(x: 1691, y: 0, width: 38, height: 30)])
        XCTAssertEqual(items.all, [1], "and AppKit caught up")
    }

    func testAWindowThatStaysAtShotnixsFrameReplacesTheOneKnown() {
        var items = RecordingMenuBar.RecorderItems()
        let own = CGRect(x: 1729, y: 0, width: 38, height: 30)
        let windows = [item(1, "Item-0", x: 1691, width: 38), item(2, "Item-0", x: 1729, width: 38)]
        items.look(at: [item(1, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [own])
        items.look(at: windows, ownBundleID: nil, ownItemFrames: [own])
        XCTAssertEqual(items.all, [1])
        items.look(at: windows, ownBundleID: nil, ownItemFrames: [own])
        XCTAssertEqual(items.all, [2], "twice in a row: the first match was the wrong one")
        // A third window matching once in between starts over.
        items.look(at: windows + [item(3, "Item-0", x: 1500, width: 38)], ownBundleID: nil, ownItemFrames: [CGRect(x: 1500, y: 0, width: 38, height: 30)])
        items.look(at: windows, ownBundleID: nil, ownItemFrames: [own])
        items.look(at: windows + [item(3, "Item-0", x: 1500, width: 38)], ownBundleID: nil, ownItemFrames: [CGRect(x: 1500, y: 0, width: 38, height: 30)])
        XCTAssertEqual(items.all, [2])
    }

    func testWhenTheItemsWindowIsGoneWhateverIsAtItsFrameIsTakenAtOnce() {
        var items = RecordingMenuBar.RecorderItems()
        let own = CGRect(x: 1729, y: 0, width: 38, height: 30)
        items.look(at: [item(1, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [own])
        // macOS made the item a new window: the old one is off the list.
        items.look(at: [item(9, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [own])
        XCTAssertEqual(items.all, [9], "no second look: until then it would be in the video")
        // Hidden by macOS (a full menu bar): no frame, nothing new to take.
        items.look(at: [item(9, "Item-0", x: 1729, width: 38)], ownBundleID: nil, ownItemFrames: [])
        XCTAssertEqual(items.all, [9])
    }

    func testTheMenuBarsHeightIsNeverGuessedLow() {
        // A bar that only shows on hover reports no height; 30 pt of icons
        // then reach into an area that starts 25 pt down.
        XCTAssertGreaterThanOrEqual(RecordingMenuBar.tallestBar, 37)
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(RecordingMenuBar.reachesMenuBar(CGRect(x: 0, y: 0, width: 2560, height: 1415), screenFrame: screen, barHeight: RecordingMenuBar.tallestBar))
    }

    // MARK: The dot beside Control Center's icon

    func testThePrivacyDotsAreTheWindowServersWindowsOfThatName() {
        func named(_ id: Int, _ name: String, owner: String) -> [String: Any] {
            var entry = info(id, pid: 389, layer: 2_147_483_630, name: name, x: 2388, width: 8, y: 6, height: 8)
            entry[kCGWindowOwnerName as String] = owner
            return entry
        }
        let list = [
            named(62231, "StatusIndicator", owner: "Window Server"),
            named(62232, "StatusIndicator", owner: "Window Server"), // the second display's
            named(60047, "Menubar", owner: "Window Server"),
            named(700, "StatusIndicator", owner: "Some App"), // anyone can call a window that
            info(48, pid: controlCenter, layer: layer, name: "Clock", x: 2402, width: 158),
        ]
        XCTAssertEqual(RecordingMenuBar.privacyDots(in: list), [62231, 62232])
        XCTAssertEqual(RecordingMenuBar.privacyDots(in: []), [])
    }

    func testTheDotsCountAmongTheRecordersWindowsForGood() {
        var items = RecordingMenuBar.RecorderItems()
        items.look(at: [item(48, "Clock", x: 2402, width: 158)], dots: [62231], ownBundleID: nil, ownItemFrames: [])
        XCTAssertEqual(items.all, [62231])
        items.look(at: [item(48, "Clock", x: 2402, width: 158)], dots: [], ownBundleID: nil, ownItemFrames: [])
        XCTAssertEqual(items.all, [62231], "between captures it's out of sight, and the next one uses it again")
    }

    // MARK: What the filter does

    func testARecordingOpensWithControlCenterLeftOutAndEverythingElseOfItsLetBackIn() {
        let filter = RecordingMenuBar.filter(
            for: .withoutRecorderItems,
            phase: .launch,
            canLeaveOutControlCenter: true,
            onScreen: [47, 48, 60397, 60411],
            recorderItems: [60397, 60411, 62231],
            dots: [62231]
        )
        XCTAssertEqual(filter, RecordingMenuBar.Filter(leavesOutControlCenter: true, letIn: [47, 48], leftOut: [62231]), "an indicator in a window nobody has seen yet gets no frame")
    }

    func testOnceTheLaunchIsOverOnlyTheRecordersWindowsAreLeftOut() {
        let filter = RecordingMenuBar.filter(
            for: .withoutRecorderItems,
            phase: .steady,
            canLeaveOutControlCenter: true,
            onScreen: [47, 48, 60397, 60411],
            recorderItems: [60397, 60411],
            dots: [62231]
        )
        XCTAssertEqual(filter, RecordingMenuBar.Filter(leftOut: [60397, 60411, 62231]), "Control Center is in the video, so a panel it opens is there the moment it's on screen")
    }

    func testWithTheMenuBarHiddenAtTheStartTheLaunchFilterIsTheSteadyOne() {
        // A full screen app: the list doesn't name Control Center, so it
        // can't be left out as an app.
        let filter = RecordingMenuBar.filter(for: .withoutRecorderItems, phase: .launch, canLeaveOutControlCenter: false, onScreen: [], recorderItems: [60411], dots: [])
        XCTAssertEqual(filter, RecordingMenuBar.Filter(leftOut: [60411]))
    }

    func testHidingTheIconsLeavesOutControlCenterAndTheDots() {
        for phase in [RecordingMenuBar.Phase.launch, .steady] {
            let filter = RecordingMenuBar.filter(for: .withoutIcons, phase: phase, canLeaveOutControlCenter: true, onScreen: [47, 48, 60397], recorderItems: [60397], dots: [62231])
            XCTAssertEqual(filter, RecordingMenuBar.Filter(leavesOutControlCenter: true, leftOut: [62231]), "nothing of Control Center's is named: naming a window of an app that's left out would let it in")
        }
        XCTAssertEqual(
            RecordingMenuBar.filter(for: .withoutIcons, phase: .steady, canLeaveOutControlCenter: false, onScreen: [], recorderItems: [], dots: [62231]),
            RecordingMenuBar.Filter(leftOut: [62231]),
            "the menu bar is hidden: nothing of Control Center's to leave out yet"
        )
        XCTAssertEqual(
            RecordingMenuBar.filter(for: .withoutIcons, phase: .steady, canLeaveOutControlCenter: false, onScreen: [47, 48, 60397], recorderItems: [60397], dots: [62231]),
            RecordingMenuBar.Filter(leftOut: [47, 48, 60397, 62231]),
            "it can't be left out as an app: every window of its own, then"
        )
        XCTAssertEqual(RecordingMenuBar.filter(for: .shown, phase: .steady, canLeaveOutControlCenter: true, onScreen: [47], recorderItems: [60397], dots: [62231]), RecordingMenuBar.Filter())
    }

    func testTheLaunchFilterIsRebuiltWhenTheLaunchIsOver() {
        let launch = RecordingMenuBar.Filter(leavesOutControlCenter: true, letIn: [47, 48], leftOut: [62231])
        func outOfStep(_ phase: RecordingMenuBar.Phase, onScreen: Set<CGWindowID> = [47, 48, 60397, 60411], recorder: Set<CGWindowID> = [60397, 60411]) -> Bool {
            RecordingMenuBar.isOutOfStep(launch, treatment: .withoutRecorderItems, phase: phase, onScreen: onScreen, recorderItems: recorder, dots: [62231])
        }
        XCTAssertFalse(outOfStep(.launch))
        XCTAssertFalse(outOfStep(.launch, onScreen: [47, 48, 60397, 60411, 61000]), "a panel opened in the first second waits for the launch to end")
        XCTAssertTrue(outOfStep(.launch, recorder: [60397, 60411, 47]), "a window let in turned out to be Shotnix's item")
        XCTAssertTrue(outOfStep(.steady))
    }

    func testTheSteadyFilterIsRebuiltOnlyForARecordersWindowItDoesNotLeaveOut() {
        let steady = RecordingMenuBar.Filter(leftOut: [60397, 60411, 62231])
        func outOfStep(onScreen: Set<CGWindowID>, recorder: Set<CGWindowID>, dots: Set<CGWindowID> = [62231], givenUp: Set<CGWindowID> = []) -> Bool {
            RecordingMenuBar.isOutOfStep(steady, treatment: .withoutRecorderItems, phase: .steady, onScreen: onScreen, recorderItems: recorder, dots: dots, givenUp: givenUp)
        }
        XCTAssertFalse(outOfStep(onScreen: [47, 48, 60397, 60411], recorder: [60397, 60411]))
        XCTAssertFalse(outOfStep(onScreen: [47, 48, 60397, 60411, 61000, 61001], recorder: [60397, 60411]), "panels and new icons need nothing: they're in the video already")
        XCTAssertTrue(outOfStep(onScreen: [47, 48, 60500, 60411], recorder: [60397, 60411, 60500]), "macOS gave Shotnix's item a new window")
        XCTAssertFalse(outOfStep(onScreen: [47, 48], recorder: [60397, 60411, 70000]), "a window that isn't on screen can wait")
        XCTAssertTrue(outOfStep(onScreen: [47, 48], recorder: [60397, 60411], dots: [62231, 62300]), "a display was connected: its dot")
        XCTAssertFalse(outOfStep(onScreen: [47, 48, 60500], recorder: [60500], dots: [62300], givenUp: [60500, 62300]), "what the capture's window list never names isn't asked for forever")
    }

    func testWithTheIconsHiddenTheFilterIsRebuiltWhenControlCenterIsBackOnScreenUnhidden() {
        let hidden = RecordingMenuBar.Filter(leavesOutControlCenter: true, leftOut: [62231])
        XCTAssertFalse(RecordingMenuBar.isOutOfStep(hidden, treatment: .withoutIcons, phase: .steady, onScreen: [47, 48, 61000], recorderItems: [], dots: [62231]), "whatever Control Center opens is out already")
        XCTAssertTrue(RecordingMenuBar.isOutOfStep(hidden, treatment: .withoutIcons, phase: .steady, onScreen: [47], recorderItems: [], dots: [62231, 62300]))
        // Built while a full screen app hid the menu bar, or before Control Center was relaunched.
        let byWindow = RecordingMenuBar.Filter(leftOut: [62231])
        XCTAssertFalse(RecordingMenuBar.isOutOfStep(byWindow, treatment: .withoutIcons, phase: .steady, onScreen: [], recorderItems: [], dots: [62231]))
        XCTAssertTrue(RecordingMenuBar.isOutOfStep(byWindow, treatment: .withoutIcons, phase: .steady, onScreen: [47, 48], recorderItems: [], dots: [62231]))
        // Its windows left out one by one keep the filter in step until it opens another.
        let each = RecordingMenuBar.Filter(leftOut: [47, 48, 62231])
        XCTAssertFalse(RecordingMenuBar.isOutOfStep(each, treatment: .withoutIcons, phase: .steady, onScreen: [47, 48], recorderItems: [], dots: [62231]))
        XCTAssertTrue(RecordingMenuBar.isOutOfStep(each, treatment: .withoutIcons, phase: .steady, onScreen: [47, 48, 61000], recorderItems: [], dots: [62231]), "a panel")
        XCTAssertFalse(RecordingMenuBar.isOutOfStep(each, treatment: .withoutIcons, phase: .steady, onScreen: [47, 48, 61000], recorderItems: [], dots: [62231], givenUp: [61000]))
        XCTAssertFalse(RecordingMenuBar.isOutOfStep(RecordingMenuBar.Filter(), treatment: .shown, phase: .steady, onScreen: [47], recorderItems: [60397], dots: [62231]), "an area below the menu bar")
    }

    func testAShotnixWithoutAnIdentifierCannotNameTheWindowServersWindows() {
        // ScreenCaptureKit would take them for Shotnix's own and show them.
        XCTAssertTrue(RecordingCaptureFilter.canName(ownersIdentifiers: ["", "com.apple.controlcenter"], leavingOut: "com.shotnix.app"))
        XCTAssertFalse(RecordingCaptureFilter.canName(ownersIdentifiers: ["", "com.apple.controlcenter"], leavingOut: ""), "outside its app bundle: left out window by window instead")
        XCTAssertTrue(RecordingCaptureFilter.canName(ownersIdentifiers: ["com.apple.controlcenter"], leavingOut: ""))
        XCTAssertTrue(RecordingCaptureFilter.canName(ownersIdentifiers: [], leavingOut: ""))
    }

    // MARK: Windows the capture's list leaves out

    func testAWindowTheListKeepsLeavingOutIsLetBeForAWhileAndThenAskedForAgain() {
        var unlisted = RecordingMenuBar.Unlisted()
        unlisted.note([62300], at: 10.0)
        unlisted.note([62300], at: 10.1)
        XCTAssertEqual(unlisted.givenUp(at: 10.15), [], "it may just have come on screen: the next list has it")
        unlisted.note([62300], at: 10.2)
        XCTAssertEqual(unlisted.givenUp(at: 10.25), [62300], "three lists in a row: not ten rebuilds a second for nothing")
        XCTAssertEqual(unlisted.givenUp(at: 10.2 + RecordingMenuBar.Unlisted.firstRest + 0.01), [], "but not for the rest of the recording either")
        // Still missing after the rest: a longer one.
        let again = 10.2 + RecordingMenuBar.Unlisted.firstRest + 0.1
        unlisted.note([62300], at: again)
        unlisted.note([62300], at: again + 0.1)
        unlisted.note([62300], at: again + 0.2)
        XCTAssertEqual(unlisted.givenUp(at: again + 0.2 + RecordingMenuBar.Unlisted.firstRest + 0.5), [62300])
        XCTAssertEqual(unlisted.givenUp(at: again + 0.2 + RecordingMenuBar.Unlisted.firstRest * 2 + 0.01), [])
    }

    func testEachWindowIsCountedOnItsOwn() {
        var unlisted = RecordingMenuBar.Unlisted()
        // One that never gets listed, and one that comes and goes.
        unlisted.note([1, 2], at: 0.0)
        unlisted.note([1], at: 0.1)
        unlisted.note([1, 2], at: 0.2)
        XCTAssertEqual(unlisted.givenUp(at: 0.25), [1], "the other one's coming and going doesn't start its count over")
        unlisted.note([2], at: 0.3)
        unlisted.note([2], at: 0.4)
        XCTAssertEqual(unlisted.givenUp(at: 0.45), [1, 2])
        // Listed for once, then missing again: counted from the start.
        var other = RecordingMenuBar.Unlisted()
        other.note([7], at: 0.0)
        other.note([7], at: 0.1)
        other.note([], at: 0.2)
        other.note([7], at: 0.3)
        other.note([7], at: 0.4)
        XCTAssertEqual(other.givenUp(at: 0.45), [])
    }

    func testTheRestNeverGrowsPastItsLongest() {
        var unlisted = RecordingMenuBar.Unlisted()
        var now: CFTimeInterval = 0
        for _ in 0..<12 {
            for _ in 0..<RecordingMenuBar.Unlisted.attempts {
                unlisted.note([5], at: now)
                now += 0.1
            }
            XCTAssertEqual(unlisted.givenUp(at: now), [5])
            XCTAssertEqual(unlisted.givenUp(at: now + RecordingMenuBar.Unlisted.longestRest), [], "asked for again within half a minute at the latest")
            now += RecordingMenuBar.Unlisted.longestRest + 0.1
        }
    }

    // MARK: Before the first frame

    func testWithTheIconsHiddenTheStartOnlyWaitsForTheIndicatorsToExist() {
        var frames: [CGRect]?
        var stableSince: CFTimeInterval = 0
        func up(_ windows: [RecordingMenuBar.Window], dots: Set<CGWindowID>, at now: CFTimeInterval) -> Bool {
            RecordingIndicatorWarmUp.indicatorsAreUp(RecordingMenuBar.Look(controlCenter: windows, dots: dots), settled: false, lastFrames: &frames, stableSince: &stableSince, now: now)
        }
        let bar = [item(47, "Battery", x: 2216, width: 42)]
        XCTAssertFalse(up(bar, dots: [], at: 10))
        XCTAssertFalse(up(bar, dots: [62231], at: 10.01), "the indicator's window has to be there to be left out where Control Center can't be as an app")
        XCTAssertTrue(up(bar + [item(60411, "AudioVideoModule", x: 2168, width: 48)], dots: [62231], at: 10.02), "the icons aren't in the video: where they are doesn't matter")
    }

    func testOtherwiseTheStartWaitsUntilTheIconsHaveMadeRoomForTheIndicator() {
        var frames: [CGRect]?
        var stableSince: CFTimeInterval = 0
        func up(_ windows: [RecordingMenuBar.Window], dots: Set<CGWindowID>, at now: CFTimeInterval) -> Bool {
            RecordingIndicatorWarmUp.indicatorsAreUp(RecordingMenuBar.Look(controlCenter: windows, dots: dots), settled: true, lastFrames: &frames, stableSince: &stableSince, now: now)
        }
        let before = [item(60397, "Item-0", x: 2178, width: 38), item(47, "Battery", x: 2216, width: 42)]
        XCTAssertFalse(up(before, dots: [], at: 10.00))
        XCTAssertFalse(up(before, dots: [62231], at: 10.20), "still for long enough, but the indicator isn't up")
        // The indicator comes in at the left and the icons slide aside.
        let sliding = [item(60411, "AudioVideoModule", x: 2168, width: 48), item(60397, "Item-0", x: 2150, width: 38), item(47, "Battery", x: 2216, width: 42)]
        XCTAssertFalse(up(sliding, dots: [62231], at: 10.25))
        let there = [item(60411, "AudioVideoModule", x: 2130, width: 48), item(60397, "Item-0", x: 2092, width: 38), item(47, "Battery", x: 2216, width: 42)]
        XCTAssertFalse(up(there, dots: [62231], at: 10.40), "just arrived")
        XCTAssertFalse(up(there, dots: [62231], at: 10.50))
        XCTAssertTrue(up(there, dots: [62231], at: 10.40 + RecordingIndicatorWarmUp.settledFor + 0.001))
        // A panel opening doesn't count as the icons moving.
        XCTAssertTrue(up(there + [item(61000, "", x: 2200, width: 340, layer: 101)], dots: [62231], at: 10.60))
        XCTAssertLessThanOrEqual(RecordingIndicatorWarmUp.longestSettledWait, 1, "a recording never starts a second late for this")
    }

    func testTheIconsAreGivenTimeToStartMovingAfterTheTimerOrAMicrophoneCameUp() {
        var frames: [CGRect]?
        var stableSince: CFTimeInterval = 0
        // Both indicators long up and the icons still: but Shotnix's icon
        // became the timer at 20.0, and the others only start to slide a
        // few frames later.
        let bar = [item(60411, "AudioVideoModule", x: 2130, width: 48), item(60397, "Item-0", x: 2092, width: 38)]
        func up(_ windows: [RecordingMenuBar.Window], at now: CFTimeInterval) -> Bool {
            RecordingIndicatorWarmUp.indicatorsAreUp(RecordingMenuBar.Look(controlCenter: windows, dots: [62231]), settled: true, lastFrames: &frames, stableSince: &stableSince, since: 20.0, now: now)
        }
        XCTAssertFalse(up(bar, at: 19.0))
        XCTAssertFalse(up(bar, at: 20.05), "still for a second, but the timer has only just come up")
        XCTAssertFalse(up(bar, at: 20.0 + RecordingIndicatorWarmUp.settlesAfter - 0.01))
        let wider = [item(60411, "AudioVideoModule", x: 2105, width: 48), item(60397, "Item-0", x: 2153, width: 63)]
        XCTAssertFalse(up(wider, at: 20.0 + RecordingIndicatorWarmUp.settlesAfter + 0.01), "and now they move")
        XCTAssertFalse(up(wider, at: 20.0 + RecordingIndicatorWarmUp.settlesAfter + 0.01 + RecordingIndicatorWarmUp.settledFor - 0.01))
        XCTAssertTrue(up(wider, at: 20.0 + RecordingIndicatorWarmUp.settlesAfter + 0.01 + RecordingIndicatorWarmUp.settledFor + 0.001))
        // Nothing moved at all: started once the time they were given is up.
        frames = nil
        stableSince = 0
        XCTAssertFalse(up(bar, at: 19.5))
        XCTAssertTrue(up(bar, at: 20.0 + RecordingIndicatorWarmUp.settlesAfter + 0.001))
    }

    // MARK: What a recording gets

    func testTreatment() {
        XCTAssertEqual(RecordingMenuBar.treatment(hidesIcons: false, reachesMenuBar: true, controlCenterHostsEveryItem: true), .withoutRecorderItems, "by default the timer and the indicator stay out")
        XCTAssertEqual(RecordingMenuBar.treatment(hidesIcons: true, reachesMenuBar: true, controlCenterHostsEveryItem: true), .withoutIcons)
        XCTAssertEqual(RecordingMenuBar.treatment(hidesIcons: true, reachesMenuBar: false, controlCenterHostsEveryItem: true), .shown, "an area below the menu bar is left alone")
        XCTAssertEqual(RecordingMenuBar.treatment(hidesIcons: false, reachesMenuBar: false, controlCenterHostsEveryItem: true), .shown)
        XCTAssertEqual(RecordingMenuBar.treatment(hidesIcons: true, reachesMenuBar: true, controlCenterHostsEveryItem: false), .shown, "before macOS 26 leaving out Control Center wouldn't hide other apps' items")
    }

    func testWhichAreasReachTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(RecordingMenuBar.reachesMenuBar(screen, screenFrame: screen, barHeight: 30), "the whole display")
        XCTAssertTrue(RecordingMenuBar.reachesMenuBar(CGRect(x: 1800, y: 1000, width: 700, height: 430), screenFrame: screen, barHeight: 30), "an area whose top edge is in the bar")
        XCTAssertFalse(RecordingMenuBar.reachesMenuBar(CGRect(x: 1800, y: 1000, width: 700, height: 410), screenFrame: screen, barHeight: 30), "an area ending right under it")
        XCTAssertFalse(RecordingMenuBar.reachesMenuBar(CGRect(x: 100, y: 100, width: 640, height: 360), screenFrame: screen, barHeight: 30))
        // A second display left of the main one, lower down.
        let second = CGRect(x: -1512, y: 458, width: 1512, height: 982)
        XCTAssertTrue(RecordingMenuBar.reachesMenuBar(second, screenFrame: second, barHeight: 33))
        XCTAssertFalse(RecordingMenuBar.reachesMenuBar(CGRect(x: -1400, y: 500, width: 800, height: 600), screenFrame: second, barHeight: 33))
        XCTAssertFalse(RecordingMenuBar.reachesMenuBar(screen, screenFrame: second, barHeight: 33), "an area on another display")
    }

    func testTheIndicatorsNameAndTheItemLayerAreWhatMacOSUses() {
        XCTAssertEqual(RecordingMenuBar.systemIndicatorName, "AudioVideoModule")
        XCTAssertEqual(RecordingMenuBar.itemLayer, 25)
        XCTAssertEqual(RecordingMenuBar.controlCenterBundleID, "com.apple.controlcenter")
    }
}
