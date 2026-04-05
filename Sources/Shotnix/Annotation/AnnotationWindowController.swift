import AppKit

/// Manages the full annotation editor window.
@MainActor
final class AnnotationWindowController: NSWindowController {

    private let canvas: AnnotationCanvas
    private let toolbar: AnnotationToolbar
    private let historyItem: HistoryItem?
    private let historyManager: HistoryManager?
    private var image: NSImage

    // Strong references so controllers aren't deallocated while their window is open
    private static var openControllers: [AnnotationWindowController] = []

    static func open(image: NSImage, historyItem: HistoryItem? = nil, historyManager: HistoryManager? = nil) {
        let controller = AnnotationWindowController(image: image, historyItem: historyItem, historyManager: historyManager)
        openControllers.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(image: NSImage, historyItem: HistoryItem?, historyManager: HistoryManager?) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager
        self.canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        self.toolbar = AnnotationToolbar()

        let canvasSize = image.size
        let toolbarHeight: CGFloat = 52
        let windowSize = NSSize(width: canvasSize.width, height: canvasSize.height + toolbarHeight)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Shotnix — Annotate"
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)

        canvas.backgroundImage = image
        canvas.frame = NSRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        toolbar.frame = NSRect(x: 0, y: canvasSize.height, width: canvasSize.width, height: toolbarHeight)

        toolbar.onToolChanged     = { [weak self] tool  in self?.canvas.activeTool = tool }
        toolbar.onColorChanged    = { [weak self] color in self?.canvas.activeColor = color }
        toolbar.onLineWidthChanged = { [weak self] w   in self?.canvas.activeLineWidth = w }
        toolbar.onUndo            = { [weak self] in self?.canvas.performUndo() }
        toolbar.onRedo            = { [weak self] in self?.canvas.performRedo() }
        toolbar.onSave            = { [weak self] in self?.save() }
        toolbar.onCopy            = { [weak self] in self?.copyToClipboard() }
        toolbar.onDelete          = { [weak self] in self?.canvas.deleteSelected() }
        toolbar.onApplyCrop       = { [weak self] in self?.applyCrop() }

        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.addSubview(canvas)
        container.addSubview(toolbar)
        win.contentView = container
        win.delegate = self
        win.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Actions

    private func save() {
        canvas.commitTextField()
        let flat = canvas.flatten()
        ImageExporter.saveWithPanel(image: flat, suggestedName: "screenshot")
    }

    private func copyToClipboard() {
        canvas.commitTextField()
        let flat = canvas.flatten()
        ImageExporter.copyToClipboard(image: flat)
        showBrieflyCopiedBanner()
    }

    private func applyCrop() {
        if let cropped = canvas.applyCrop() {
            canvas.backgroundImage = cropped
            canvas.frame = NSRect(origin: .zero, size: cropped.size)
            canvas.objects.removeAll()
            canvas.setNeedsDisplay(canvas.bounds)
        }
    }

    private func showBrieflyCopiedBanner() {
        guard let win = window else { return }
        let banner = NSTextField(labelWithString: "✓ Copied to clipboard")
        banner.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        banner.textColor = .white
        banner.isBezeled = false
        banner.drawsBackground = true
        banner.alignment = .center
        guard let contentView = win.contentView else { return }
        banner.frame = NSRect(x: contentView.bounds.midX - 100, y: 60, width: 200, height: 28)
        contentView.addSubview(banner)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { banner.removeFromSuperview() }
    }
}

extension AnnotationWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AnnotationWindowController.openControllers.removeAll { $0 === self }
    }
}

// MARK: – Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onApplyCrop: (() -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var selectedTool: AnnotationTool = .arrow
    private let colorWell = NSColorWell()

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        var x: CGFloat = 8

        // Tool buttons
        let tools: [AnnotationTool] = [.select, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .freehand, .text, .highlighter, .blur, .pixelate, .crop]
        for tool in tools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        // Separator
        x += 8
        let sep = NSBox(); sep.boxType = .separator
        sep.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep); x += 12

        // Color well
        colorWell.frame = NSRect(x: x, y: 10, width: 30, height: 30)
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        addSubview(colorWell); x += 40

        // Line width
        let widthLabel = NSTextField(labelWithString: "Size:")
        widthLabel.frame = NSRect(x: x, y: 18, width: 35, height: 16)
        widthLabel.font = .systemFont(ofSize: 11)
        addSubview(widthLabel); x += 38
        let slider = NSSlider(value: 3, minValue: 1, maxValue: 20, target: self, action: #selector(lineWidthChanged))
        slider.frame = NSRect(x: x, y: 12, width: 80, height: 28)
        addSubview(slider); x += 88

        // Separator
        x += 8
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep2); x += 12

        // Action buttons
        for (title, sel) in [("↩ Undo", #selector(undoTapped)), ("↪ Redo", #selector(redoTapped)),
                              ("⌫ Del", #selector(deleteTapped)), ("Crop✓", #selector(cropTapped)),
                              ("Copy", #selector(copyTapped)), ("Save", #selector(saveTapped))] {
            let btn = NSButton(title: title, target: self, action: sel)
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            let w: CGFloat = title.count > 5 ? 60 : 50
            btn.frame = NSRect(x: x, y: 11, width: w, height: 28)
            addSubview(btn); x += w + 4
        }

        selectTool(.arrow)
    }

    private func makeToolButton(tool: AnnotationTool) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: tool.tooltip)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.toolTip = tool.tooltip
        btn.target = self
        btn.action = #selector(toolTapped(_:))
        btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
        return btn
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        selectTool(tool)
        onToolChanged?(tool)
    }

    private func selectTool(_ tool: AnnotationTool) {
        toolButtons[selectedTool]?.layer?.backgroundColor = nil
        selectedTool = tool
        toolButtons[tool]?.wantsLayer = true
        toolButtons[tool]?.layer?.backgroundColor = NSColor.selectedControlColor.cgColor
        toolButtons[tool]?.layer?.cornerRadius = 6
    }

    @objc private func colorChanged()     { onColorChanged?(colorWell.color) }
    @objc private func lineWidthChanged(_ sender: NSSlider) { onLineWidthChanged?(CGFloat(sender.doubleValue)) }
    @objc private func undoTapped()       { onUndo?() }
    @objc private func redoTapped()       { onRedo?() }
    @objc private func deleteTapped()     { onDelete?() }
    @objc private func cropTapped()       { onApplyCrop?() }
    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
}
