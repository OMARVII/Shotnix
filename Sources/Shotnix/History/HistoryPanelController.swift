import AppKit

/// Floating panel showing all past captures as a scrollable grid.
@MainActor
final class HistoryPanelController: NSObject {

    static let shared = HistoryPanelController()

    private var panel: NSPanel?
    private weak var historyManager: HistoryManager?

    func show(historyManager: HistoryManager) {
        self.historyManager = historyManager
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            reload()
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
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    private func buildContent(historyManager: HistoryManager) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 480))

        // Toolbar
        let clearBtn = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: 8, y: 448, width: 80, height: 24)
        container.addSubview(clearBtn)

        let label = NSTextField(labelWithString: "Capture History")
        label.font = .boldSystemFont(ofSize: 13)
        label.frame = NSRect(x: 100, y: 450, width: 400, height: 20)
        label.alignment = .center
        container.addSubview(label)

        // Grid scroll view
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let grid = buildGrid(historyManager: historyManager)
        scroll.documentView = grid
        container.addSubview(scroll)

        return container
    }

    private func buildGrid(historyManager: HistoryManager) -> NSView {
        let cols = 3
        let thumbSize: CGFloat = 180
        let padding: CGFloat = 12
        let items = historyManager.items
        let rows = max(1, Int(ceil(Double(items.count) / Double(cols))))
        let totalH = CGFloat(rows) * (thumbSize + 40 + padding) + padding

        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: totalH))

        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = padding + CGFloat(col) * (thumbSize + padding)
            // In NSScrollView, y=0 is bottom; we want newest (index 0) at top
            let y = totalH - (CGFloat(row + 1) * (thumbSize + 40 + padding))

            let cell = HistoryCell(item: item, size: thumbSize, historyManager: historyManager)
            cell.frame = NSRect(x: x, y: y, width: thumbSize, height: thumbSize + 40)
            grid.addSubview(cell)
        }

        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No captures yet")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: 0, y: totalH/2 - 12, width: 600, height: 24)
            grid.addSubview(empty)
        }

        return grid
    }

    private func reload() {
        guard let panel, let manager = historyManager else { return }
        panel.contentView = buildContent(historyManager: manager)
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

// MARK: – History Cell

@MainActor
private final class HistoryCell: NSView {

    private let item: HistoryItem
    private let historyManager: HistoryManager

    init(item: HistoryItem, size: CGFloat, historyManager: HistoryManager) {
        self.item = item
        self.historyManager = historyManager
        super.init(frame: .zero)

        let thumb = NSImageView(frame: NSRect(x: 0, y: 40, width: size, height: size))
        thumb.image = item.thumbnail
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(thumb)

        let dateStr = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let label = NSTextField(labelWithString: dateStr)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 20, width: size, height: 16)
        addSubview(label)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copyBtn.bezelStyle = .rounded
        copyBtn.font = .systemFont(ofSize: 10)
        copyBtn.frame = NSRect(x: 0, y: 0, width: size/2 - 2, height: 18)
        addSubview(copyBtn)

        let editBtn = NSButton(title: "Edit", target: self, action: #selector(editImage))
        editBtn.bezelStyle = .rounded
        editBtn.font = .systemFont(ofSize: 10)
        editBtn.frame = NSRect(x: size/2 + 2, y: 0, width: size/2 - 2, height: 18)
        addSubview(editBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyImage() { ImageExporter.copyToClipboard(image: item.fullImage) }
    @objc private func editImage() {
        AnnotationWindowController.open(image: item.fullImage, historyItem: item, historyManager: historyManager)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy",         action: #selector(copyImage),  keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit",         action: #selector(editImage),  keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Save As…",     action: #selector(saveImage),  keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pin to Screen",action: #selector(pinImage),   keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete",       action: #selector(deleteItem), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func saveImage() {
        ImageExporter.saveWithPanel(image: item.fullImage, suggestedName: "screenshot")
    }
    @objc private func pinImage() { PinnedWindow.pin(image: item.fullImage) }
    @objc private func deleteItem() {
        historyManager.delete(item)
        removeFromSuperview()
    }
}
