import AppKit
import Darwin
import UniformTypeIdentifiers
import ImageIO

/// CGImage is immutable and safe to read from any thread; this box just
/// carries one across a Task.detached boundary without a Sendable warning.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum ImageExporter {

    enum ExportError: LocalizedError {
        case pngEncodingFailed
        case encodingFailed
        case noImageData

        var errorDescription: String? {
            switch self {
            case .pngEncodingFailed:
                "Could not encode screenshot as PNG."
            case .encodingFailed:
                "Could not encode the screenshot."
            case .noImageData:
                "The screenshot has no image data."
            }
        }
    }

    enum SavePanelResult {
        case saved(URL)
        case cancelled
        case failed(URL?)

        var didSave: Bool {
            if case .saved = self { return true }
            return false
        }
    }

    private static let webpUTI = "org.webmproject.webp" as CFString
    private static var activeSavePanels: [NSSavePanel] = []

    /// Every write funnels through one serial queue, so two saves that pick
    /// the same timestamped name (All Displays, a burst of captures) can't
    /// both claim it.
    private static let writeQueue = DispatchQueue(label: "com.shotnix.export.write", qos: .userInitiated)

    // MARK: – Clipboard

    /// Encodes first and only then replaces the clipboard — a failed encode
    /// must never leave the user with an emptied clipboard. Returns whether
    /// the image actually reached it, so callers only confirm a real copy.
    @discardableResult
    static func copyToClipboard(image: NSImage, pasteboard: NSPasteboard = .general) -> Bool {
        guard let cg = image.bestCGImage, let png = pngData(from: cg) else { return false }
        return writePNG(png, to: pasteboard)
    }

    /// Clipboard copy with the PNG encode off the main thread — a 5K capture's
    /// encode otherwise lands exactly while the overlay animates in. The
    /// pasteboard itself is only touched back on the main actor.
    @MainActor
    static func copyToClipboardAsync(image: NSImage, pasteboard: NSPasteboard = .general, completion: ((Bool) -> Void)? = nil) {
        guard let cg = image.bestCGImage else {
            completion?(false)
            return
        }
        let box = SendableCGImage(cg)
        Task.detached(priority: .userInitiated) {
            let png = pngData(from: box.image)
            await MainActor.run {
                if let png { writePNG(png, to: pasteboard) }
                completion?(png != nil)
            }
        }
    }

    @discardableResult
    private static func writePNG(_ png: Data, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        // PNG only — NSPasteboard synthesizes TIFF on demand for legacy readers,
        // and every modern macOS app (Slack, Notion, Figma, Preview, Messages)
        // prefers PNG. Skipping the TIFF encode saves ~30 MB + ~50 ms per 4K copy.
        pb.declareTypes([.png], owner: nil)
        return pb.setData(png, forType: .png)
    }

    // MARK: – Auto-named saves

    /// Saves under a fresh name in `directory`: a name that's taken gets
    /// " 2", " 3"… (the recording convention) instead of replacing the file.
    /// Encode and write run off the main thread; the completion runs on the
    /// main actor with the URL actually written (WebP may become PNG).
    @MainActor
    static func autoSave(
        image: NSImage,
        in directory: URL,
        baseName: String = timestampedName,
        format: String = Settings.screenshotFormat,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        guard let cg = image.bestCGImage else {
            completion?(.failure(ExportError.noImageData))
            return
        }
        let box = SendableCGImage(cg)
        let quality = CGFloat(Settings.jpegQuality)
        Task { @MainActor in
            do {
                let url = try await onWriteQueue {
                    let (data, ext) = try encode(cg: box.image, format: format, jpegQuality: quality)
                    let url = try writeWithoutReplacing(data, in: directory, baseName: baseName, pathExtension: ext)
                    HistoryManager.applyScreenshotMetadata(to: url.path, rect: nil)
                    return url
                }
                completion?(.success(url))
            } catch {
                print("[Shotnix] Auto-save failed in \(directory.path): \(error)")
                completion?(.failure(error))
            }
        }
    }

    /// `baseName.ext`, or the first free `baseName N.ext` (N ≥ 2).
    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String, fileManager: FileManager = .default) -> URL {
        var url = directory.appendingPathComponent("\(baseName).\(pathExtension)")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName) \(suffix).\(pathExtension)")
            suffix += 1
        }
        return url
    }

    /// Writes to a hidden temp file, then renames it into place with
    /// RENAME_EXCL — atomic, and it refuses to replace a file another app
    /// created under the same name a moment ago.
    private static func writeWithoutReplacing(_ data: Data, in directory: URL, baseName: String, pathExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".shotnix-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        for _ in 0..<1000 {
            let candidate = uniqueURL(in: directory, baseName: baseName, pathExtension: pathExtension)
            let status = temp.withUnsafeFileSystemRepresentation { source in
                candidate.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source!, destination!, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            if code == ENOTSUP || code == EINVAL {
                // Volumes without exclusive rename (some network shares):
                // an exclusive create still never replaces anything.
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Toast text for a failed auto-save. Every variant ends by pointing at
    /// the fix, because the toast opens Settings → Screenshots on click.
    static func autoSaveFailureMessage(for error: Error, directory: URL) -> String {
        let folderName = FileManager.default.displayName(atPath: directory.path)
        let folder = folderName.isEmpty ? directory.lastPathComponent : folderName
        if isOutOfSpace(error) {
            return "Couldn't save the screenshot: the disk is full. Free up space or pick another save folder."
        }
        if isPermissionDenied(error) {
            return "Couldn't save the screenshot: Shotnix can't write to \(folder). Click to choose another save folder."
        }
        if error is ExportError {
            return "Couldn't save the screenshot: it could not be encoded as \(Settings.screenshotFormat.uppercased())."
        }
        return "Couldn't save the screenshot to \(folder). Click to check the save folder."
    }

    private static func posixCodes(in error: Error) -> [Int] {
        var codes: [Int] = []
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain { codes.append(nsError.code) }
            if nsError.domain == NSCocoaErrorDomain {
                switch nsError.code {
                case NSFileWriteOutOfSpaceError: codes.append(Int(ENOSPC))
                case NSFileWriteNoPermissionError: codes.append(Int(EACCES))
                case NSFileWriteVolumeReadOnlyError: codes.append(Int(EROFS))
                default: break
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        posixCodes(in: error).contains { $0 == Int(ENOSPC) || $0 == Int(EDQUOT) }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        posixCodes(in: error).contains { $0 == Int(EACCES) || $0 == Int(EPERM) || $0 == Int(EROFS) }
    }

    private static func onWriteQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: – Filename template

    /// Base name (no extension) for every screenshot/recording/drag export,
    /// rendered from the user's filename template (Preferences → Screenshots).
    static var timestampedName: String {
        renderFilenameTemplate(Settings.filenameTemplate)
    }

    /// Renders a filename template. Tokens: %y year (4-digit), %m month,
    /// %d day, %H hour (24h), %M minute, %S second, %% literal percent.
    /// Path-hostile characters are sanitized; an empty result falls back to
    /// the default template so callers always get a usable name.
    static func renderFilenameTemplate(_ template: String, date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int = 2) -> String {
            String(format: "%0\(width)d", value ?? 0)
        }

        var rendered = ""
        rendered.reserveCapacity(template.count + 16)
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            let next = template.index(after: index)
            if ch == "%", next < template.endIndex {
                switch template[next] {
                case "y": rendered += pad(c.year, 4)
                case "m": rendered += pad(c.month)
                case "d": rendered += pad(c.day)
                case "H": rendered += pad(c.hour)
                case "M": rendered += pad(c.minute)
                case "S": rendered += pad(c.second)
                case "%": rendered += "%"
                default:
                    rendered.append(ch)
                    rendered.append(template[next])
                }
                index = template.index(after: next)
            } else {
                rendered.append(ch)
                index = next
            }
        }

        // "/" would create directories and ":" renders as "/" in Finder.
        rendered = rendered
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rendered.isEmpty {
            return renderFilenameTemplate(Settings.defaultFilenameTemplate, date: date)
        }
        return rendered
    }

    /// The template rendered for when a capture was TAKEN — drags and Save
    /// As from history name files after the capture, not after the drag.
    static func captureName(for date: Date) -> String {
        renderFilenameTemplate(Settings.filenameTemplate, date: date)
    }

    // MARK: – Save with panel

    @MainActor
    static func saveWithPanel(image: NSImage, suggestedName: String, presentingWindow: NSWindow? = nil, completion: ((SavePanelResult) -> Void)? = nil) {
        NSApp.unhide(nil)
        NSApp.ensureForegroundCapable()
        NSApp.activate(ignoringOtherApps: true)
        presentingWindow?.deminiaturize(nil)
        presentingWindow?.makeKeyAndOrderFront(nil)
        presentingWindow?.orderFrontRegardless()

        let panel = NSSavePanel()
        let preferredExt = availableFormats.contains(Settings.screenshotFormat) ? Settings.screenshotFormat : "png"
        panel.nameFieldStringValue = "\(suggestedName).\(preferredExt)"
        var contentTypes: [UTType] = [.png, .jpeg]
        if isWebPSupported, let webp = UTType("org.webmproject.webp") {
            contentTypes.append(webp)
        }
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        activeSavePanels.append(panel)

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            activeSavePanels.removeAll { $0 === panel }

            guard response == .OK else {
                completion?(.cancelled)
                return
            }

            guard let url = panel.url else {
                completion?(.failed(nil))
                showSaveFailedAlert(for: nil, presentingWindow: presentingWindow)
                return
            }

            // The panel already confirmed replacing an existing file, so this
            // write may overwrite — unlike auto-named saves.
            saveAsync(image: image, to: url) { result in
                switch result {
                case .success(let savedURL):
                    completion?(.saved(savedURL))
                case .failure:
                    completion?(.failed(url))
                    showSaveFailedAlert(for: url, presentingWindow: presentingWindow)
                }
            }
        }

        if let presentingWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    @MainActor
    private static func showSaveFailedAlert(for url: URL?, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Save Screenshot"
        if let url {
            alert.informativeText = "Shotnix could not write the file to:\n\(url.path)"
        } else {
            alert.informativeText = "The save panel did not return a destination. Please try saving again."
        }
        alert.addButton(withTitle: "OK")

        if let presentingWindow, presentingWindow.isVisible {
            alert.beginSheetModal(for: presentingWindow)
        } else {
            alert.runModal()
        }
    }

    // MARK: – Explicit destination

    /// Writes exactly to `url` (replacing a file there), off the main thread.
    /// Only for destinations the user picked — auto-named saves use autoSave.
    @MainActor
    static func saveAsync(image: NSImage, to url: URL, completion: ((Result<URL, Error>) -> Void)? = nil) {
        guard let cg = image.bestCGImage else {
            completion?(.failure(ExportError.noImageData))
            return
        }
        let box = SendableCGImage(cg)
        let quality = CGFloat(Settings.jpegQuality)
        Task { @MainActor in
            do {
                let saved = try await onWriteQueue {
                    try encodeAndWrite(cg: box.image, to: url, jpegQuality: quality)
                }
                completion?(.success(saved))
            } catch {
                print("[Shotnix] Save failed at \(url.path): \(error)")
                completion?(.failure(error))
            }
        }
    }

    /// Synchronous explicit-destination save for callers already off the
    /// main thread (and tests).
    @discardableResult
    static func save(image: NSImage, to url: URL) -> URL? {
        // Extract the CGImage once and reuse it for whichever encoder runs.
        guard let cg = image.bestCGImage else {
            print("[Shotnix] Save failed: image has no CGImage backing")
            return nil
        }
        return try? encodeAndWrite(cg: cg, to: url, jpegQuality: CGFloat(Settings.jpegQuality))
    }

    /// Encode + atomic write core, safe on any thread — the format switch on
    /// the destination extension, the WebP→PNG fallback, and metadata tagging.
    private static func encodeAndWrite(cg: CGImage, to url: URL, jpegQuality: CGFloat) throws -> URL {
        let (data, ext) = try encode(cg: cg, format: url.pathExtension, jpegQuality: jpegQuality)
        let outputURL = ext == url.pathExtension.lowercased() || (ext == "jpeg" && url.pathExtension.lowercased() == "jpg")
            ? url
            : url.deletingPathExtension().appendingPathExtension(ext)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        HistoryManager.applyScreenshotMetadata(to: outputURL.path, rect: nil)
        return outputURL
    }

    /// Image data for a format name or extension, plus the extension the
    /// data really has — WebP falls back to PNG where macOS can't write it.
    private static func encode(cg: CGImage, format: String, jpegQuality: CGFloat) throws -> (Data, String) {
        let data: Data?
        let ext: String
        switch format.lowercased() {
        case "jpg", "jpeg":
            data = jpegData(from: cg, quality: jpegQuality)
            ext = "jpeg"
        case "webp" where isWebPSupported:
            data = webpData(from: cg)
            ext = "webp"
        default:
            data = pngData(from: cg)
            ext = "png"
        }
        guard let data else { throw ExportError.encodingFailed }
        return (data, ext)
    }

    // MARK: – Drag files

    /// Finder and nearly every app accept a real file URL on drop (promises
    /// are spottier), so drags hand over a file in a private temp folder,
    /// removed a few minutes later.
    private static let dragFileLifetime: TimeInterval = 300

    /// Clones `source` (APFS clone: instant, keeps Finder tags and metadata)
    /// under `name`. Each file gets its own folder so two drags of captures
    /// taken in the same second never collide.
    static func dragFile(copying source: URL, named name: String) -> URL? {
        guard let destination = makeDragFileURL(named: name, pathExtension: source.pathExtension) else { return nil }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            scheduleDragFileCleanup(destination)
            return destination
        } catch {
            print("[Shotnix] Drag export failed at \(destination.path): \(error)")
            return nil
        }
    }

    static func dragFile(data: Data, named name: String, pathExtension: String = "png") -> URL? {
        guard let destination = makeDragFileURL(named: name, pathExtension: pathExtension) else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            HistoryManager.applyScreenshotMetadata(to: destination.path, rect: nil)
            scheduleDragFileCleanup(destination)
            return destination
        } catch {
            print("[Shotnix] Drag export failed at \(destination.path): \(error)")
            return nil
        }
    }

    private static func makeDragFileURL(named name: String, pathExtension: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixDrag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("[Shotnix] Drag export folder failed: \(error)")
            return nil
        }
        return folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
    }

    private static func scheduleDragFileCleanup(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + dragFileLifetime) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: – Format helpers
    //
    // The CGImage-taking variants are the primitive — each encode extracts the
    // best CGImage off the NSImage at most once per call site. The NSImage
    // overloads are kept for callers that don't already hold a CGImage.

    static func pngData(from cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from cg: CGImage, quality: CGFloat = 0.95) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func webpData(from cg: CGImage, quality: CGFloat = 0.90) -> Data? {
        guard isWebPSupported else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, webpUTI, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// ImageIO reads WebP but, on the macOS versions we ship to so far,
    /// can't write it — so the option only exists where it really works.
    static var isWebPSupported: Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
        return identifiers.contains(webpUTI)
    }

    /// Formats offered in Preferences and the save panel.
    static var availableFormats: [String] {
        isWebPSupported ? ["png", "jpeg", "webp"] : ["png", "jpeg"]
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return pngData(from: cg)
    }

    static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return jpegData(from: cg, quality: quality)
    }

    static func webpData(from image: NSImage, quality: CGFloat = 0.90) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return webpData(from: cg, quality: quality)
    }
}

extension NSImage {
    /// Extract the highest-resolution CGImage backing this NSImage.
    /// Prefers the raw CGImage from NSBitmapImageRep (zero resampling) over
    /// `cgImage(forProposedRect:)` which re-renders through CoreGraphics and
    /// can introduce interpolation blur.
    ///
    /// Cached per-instance via associated object so repeated export paths
    /// (history PNG + thumbnail + clipboard) only compute this once.
    var bestCGImage: CGImage? {
        if let cached = objc_getAssociatedObject(self, &NSImage.bestCGImageKey) as! CGImage? {
            return cached
        }
        let computed = computeBestCGImage()
        if let computed {
            objc_setAssociatedObject(self, &NSImage.bestCGImageKey, computed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return computed
    }

    private static var bestCGImageKey: UInt8 = 0

    private func computeBestCGImage() -> CGImage? {
        var best: CGImage?
        var bestPixels = 0
        for rep in representations {
            if let bitmapRep = rep as? NSBitmapImageRep, let cg = bitmapRep.cgImage {
                let pixels = cg.width * cg.height
                if pixels > bestPixels {
                    best = cg
                    bestPixels = pixels
                }
            }
        }
        if let best { return best }

        let maxRep = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        let pixelW = maxRep?.pixelsWide ?? Int(size.width)
        let pixelH = maxRep?.pixelsHigh ?? Int(size.height)
        var proposedRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
