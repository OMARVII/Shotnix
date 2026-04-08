import AppKit

@MainActor
final class AboutWindowController: NSObject {

    static let shared = AboutWindowController()

    func show() {
        PreferencesWindowController.shared.show(tab: .about)
    }
}
