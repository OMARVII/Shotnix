import Foundation
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

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
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
