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
        NSApp.setActivationPolicy(.accessory)
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

        // Cap window to 85% of screen so large screenshots don't go off-screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85 - toolbarHeight
        let winW = min(canvasSize.width, maxW)
        let winH = min(canvasSize.height, maxH) + toolbarHeight
        let windowSize = NSSize(width: winW, height: winH)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Shotnix — Annotate"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 320, height: 240 + toolbarHeight)
        win.center()

        super.init(window: win)

        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: canvasSize)

        // Scroll view for canvas — clips content properly
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - toolbarHeight))
        // Center canvas when viewport is larger than the image (eliminates blank side areas)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none

        // Toolbar positioned at top of window
        toolbar.frame = NSRect(x: 0, y: winH - toolbarHeight, width: winW, height: toolbarHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]

        toolbar.onToolChanged     = { [weak self] tool in
            self?.canvas.activeTool = tool
            // Clear crop state when switching away from crop tool
            if tool != .crop {
                self?.canvas.cropRect = nil
                self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
                self?.toolbar.setCropApplyVisible(false)
            }
        }
        toolbar.onColorChanged    = { [weak self] color in self?.canvas.activeColor = color }
        toolbar.onLineWidthChanged = { [weak self] w   in self?.canvas.activeLineWidth = w }
        toolbar.onSave            = { [weak self] in self?.save() }
        toolbar.onCopy            = { [weak self] in self?.copyToClipboard() }
        toolbar.onApplyCrop       = { [weak self] in self?.applyCrop() }

        // Show Crop✓ button only when a crop region is drawn
        canvas.onCropChanged = { [weak self] rect in
            let hasCrop = rect != nil && !(rect?.isEmpty ?? true)
            self?.toolbar.setCropApplyVisible(hasCrop)
        }

        // Build hierarchy FIRST, then configure layers (layers don't exist until views are in a window)
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.addSubview(scrollView)
        container.addSubview(toolbar)
        win.contentView = container
        win.delegate = self

        // NOW layers exist — set masksToBounds on the clip view (the actual clipping mechanism)
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true

        win.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Actions

    private func save() {
        canvas.commitTextField()
        let flat = canvas.flatten()
        ImageExporter.saveWithPanel(image: flat, suggestedName: ImageExporter.timestampedName)
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
        if AnnotationWindowController.openControllers.isEmpty {
            NSApp.setActivationPolicy(.prohibited)
        }
    }
}

// MARK: – Centering Clip View

/// Centers the document view when the scroll view viewport is larger than the content.
@MainActor
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }
        let docFrame = documentView.frame
        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: – Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onApplyCrop: (() -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var selectedTool: AnnotationTool = .arrow
    private let colorWell = NSColorWell()
    private var cropApplyButton: NSButton?

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

        // Always-visible action buttons
        for (title, sel) in [("Copy", #selector(copyTapped)), ("Save", #selector(saveTapped))] {
            let btn = NSButton(title: title, target: self, action: sel)
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.frame = NSRect(x: x, y: 11, width: 50, height: 28)
            addSubview(btn); x += 54
        }

        // Crop apply button (only visible when a crop region is drawn)
        let cropBtn = NSButton(title: "Crop✓", target: self, action: #selector(cropTapped))
        cropBtn.bezelStyle = .rounded
        cropBtn.font = .systemFont(ofSize: 11)
        cropBtn.frame = NSRect(x: x, y: 11, width: 60, height: 28)
        cropBtn.isHidden = true
        addSubview(cropBtn)
        cropApplyButton = cropBtn

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

    func setCropApplyVisible(_ visible: Bool) {
        cropApplyButton?.isHidden = !visible
    }

    @objc private func colorChanged()     { onColorChanged?(colorWell.color) }
    @objc private func lineWidthChanged(_ sender: NSSlider) { onLineWidthChanged?(CGFloat(sender.doubleValue)) }
    @objc private func cropTapped()       { onApplyCrop?() }
    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
}
