import AppKit

/// Floating panel showing all past captures in a grouped NSCollectionView.
@MainActor
final class HistoryPanelController: NSObject {

    static let shared = HistoryPanelController()

    private var panel: NSPanel?
    private weak var historyManager: HistoryManager?
    private var collectionView: NSCollectionView?
    private var emptyOverlay: NSView?
    private var countLabel: NSTextField?
    private var closeObserver: NSObjectProtocol?

    private struct Section {
        let title: String
        let items: [HistoryItem]
    }

    private var sections: [Section] = []

    // MARK: - Show / Hide

    func show(historyManager: HistoryManager) {
        self.historyManager = historyManager
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            buildSections()
            collectionView?.reloadData()
            updateEmptyState()
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Shotnix - Capture History"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isFloatingPanel = true
        p.minSize = NSSize(width: 760, height: 520)
        p.center()
        p.contentView = buildContent(historyManager: historyManager)
        p.alphaValue = 0
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.panelDidClose(notification) }
        }
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        panel = p
    }

    // MARK: - Content

    private func buildContent(historyManager: HistoryManager) -> NSView {
        let container = HistoryStageView(frame: NSRect(x: 0, y: 0, width: 920, height: 640))

        let header = NSView(frame: NSRect(x: 0, y: 532, width: 920, height: 108))
        header.autoresizingMask = [.width, .minYMargin]

        let eyebrow = NSTextField(labelWithString: "SHOTNIX LIBRARY")
        eyebrow.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        eyebrow.textColor = NSColor.controlAccentColor.withAlphaComponent(0.92)
        eyebrow.frame = NSRect(x: 28, y: 70, width: 240, height: 16)
        header.addSubview(eyebrow)

        let title = NSTextField(labelWithString: "Capture History")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.94)
        title.frame = NSRect(x: 28, y: 34, width: 360, height: 34)
        header.addSubview(title)

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 12, weight: .medium)
        count.textColor = NSColor.white.withAlphaComponent(0.48)
        count.frame = NSRect(x: 30, y: 16, width: 560, height: 16)
        header.addSubview(count)
        countLabel = count

        let clearBtn = HistoryActionButton(title: "Clear All", variant: .destructive, target: self, action: #selector(clearAll))
        clearBtn.frame = NSRect(x: 770, y: 42, width: 118, height: 34)
        clearBtn.autoresizingMask = [.minXMargin]
        clearBtn.toolTip = "Delete every saved capture"
        header.addSubview(clearBtn)
        container.addSubview(header)

        // Collection view
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 190, height: 238)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 24, right: 20)
        layout.headerReferenceSize = NSSize(width: 920, height: 36)

        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.register(
            HistoryCollectionItem.self,
            forItemWithIdentifier: HistoryCollectionItem.identifier
        )
        cv.register(
            HistorySectionHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: HistorySectionHeader.identifier
        )
        cv.dataSource = self
        cv.delegate = self
        cv.backgroundColors = [.clear]
        cv.isSelectable = false
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 888, height: 508))
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)

        collectionView = cv

        // Empty state overlay
        let empty = buildEmptyOverlay(frame: scroll.frame)
        empty.autoresizingMask = [.width, .height]
        container.addSubview(empty)
        emptyOverlay = empty

        buildSections()
        updateHeader()
        updateEmptyState()

        return container
    }

    private func buildEmptyOverlay(frame: NSRect) -> NSView {
        let overlay = NSView(frame: frame)

        let stack = HistoryEmptyStateCard(frame: NSRect(x: 0, y: 0, width: 360, height: 190))

        let icon = NSImageView(frame: NSRect(x: 150, y: 122, width: 60, height: 46))
        if let symbolImg = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 38, weight: .medium)
            icon.image = symbolImg.withSymbolConfiguration(config)
        }
        icon.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.86)
        stack.addSubview(icon)

        let title = NSTextField(labelWithString: "No captures yet")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 88, width: 360, height: 24)
        stack.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Press \u{2318}\u{21E7}4 to take your first screenshot")
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.50)
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 24, y: 56, width: 312, height: 18)
        stack.addSubview(subtitle)

        let hint = NSTextField(labelWithString: "Captured screenshots will appear here instantly")
        hint.font = .systemFont(ofSize: 12, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.36)
        hint.alignment = .center
        hint.frame = NSRect(x: 24, y: 30, width: 312, height: 16)
        stack.addSubview(hint)

        stack.frame.origin = NSPoint(
            x: (frame.width - stack.frame.width) / 2,
            y: (frame.height - stack.frame.height) / 2
        )
        stack.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        overlay.addSubview(stack)

        return overlay
    }

    private func updateEmptyState() {
        emptyOverlay?.isHidden = !sections.isEmpty
        updateHeader()
    }

    private func updateHeader() {
        let total = sections.reduce(0) { $0 + $1.items.count }
        let captureWord = total == 1 ? "capture" : "captures"
        countLabel?.stringValue = total == 0
            ? "No saved captures yet"
            : "\(total) saved \(captureWord) · drag any card to Finder · right-click for more actions"
    }

    // MARK: - Sections

    private func buildSections() {
        guard let manager = historyManager else { sections = []; return }
        let calendar = Calendar.current
        var today: [HistoryItem] = []
        var yesterday: [HistoryItem] = []
        var thisWeek: [HistoryItem] = []
        var older: [HistoryItem] = []

        for item in manager.items {
            if calendar.isDateInToday(item.createdAt) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.createdAt) {
                yesterday.append(item)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()),
                      item.createdAt > weekAgo {
                thisWeek.append(item)
            } else {
                older.append(item)
            }
        }

        sections = []
        if !today.isEmpty { sections.append(Section(title: "Today", items: today)) }
        if !yesterday.isEmpty { sections.append(Section(title: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { sections.append(Section(title: "This Week", items: thisWeek)) }
        if !older.isEmpty { sections.append(Section(title: "Older", items: older)) }
    }

    // MARK: - Reload

    func reloadAfterDelete() {
        buildSections()
        collectionView?.reloadData()
        updateEmptyState()
    }

    private func reload() {
        buildSections()
        collectionView?.reloadData()
        updateEmptyState()
    }

    // MARK: - Actions

    @objc private func panelDidClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow, closedWindow === panel else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        panel = nil
        collectionView = nil
        emptyOverlay = nil
        countLabel = nil
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: closedWindow)
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "This will permanently delete all captured screenshots."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        historyManager?.deleteAll()
        reload()
    }
}

// MARK: - NSCollectionViewDataSource

extension HistoryPanelController: NSCollectionViewDataSource {

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        return max(sections.count, 1)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard !sections.isEmpty else { return 0 }
        return sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(
            withIdentifier: HistoryCollectionItem.identifier,
            for: indexPath
        ) as! HistoryCollectionItem
        let historyItem = sections[indexPath.section].items[indexPath.item]
        cell.configure(with: historyItem, historyManager: historyManager!)
        return cell
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: HistorySectionHeader.identifier,
            for: indexPath
        ) as! HistorySectionHeader
        if !sections.isEmpty {
            header.configure(title: sections[indexPath.section].title)
        }
        return header
    }
}

// MARK: - NSCollectionViewDelegate + Drag

extension HistoryPanelController: NSCollectionViewDelegate {

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard !sections.isEmpty else { return nil }
        let item = sections[indexPath.section].items[indexPath.item]
        return NSFilePromiseProvider(fileType: "public.png", delegate: HistoryImageFilePromiseDelegate(image: item.fullImage))
    }
}

private final class HistoryImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Shotnix.HistoryFilePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "\(ImageExporter.timestampedName).png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            guard let png = ImageExporter.pngData(from: image) else {
                handler(ImageExporter.ExportError.pngEncodingFailed)
                return
            }
            try png.write(to: url, options: .atomic)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }
}

// MARK: - Collection View Item

@MainActor
final class HistoryCollectionItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("HistoryCollectionItem")

    private var historyItem: HistoryItem?
    private weak var historyManager: HistoryManager?
    private var trackingArea: NSTrackingArea?
    private let cardView = HistoryCaptureCardView()
    private let previewWell = HistoryPreviewWellView()
    private let thumbView = NSImageView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let copyBtn = HistoryActionButton(title: "Copy", variant: .secondary, target: nil, action: nil)
    private let editBtn = HistoryActionButton(title: "Edit", variant: .primary, target: nil, action: nil)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 238))

        cardView.frame = container.bounds
        cardView.autoresizingMask = [.width, .height]
        container.addSubview(cardView)

        previewWell.frame = NSRect(x: 12, y: 70, width: 166, height: 140)
        container.addSubview(previewWell)

        thumbView.frame = previewWell.frame.insetBy(dx: 8, dy: 7)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 10
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.allowsEdgeAntialiasing = true
        thumbView.layer?.borderWidth = 0
        thumbView.layer?.borderColor = NSColor.clear.cgColor
        thumbView.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(thumbView)

        dateLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        dateLabel.alignment = .left
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.frame = NSRect(x: 14, y: 48, width: 162, height: 15)
        container.addSubview(dateLabel)

        detailLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 14, y: 33, width: 162, height: 13)
        container.addSubview(detailLabel)

        copyBtn.frame = NSRect(x: 14, y: 7, width: 74, height: 24)
        copyBtn.target = self
        copyBtn.action = #selector(copyImage)
        copyBtn.toolTip = "Copy capture to clipboard"
        container.addSubview(copyBtn)

        editBtn.frame = NSRect(x: 102, y: 7, width: 74, height: 24)
        editBtn.target = self
        editBtn.action = #selector(editImage)
        editBtn.toolTip = "Open in annotation editor"
        container.addSubview(editBtn)

        self.view = container
    }

    func configure(with item: HistoryItem, historyManager: HistoryManager) {
        self.historyItem = item
        self.historyManager = historyManager
        thumbView.image = historyManager.cachedThumbnail(for: item) ?? item.thumbnail
        dateLabel.stringValue = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        detailLabel.stringValue = detailText(for: item)
        setupTracking()
    }

    private func detailText(for item: HistoryItem) -> String {
        if let rect = item.captureRect?.cgRect {
            return String(format: "%.0f x %.0f capture", rect.width, rect.height)
        }
        let size = item.thumbnail.size
        guard size.width > 0, size.height > 0 else { return "Saved capture" }
        return String(format: "%.0f x %.0f image", size.width, size.height)
    }

    // MARK: Hover

    private func setupTracking() {
        if let old = trackingArea { view.removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cardView.animator().alphaValue = 1
            previewWell.animator().alphaValue = 1
            thumbView.animator().layer?.transform = CATransform3DMakeScale(1.014, 1.014, 1)
        }
        cardView.isHovered = true
        previewWell.isHovered = true
        thumbView.layer?.shadowColor = NSColor.black.cgColor
        thumbView.layer?.shadowOpacity = 0.18
        thumbView.layer?.shadowRadius = 10
        thumbView.layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            thumbView.animator().layer?.transform = CATransform3DIdentity
        }
        cardView.isHovered = false
        previewWell.isHovered = false
        thumbView.layer?.shadowOpacity = 0
    }

    // MARK: Context Menu

    override func rightMouseDown(with event: NSEvent) {
        guard historyItem != nil else { return }
        ShotnixContextMenu.show(
            sections: [
                ShotnixMenuSection(id: "history.capture", title: "Capture", actions: [
                    ShotnixMenuAction(id: "history.copy", title: "Copy", symbolName: "doc.on.doc", role: .primary) { [weak self] in self?.copyImage() },
                    ShotnixMenuAction(id: "history.edit", title: "Edit", symbolName: "pencil") { [weak self] in self?.editImage() },
                    ShotnixMenuAction(id: "history.save", title: "Save As", symbolName: "square.and.arrow.down") { [weak self] in self?.saveImage() },
                    ShotnixMenuAction(id: "history.pin", title: "Pin to Screen", symbolName: "pin") { [weak self] in self?.pinImage() },
                ]),
                ShotnixMenuSection(id: "history.manage", title: "Manage", actions: [
                    ShotnixMenuAction(id: "history.delete", title: "Delete", symbolName: "trash", role: .destructive) { [weak self] in self?.deleteItem() },
                ])
            ],
            at: event,
            in: view
        )
    }

    // MARK: Actions

    @objc private func copyImage() {
        guard let item = historyItem else { return }
        ImageExporter.copyToClipboard(image: item.fullImage)
    }

    @objc private func editImage() {
        guard let item = historyItem, let manager = historyManager else { return }
        AnnotationWindowController.open(image: item.fullImage, historyItem: item, historyManager: manager)
    }

    @objc private func saveImage() {
        guard let item = historyItem else { return }
        ImageExporter.saveWithPanel(image: item.fullImage, suggestedName: ImageExporter.timestampedName)
    }

    @objc private func pinImage() {
        guard let item = historyItem else { return }
        PinnedWindow.pin(image: item.fullImage)
    }

    @objc private func deleteItem() {
        guard let item = historyItem, let manager = historyManager else { return }
        manager.delete(item)
        HistoryPanelController.shared.reloadAfterDelete()
    }
}

// MARK: - Section Header

@MainActor
final class HistorySectionHeader: NSView, NSCollectionViewElement {

    static let identifier = NSUserInterfaceItemIdentifier("HistorySectionHeader")

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.58)
        label.frame = NSRect(x: 26, y: 7, width: 300, height: 18)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        label.stringValue = title.uppercased()
    }
}

@MainActor
private final class HistoryStageView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [ShotnixColors.editorStageTop.cgColor, ShotnixColors.editorStageBottom.cgColor] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        } else {
            ShotnixColors.editorStageTop.setFill()
            rect.fill()
        }

        drawGlow(in: context, color: NSColor.controlAccentColor.withAlphaComponent(0.14), center: CGPoint(x: rect.maxX * 0.78, y: rect.maxY + 12), radius: max(rect.width, rect.height) * 0.42)
        drawGlow(in: context, color: NSColor.systemPurple.withAlphaComponent(0.12), center: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY - 10), radius: max(rect.width, rect.height) * 0.38)
    }

    private func drawGlow(in context: CGContext, color: NSColor, center: CGPoint, radius: CGFloat) {
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        let colorSpace = color.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
    }
}

@MainActor
private final class HistoryPreviewWellView: NSView {
    var isHovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.allowsEdgeAntialiasing = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(isHovered ? 0.20 : 0.15).cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(isHovered ? 0.08 : 0.045).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}

@MainActor
private final class HistoryCaptureCardView: NSView {
    var isHovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.allowsEdgeAntialiasing = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(NSColor(calibratedWhite: 0.045, alpha: isHovered ? 0.94 : 0.86).cgColor)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(isHovered ? 0.12 : 0.06).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}

@MainActor
private final class HistoryEmptyStateCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -14)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
        NSColor.black.withAlphaComponent(0.26).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class HistoryActionButton: NSButton {
    enum Variant { case primary, secondary, destructive }

    private let variant: Variant
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, variant: Variant, target: AnyObject?, action: Selector?) {
        self.variant = variant
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateBackground(hoverColor)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateBackground(baseColor)
    }

    override func mouseDown(with event: NSEvent) {
        animateBackground(pressedColor)
        layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        animateBackground(isHovered ? hoverColor : baseColor)
        layer?.transform = CATransform3DIdentity
        super.mouseUp(with: event)
    }

    private func configure() {
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = .systemFont(ofSize: 12, weight: .semibold)
        contentTintColor = textColor
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = baseColor
        layer?.borderWidth = 1
        layer?.borderColor = borderColor
    }

    private var baseColor: CGColor {
        switch variant {
        case .primary: return NSColor.white.withAlphaComponent(0.92).cgColor
        case .secondary: return ShotnixColors.editorActionBackground.cgColor
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.18).cgColor
        }
    }

    private var hoverColor: CGColor {
        switch variant {
        case .primary: return NSColor.white.cgColor
        case .secondary: return ShotnixColors.cornerButtonHover.cgColor
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.27).cgColor
        }
    }

    private var pressedColor: CGColor {
        switch variant {
        case .primary: return NSColor.white.withAlphaComponent(0.74).cgColor
        case .secondary: return ShotnixColors.cornerButtonPressed.cgColor
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.36).cgColor
        }
    }

    private var borderColor: CGColor {
        switch variant {
        case .primary: return NSColor.white.withAlphaComponent(0.28).cgColor
        case .secondary: return ShotnixColors.editorDockBorder.cgColor
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.38).cgColor
        }
    }

    private var textColor: NSColor {
        switch variant {
        case .primary: return NSColor.black.withAlphaComponent(0.88)
        case .secondary: return NSColor.white.withAlphaComponent(0.84)
        case .destructive: return NSColor.systemRed
        }
    }

    private func animateBackground(_ color: CGColor) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            self.layer?.backgroundColor = color
        }
    }
}
