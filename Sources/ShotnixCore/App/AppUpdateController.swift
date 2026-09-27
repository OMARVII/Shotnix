import AppKit
import Sparkle

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?

    override init() {
        super.init()

        guard AppUpdateConfiguration.current != nil else {
            print("[Shotnix] Sparkle updates are disabled because SUPublicEDKey is not configured.")
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// An update never relaunches the app in the middle of a recording or an
    /// export: it installs once they have ended.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard AppTermination.isBusy else { return false }
            AppTermination.whenIdle { installHandler() }
            return true
        }
    }

    /// With automatic updates on, Sparkle downloads an update in the
    /// background and installs it when the app quits. A menu bar app is
    /// rarely quit, so the update could wait for days: Shotnix installs it
    /// itself as soon as it's quiet (it quits and reopens in a moment).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            quietInstaller.schedule(immediateInstallHandler)
            return true
        }
    }

    private let quietInstaller = QuietUpdateInstaller()

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }
}

/// Holds a downloaded update until nothing would notice Shotnix quitting and
/// reopening: no recording or export running, no window open (an editor,
/// Settings, a pin, the capture overlay), and a minute without typing or
/// pointing, so the next shortcut isn't the one that lands mid-relaunch.
@MainActor
final class QuietUpdateInstaller {
    nonisolated static let idleSeconds: Double = 60
    private var install: (() -> Void)?
    private var timer: Timer?

    func schedule(_ install: @escaping () -> Void) {
        self.install = install
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        installIfQuiet()
    }

    private func installIfQuiet() {
        guard let install, Self.isQuiet(busy: AppTermination.isBusy, openWindows: Self.openWindowCount, idleSeconds: Self.systemIdleSeconds) else { return }
        self.install = nil
        timer?.invalidate()
        timer = nil
        install()
    }

    nonisolated static func isQuiet(busy: Bool, openWindows: Int, idleSeconds: Double) -> Bool {
        !busy && openWindows == 0 && idleSeconds >= Self.idleSeconds
    }

    /// Windows someone could be looking at; the menu bar icon's own window
    /// doesn't count.
    private static var openWindowCount: Int {
        NSApp.windows.filter {
            $0.isVisible && $0.alphaValue > 0 && $0.frame.width > 1 && $0.frame.height > 1
                && !String(describing: type(of: $0)).contains("StatusBar")
        }.count
    }

    /// Seconds since the last key press, click or pointer move, anywhere.
    private static var systemIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

struct AppUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicEDKey: String

    static var current: AppUpdateConfiguration? {
        AppUpdateConfiguration(
            feedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    init?(feedURLString: String?, publicEDKey: String?) {
        guard let feedURLString,
              let feedURL = URL(string: feedURLString),
              let publicEDKey,
              !publicEDKey.isEmpty,
              !publicEDKey.contains("SET_SPARKLE_PUBLIC_ED_KEY") else {
            return nil
        }

        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }
}
