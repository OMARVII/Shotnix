import AppKit

/// Floating panel showing all past captures in a grouped NSCollectionView.
@MainActor
final class HistoryPanelController: NSObject {

    static let shared = HistoryPanelController()

    private var panel: NSPanel?
    private weak var historyManager: HistoryManager?
    private var collectionView: NSCollectionView?
    private var emptyOverlay: NSView?
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Shotnix — Capture History"
        p.isFloatingPanel = true
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 480))

        // Toolbar
        let toolbar = NSView(frame: NSRect(x: 0, y: 448, width: 600, height: 32))
        toolbar.autoresizingMask = [.width, .minYMargin]

        let clearBtn = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: 8, y: 4, width: 80, height: 24)
        toolbar.addSubview(clearBtn)

        let label = NSTextField(labelWithString: "Capture History")
        label.font = .boldSystemFont(ofSize: 13)
        label.frame = NSRect(x: 100, y: 6, width: 400, height: 20)
        label.alignment = .center
        toolbar.addSubview(label)
        container.addSubview(toolbar)

        // Collection view
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 220)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.headerReferenceSize = NSSize(width: 600, height: 32)

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
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 448))
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)

        collectionView = cv

        // Empty state overlay
        let empty = buildEmptyOverlay(frame: scroll.frame)
        empty.autoresizingMask = [.width, .height]
        container.addSubview(empty)
        emptyOverlay = empty

        buildSections()
        updateEmptyState()

        return container
    }

    private func buildEmptyOverlay(frame: NSRect) -> NSView {
        let overlay = NSView(frame: frame)

        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))

        let icon = NSImageView(frame: NSRect(x: 100, y: 52, width: 60, height: 48))
        if let symbolImg = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
            icon.image = symbolImg.withSymbolConfiguration(config)
        }
        icon.contentTintColor = .tertiaryLabelColor
        stack.addSubview(icon)

        let title = NSTextField(labelWithString: "No captures yet")
        title.font = .boldSystemFont(ofSize: 16)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 24, width: 260, height: 22)
        stack.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Press \u{2318}\u{21E7}4 to take your first screenshot")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: 0, width: 260, height: 18)
        stack.addSubview(subtitle)

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
        NSApp.setActivationPolicy(.prohibited)
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
        let url = URL(fileURLWithPath: item.imagePath) as NSURL
        return url
    }
}

// MARK: - Collection View Item

@MainActor
final class HistoryCollectionItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("HistoryCollectionItem")

    private var historyItem: HistoryItem?
    private weak var historyManager: HistoryManager?
    private var trackingArea: NSTrackingArea?
    private let thumbView = NSImageView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let copyBtn = NSButton(title: "Copy", target: nil, action: nil)
    private let editBtn = NSButton(title: "Edit", target: nil, action: nil)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 220))

        thumbView.frame = NSRect(x: 0, y: 40, width: 180, height: 180)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 8
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 1
        thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(thumbView)

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .center
        dateLabel.frame = NSRect(x: 0, y: 20, width: 180, height: 16)
        container.addSubview(dateLabel)

        copyBtn.bezelStyle = .rounded
        copyBtn.font = .systemFont(ofSize: 10)
        copyBtn.frame = NSRect(x: 0, y: 0, width: 86, height: 18)
        copyBtn.target = self
        copyBtn.action = #selector(copyImage)
        container.addSubview(copyBtn)

        editBtn.bezelStyle = .rounded
        editBtn.font = .systemFont(ofSize: 10)
        editBtn.frame = NSRect(x: 92, y: 0, width: 88, height: 18)
        editBtn.target = self
        editBtn.action = #selector(editImage)
        container.addSubview(editBtn)

        self.view = container
    }

    func configure(with item: HistoryItem, historyManager: HistoryManager) {
        self.historyItem = item
        self.historyManager = historyManager
        thumbView.image = historyManager.cachedThumbnail(for: item) ?? item.thumbnail
        dateLabel.stringValue = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        setupTracking()
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
            ctx.duration = 0.15
            thumbView.animator().layer?.transform = CATransform3DMakeScale(1.03, 1.03, 1)
        }
        thumbView.layer?.shadowColor = NSColor.black.cgColor
        thumbView.layer?.shadowOpacity = 0.2
        thumbView.layer?.shadowRadius = 8
        thumbView.layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            thumbView.animator().layer?.transform = CATransform3DIdentity
        }
        thumbView.layer?.shadowOpacity = 0
    }

    // MARK: Context Menu

    override func rightMouseDown(with event: NSEvent) {
        guard historyItem != nil else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit", action: #selector(editImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Save As\u{2026}", action: #selector(saveImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pin to Screen", action: #selector(pinImage), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteItem), keyEquivalent: ""))
        for menuItem in menu.items { menuItem.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 4, width: 300, height: 20)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        label.stringValue = title
    }
}
