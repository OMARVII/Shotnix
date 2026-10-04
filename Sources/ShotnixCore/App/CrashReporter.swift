import AppKit
import Darwin

/// After Shotnix crashed, or macOS closed it for running out of memory, the
/// next launch offers to send a report: by email with macOS's crash report
/// attached, or as a GitHub issue. Nothing leaves the Mac unless the person
/// sends it themselves, and normal quits, updates and restarts never ask.
@MainActor
enum CrashReporter {
    static let supportEmail = "support@shotnix.com"
    static let issuesURL = URL(string: "https://github.com/OMARVII/Shotnix/issues/new")!

    private static let sessionKey = "crashReporterSession"
    private static let handledKey = "crashReporterHandledIncidents"
    private static let declinedKey = "crashReporterDeclined"

    /// The session before this launch, read once at startup.
    private static var previousSession: CrashSession?
    private static var session: CrashSession?
    private static var sampler: Timer?
    private static var store: UserDefaults = .standard

    // MARK: Session

    /// Remembers this launch, and how much memory it uses, so the next launch
    /// can tell a crash or an out-of-memory kill from a normal quit.
    static func startSession(defaults: UserDefaults = .standard) {
        store = defaults
        previousSession = CrashSession.load(from: defaults, key: sessionKey)
        let current = CrashSession(
            started: Date(),
            bootTime: CrashSession.currentBootTime,
            peakFootprint: CrashSession.currentFootprint,
            version: CrashReportSummary.appVersion,
            ended: false
        )
        session = current
        current.save(to: defaults, key: sessionKey)
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in sampleMemory() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    /// A normal quit: the next launch won't ask about anything.
    static func endSession() {
        sampler?.invalidate()
        guard var current = session else { return }
        current.ended = true
        current.save(to: store, key: sessionKey)
    }

    private static func sampleMemory() {
        guard var current = session else { return }
        let footprint = CrashSession.currentFootprint
        // Written only when the peak grows by a quarter of a gigabyte.
        guard footprint > current.peakFootprint + 256_000_000 else { return }
        current.peakFootprint = footprint
        session = current
        current.save(to: store, key: sessionKey)
    }

    // MARK: Offer

    /// Asks once about each crash, shortly after launch, when nothing else is
    /// on screen. `isBusy` holds it back while a recording runs.
    static func offerReportIfNeeded(isBusy: @escaping @MainActor () -> Bool, attempt: Int = 0) {
        let defaults = store
        guard !defaults.bool(forKey: declinedKey) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: attempt == 0 ? 2_500_000_000 : 10_000_000_000)
            if NSApp.modalWindow != nil || isBusy() {
                if attempt < 30 { offerReportIfNeeded(isBusy: isBusy, attempt: attempt + 1) }
                return
            }
            let handled = Set(defaults.stringArray(forKey: handledKey) ?? [])
            let since = previousSession?.started ?? Date().addingTimeInterval(-3 * 86_400)
            let reports = CrashReportFile.find(in: CrashReportFile.reportsFolder, since: since, bundleID: CrashReportSummary.bundleID)
            guard let reason = CrashPromptReason.decide(
                previous: previousSession,
                reports: reports.filter { !handled.contains($0.incident) },
                bootTime: CrashSession.currentBootTime,
                physicalMemory: ProcessInfo.processInfo.physicalMemory
            ) else { return }
            present(reason, defaults: defaults)
        }
    }

    private static func present(_ reason: CrashPromptReason, defaults: UserDefaults) {
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)
        let alert = makeAlert(for: reason)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: declinedKey) }
        if case .crash(let report) = reason {
            var handled = defaults.stringArray(forKey: handledKey) ?? []
            handled.append(report.incident)
            defaults.set(Array(handled.suffix(50)), forKey: handledKey)
        }
        switch response {
        case .alertFirstButtonReturn: sendEmail(reason)
        case .alertSecondButtonReturn: openIssue(reason)
        default: break
        }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    static func makeAlert(for reason: CrashPromptReason) -> NSAlert {
        let alert = NSAlert()
        switch reason {
        case .crash:
            alert.messageText = L("Shotnix quit unexpectedly last time")
        case .outOfMemory:
            alert.messageText = L("macOS closed Shotnix last time because it ran out of memory")
        }
        alert.informativeText = L("A report helps fix this. You'll see everything before it's sent, and it never includes your screenshots or recordings.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Send by Email…"))
        alert.addButton(withTitle: L("Report on GitHub"))
        alert.addButton(withTitle: L("Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don't ask again")
        return alert
    }

    // MARK: Sending

    private static func sendEmail(_ reason: CrashPromptReason) {
        let summary = CrashReportSummary(reason: reason)
        let attachment = savedReport(reason)
        let items: [Any] = [summary.emailBody] + (attachment.map { [$0] } ?? [])
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [supportEmail]
            service.subject = summary.subject
            service.perform(withItems: items)
            return
        }
        // No mail app set up for sharing: a plain mailto link, with the whole
        // report on the clipboard to paste.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.fullText, forType: .string)
        if let url = summary.mailtoURL(to: supportEmail) { NSWorkspace.shared.open(url) }
        ToastWindow.show(message: L("The full report is on your clipboard. Paste it into the email."), duration: 6)
    }

    private static func openIssue(_ reason: CrashPromptReason) {
        let summary = CrashReportSummary(reason: reason)
        if let url = summary.issueURL(base: issuesURL) { NSWorkspace.shared.open(url) }
        guard let file = savedReport(reason) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        ToastWindow.show(message: L("To attach the full report, drag it from Finder onto the GitHub page."), duration: 7)
    }

    /// The crash report, home folder hidden, as a .txt file GitHub and mail
    /// accept as an attachment.
    private static func savedReport(_ reason: CrashPromptReason) -> URL? {
        guard case .crash(let report) = reason else { return nil }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shotnix/Crash Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Shotnix crash report \(stamp.string(from: report.date)).txt")
        do {
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - The session record

/// What one launch of Shotnix leaves behind: when it started, on which boot
/// of the Mac, the most memory it used, and whether it quit normally.
struct CrashSession: Codable, Equatable {
    var started: Date
    var bootTime: TimeInterval
    var peakFootprint: UInt64
    var version: String
    var ended: Bool

    static func load(from defaults: UserDefaults, key: String) -> CrashSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CrashSession.self, from: data)
    }

    func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }

    /// When the Mac started, in seconds since 1970: it changes on every
    /// restart, including after a power loss.
    static var currentBootTime: TimeInterval {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
    }

    /// The memory Shotnix uses right now, as Activity Monitor counts it.
    static var currentFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

// MARK: - Why to ask

enum CrashPromptReason: Equatable {
    /// macOS saved a crash report for Shotnix.
    case crash(CrashReportFile)
    /// No crash report, but the last launch ended without quitting, on the
    /// same boot of the Mac, after using most of its memory.
    case outOfMemory(peak: UInt64, physical: UInt64, version: String)

    /// Using this much memory and then vanishing means macOS closed Shotnix:
    /// three quarters of the Mac's memory, and never less than 6 GB.
    static func memoryThreshold(physicalMemory: UInt64) -> UInt64 {
        max(6_000_000_000, physicalMemory / 4 * 3)
    }

    static func decide(previous: CrashSession?, reports: [CrashReportFile], bootTime: TimeInterval, physicalMemory: UInt64) -> CrashPromptReason? {
        if let newest = reports.max(by: { $0.date < $1.date }) { return .crash(newest) }
        // A force quit or a power cut ends a session too: only a big memory
        // peak on an unchanged boot points at macOS closing Shotnix.
        guard let previous, !previous.ended, abs(previous.bootTime - bootTime) < 2,
              previous.peakFootprint >= memoryThreshold(physicalMemory: physicalMemory) else { return nil }
        return .outOfMemory(peak: previous.peakFootprint, physical: physicalMemory, version: previous.version)
    }
}

// MARK: - macOS's crash reports

/// One of macOS's crash reports (an .ips file in ~/Library/Logs/DiagnosticReports)
/// for Shotnix: the facts the summary needs, and the whole text with the
/// home folder hidden.
struct CrashReportFile: Equatable {
    let url: URL
    let incident: String
    let date: Date
    let appVersion: String
    let build: String
    let osVersion: String
    let model: String
    /// "EXC_BAD_ACCESS (SIGSEGV)".
    let exception: String
    /// What the app or the system said on the way down, like a fatal error message.
    let messages: [String]
    /// The crashed thread, top frame first: "ShotnixCore  VideoExporter.export() + 120".
    let frames: [String]
    let text: String

    static var reportsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Shotnix's crash reports written after `since`, newest first.
    static func find(in folder: URL, since: Date, bundleID: String) -> [CrashReportFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("Shotnix") }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > since }
            .compactMap { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (try? String(contentsOf: url, encoding: .utf8)).flatMap { parse($0, url: url, bundleID: bundleID, fallbackDate: modified) }
            }
            .filter { $0.date > since }
            .sorted { $0.date > $1.date }
    }

    /// Reads a report: a line of JSON about the app, then the crash as JSON.
    /// Anything that isn't one of Shotnix's crashes is nil.
    static func parse(_ raw: String, url: URL, bundleID: String, fallbackDate: Date? = nil) -> CrashReportFile? {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        let bundleInfo = body["bundleInfo"] as? [String: Any]
        let reportBundle = header["bundleID"] as? String ?? bundleInfo?["CFBundleIdentifier"] as? String
        // 309 is a crash; hangs and resource reports have their own types.
        guard reportBundle == bundleID, header["bug_type"] as? String == "309" else { return nil }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames: [String] = threads.indices.contains(faulting)
            ? ((threads[faulting]["frames"] as? [[String: Any]]) ?? []).prefix(16).map { frame in
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
                if let symbol = frame["symbol"] as? String {
                    return "\(image)  \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
                }
                return "\(image)  0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
            }
            : []

        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "unknown"
        let signal = exception?["signal"] as? String
        var messages: [String] = []
        // Swift's fatalError and precondition messages land here.
        if let info = body["asi"] as? [String: [String]] { messages += info.values.flatMap { $0 } }
        if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] as? String {
            messages.append(indicator)
        }
        let os = body["osVersion"] as? [String: Any]
        let osText = [os?["train"] as? String, (os?["build"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")

        return CrashReportFile(
            url: url,
            incident: header["incident_id"] as? String ?? url.lastPathComponent,
            date: parseDate(header["timestamp"] as? String) ?? fallbackDate ?? .distantPast,
            appVersion: header["app_version"] as? String ?? bundleInfo?["CFBundleShortVersionString"] as? String ?? "?",
            build: header["build_version"] as? String ?? bundleInfo?["CFBundleVersion"] as? String ?? "?",
            osVersion: osText.isEmpty ? header["os_version"] as? String ?? "?" : osText,
            model: body["modelCode"] as? String ?? "?",
            exception: signal.map { "\(type) (\($0))" } ?? type,
            messages: messages.map { redacted($0) },
            frames: frames.map { redacted($0) },
            text: redacted(raw)
        )
    }

    /// "2026-10-04 12:59:42.00 +0200".
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The home folder becomes ~ and the account name "user", wherever they appear.
    static func redacted(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var result = text.replacingOccurrences(of: home, with: "~")
        if user.count > 2 {
            result = result.replacingOccurrences(of: "/Users/\(user)", with: "~")
            result = result.replacingOccurrences(of: user, with: "user")
        }
        return result
    }
}

// MARK: - What gets sent

/// The report as the person sends it, in English for the developer: the
/// versions, what happened, and the crashed thread.
struct CrashReportSummary {
    let reason: CrashPromptReason

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.shotnix.app" }
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var subject: String {
        switch reason {
        case .crash(let report): "Shotnix \(report.appVersion) crashed: \(report.exception)"
        case .outOfMemory(_, _, let version): "Shotnix \(version) ran out of memory"
        }
    }

    /// The facts, then a question for the person to answer.
    var details: String {
        var lines: [String] = []
        switch reason {
        case .crash(let report):
            lines.append("Shotnix \(report.appVersion) (\(report.build)) on \(report.osVersion), \(report.model)")
            lines.append("Crashed on \(Self.stamp(report.date)): \(report.exception)")
            lines += report.messages.prefix(3).map { "Reason: \($0)" }
            if !report.frames.isEmpty {
                lines.append("")
                lines.append("Crashed thread:")
                lines += report.frames.enumerated().map { "\($0.offset)  \($0.element)" }
            }
        case .outOfMemory(let peak, let physical, let version):
            lines.append("Shotnix \(version) on \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.model)")
            lines.append("macOS closed Shotnix after it used \(Self.gigabytes(peak)) of memory (this Mac has \(Self.gigabytes(physical))).")
        }
        return lines.joined(separator: "\n")
    }

    var emailBody: String { "\(details)\n\nWhat were you doing when it happened?\n\n" }

    /// Everything, for the clipboard: the summary and macOS's whole report.
    var fullText: String {
        guard case .crash(let report) = reason else { return emailBody }
        return "\(emailBody)\n----- macOS crash report -----\n\(report.text)"
    }

    /// A new GitHub issue with the summary filled in. GitHub refuses links
    /// much over 8,000 characters, and encoding can triple the text.
    func issueURL(base: URL) -> URL? {
        var body = "\(details)\n\n**What were you doing when it happened?**\n\n"
        if case .crash = reason {
            body += "\n_The full crash report is in the Finder window Shotnix opened: drag the file here to attach it._\n"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body", value: String(body.prefix(2_000))),
        ]
        return components?.url
    }

    /// A mailto link holds the summary only: mail apps cut long links short.
    func mailtoURL(to address: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: String(emailBody.prefix(1_500))),
        ]
        return components.url
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
    }
}
