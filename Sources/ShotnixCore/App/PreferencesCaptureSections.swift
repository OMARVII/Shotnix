import AppKit
import SwiftUI

// Settings → Screenshots sections for capture and history options added
// in 0.24, kept out of PreferencesWindowController to keep that file's
// hunks small.

/// Capture on release vs. an adjustable selection.
struct CaptureSelectionPreferences: View {
    @AppStorage("captureImmediatelyAfterSelecting") var captureImmediately = true

    var body: some View {
        PreferenceSection("Selection") {
            PreferenceRow("Capture immediately after selecting") {
                Toggle("", isOn: $captureImmediately)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }

        PreferenceFootnote(text: captureImmediately
            ? "Releasing the mouse takes the shot. Hold ⇧ as you release to adjust the selection first — drag its edges, nudge it with the arrow keys, then press Return."
            : "The selection stays on screen to adjust — drag its edges, nudge it with the arrow keys, then press Return. Hold ⇧ as you release to capture right away.")
    }
}

/// Language and accuracy for Capture Text and History search.
struct TextRecognitionPreferences: View {
    @AppStorage("ocrFastRecognition") var fast = false
    @AppStorage("ocrLanguages") var languagesRaw = ""

    private var chosen: [String] {
        languagesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var supported: [String] {
        OCREngine.supportedLanguages(fast: fast)
    }

    private var languagesTitle: String {
        let names = chosen.map(Self.displayName(for:))
        return names.isEmpty ? "Automatic" : names.joined(separator: ", ")
    }

    var body: some View {
        PreferenceSection("Text Recognition") {
            PreferenceRow("Accuracy") {
                PreferenceSegmentedSelector(
                    selection: $fast,
                    options: [
                        PreferenceOption(value: false, title: "Accurate"),
                        PreferenceOption(value: true, title: "Fast")
                    ]
                )
            }

            PreferenceDivider()

            PreferenceRow("Languages") {
                Menu {
                    Button {
                        languagesRaw = ""
                    } label: {
                        if chosen.isEmpty {
                            Label("Automatic", systemImage: "checkmark")
                        } else {
                            Text("Automatic")
                        }
                    }
                    Divider()
                    ForEach(supported, id: \.self) { code in
                        Toggle(Self.displayName(for: code), isOn: binding(for: code))
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(languagesTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.44))
                    }
                    .foregroundStyle(Color.white.opacity(0.86))
                    .padding(.horizontal, 10)
                    .frame(width: 190, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }

        PreferenceFootnote(text: "Automatic detects each capture's language; pick languages when it guesses wrong. Accurate reads small text best — Fast answers sooner but knows fewer languages. Used by Capture Text, Copy Text, and History search.")
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(code) },
            set: { isOn in
                var languages = chosen.filter { $0 != code }
                if isOn { languages.append(code) }
                languagesRaw = languages.joined(separator: ",")
            }
        )
    }

    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// How long History keeps captures, what it costs on disk, and Clean Up.
struct HistoryPreferences: View {
    @AppStorage("historyRetention") var retentionRaw = HistoryRetention.forever.rawValue
    @State private var usageBytes: Int64?
    @State private var isCleaning = false

    private var historyManager: HistoryManager? {
        (NSApp.delegate as? AppDelegate)?.historyManager
    }

    private var retention: Binding<String> {
        Binding(
            get: { retentionRaw },
            set: { newValue in
                guard let policy = HistoryRetention(rawValue: newValue), newValue != retentionRaw else { return }
                guard Self.confirmRetentionChange(to: policy, manager: historyManager) else { return }
                retentionRaw = newValue
                historyManager?.applyRetention(policy)
                refreshUsage()
            }
        )
    }

    var body: some View {
        PreferenceSection("History") {
            PreferenceRow("Keep captures") {
                PreferenceMenuSelector(
                    selection: retention,
                    options: HistoryRetention.allCases.map { PreferenceOption(value: $0.rawValue, title: $0.title) },
                    width: 190
                )
            }

            PreferenceDivider()

            PreferenceRow("Storage", detail: usageDetail) {
                Button(isCleaning ? "Cleaning Up…" : "Clean Up…") {
                    cleanUp()
                }
                .buttonStyle(.bordered)
                .disabled(isCleaning || historyManager == nil)
            }
        }
        .onAppear(perform: refreshUsage)

        PreferenceFootnote(text: "Captures stay in History until you delete them, unless you pick a limit here. Clean Up empties History's trash (deleted captures you could still undo) and removes files no capture uses anymore.")
    }

    private var usageDetail: String {
        let count = historyManager?.items.count ?? 0
        let captures = count == 1 ? "1 capture" : "\(count.formatted()) captures"
        guard let usageBytes else { return "History uses … (\(captures))" }
        return "History uses \(Self.formatted(bytes: usageBytes)) (\(captures))"
    }

    static func formatted(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshUsage() {
        guard let historyManager else { return }
        Task { @MainActor in
            usageBytes = await historyManager.diskUsage()
        }
    }

    private func cleanUp() {
        guard let historyManager else { return }
        let alert = NSAlert()
        alert.messageText = "Clean Up History?"
        let expiring = historyManager.itemsExceedingRetention(Settings.historyRetention).count
        alert.informativeText = expiring == 0
            ? "Deleted captures waiting in History's trash and files no capture uses are removed for good. The captures in your history stay."
            : "Deleted captures waiting in History's trash and files no capture uses are removed for good, along with \(expiring == 1 ? "1 capture" : "\(expiring.formatted()) captures") past your History limit. The rest of your history stays."
        alert.addButton(withTitle: "Clean Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isCleaning = true
        Task { @MainActor in
            let freed = await historyManager.cleanUp()
            usageBytes = await historyManager.diskUsage()
            isCleaning = false
            ToastWindow.show(message: freed > 0 ? "Freed \(Self.formatted(bytes: freed))" : "History was already tidy")
        }
    }

    /// A newly picked limit that would delete captures right away asks first.
    static func confirmRetentionChange(to policy: HistoryRetention, manager: HistoryManager?) -> Bool {
        let doomed = manager?.itemsExceedingRetention(policy).count ?? 0
        guard doomed > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = doomed == 1 ? "Delete 1 Capture?" : "Delete \(doomed.formatted()) Captures?"
        alert.informativeText = "Keeping \(policy.title.lowercased()) removes \(doomed == 1 ? "1 older capture" : "\(doomed.formatted()) older captures") from History now. This can't be undone."
        alert.addButton(withTitle: "Delete Captures")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
