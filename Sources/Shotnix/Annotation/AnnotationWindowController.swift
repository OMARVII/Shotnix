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
        if let win = controller.window {
            win.alphaValue = 0
            win.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
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
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
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
        scrollView.backgroundColor = ShotnixColors.canvasBackground
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

        // Sync tool changes from canvas keyboard shortcuts back to toolbar
        canvas.onToolChanged = { [weak self] tool in
            self?.toolbar.selectToolExternally(tool)
            if tool != .crop {
                self?.canvas.cropRect = nil
                self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
                self?.toolbar.setCropApplyVisible(false)
            }
        }

        // Show Crop check button only when a crop region is drawn
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !canvas.objects.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Annotations"
        alert.informativeText = "You have annotations that haven't been saved. Close without saving?"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

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
    private var colorButton: NSButton?
    private var colorPopover: NSPopover?
    private var cropApplyButton: NSButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        wantsLayer = true

        // Frosted glass background
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .titlebar
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        // Bottom separator line
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        bottomLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        bottomLine.autoresizingMask = [.width]
        addSubview(bottomLine)

        var x: CGFloat = 8

        // Drawing tools group
        let drawingTools: [AnnotationTool] = [.select, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .freehand]
        for tool in drawingTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        // Separator between groups
        x += 4
        let sep1 = NSBox(); sep1.boxType = .separator
        sep1.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep1); x += 8

        // Annotation tools group
        let annotationTools: [AnnotationTool] = [.text, .numberedStep, .highlighter]
        for tool in annotationTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        // Separator
        x += 4
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep2); x += 8

        // Effect tools group
        let effectTools: [AnnotationTool] = [.blur, .pixelate, .crop]
        for tool in effectTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        // Separator
        x += 4
        let sep3 = NSBox(); sep3.boxType = .separator
        sep3.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep3); x += 8

        // Color button (circular, shows current color)
        let colorBtn = NSButton(frame: NSRect(x: x, y: 10, width: 30, height: 30))
        colorBtn.wantsLayer = true
        colorBtn.layer?.cornerRadius = 15
        colorBtn.layer?.backgroundColor = NSColor.systemRed.cgColor
        colorBtn.layer?.borderWidth = 2
        colorBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        colorBtn.isBordered = false
        colorBtn.bezelStyle = .regularSquare
        colorBtn.target = self
        colorBtn.action = #selector(showColorPopover(_:))
        colorBtn.toolTip = "Color"
        addSubview(colorBtn)
        colorButton = colorBtn
        x += 40

        // Line width
        let widthLabel = NSTextField(labelWithString: "Size:")
        widthLabel.frame = NSRect(x: x, y: 18, width: 35, height: 16)
        widthLabel.font = .systemFont(ofSize: 11)
        addSubview(widthLabel); x += 38
        let slider = NSSlider(value: 3, minValue: 1, maxValue: 20, target: self, action: #selector(lineWidthChanged))
        slider.frame = NSRect(x: x, y: 12, width: 80, height: 28)
        addSubview(slider); x += 88

        // Separator
        x += 4
        let sep4 = NSBox(); sep4.boxType = .separator
        sep4.frame = NSRect(x: x, y: 6, width: 1, height: 40)
        addSubview(sep4); x += 8

        // Action buttons
        for (title, sel) in [("Copy", #selector(copyTapped)), ("Save", #selector(saveTapped))] {
            let btn = NSButton(title: title, target: self, action: sel)
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.frame = NSRect(x: x, y: 11, width: 50, height: 28)
            addSubview(btn); x += 54
        }

        // Crop apply button (only visible when a crop region is drawn)
        let cropBtn = NSButton(title: "Crop\u{2713}", target: self, action: #selector(cropTapped))
        cropBtn.bezelStyle = .rounded
        cropBtn.font = .systemFont(ofSize: 11)
        cropBtn.frame = NSRect(x: x, y: 11, width: 60, height: 28)
        cropBtn.isHidden = true
        addSubview(cropBtn)
        cropApplyButton = cropBtn

        selectTool(.arrow)
    }

    private func makeToolButton(tool: AnnotationTool) -> NSButton {
        let btn = AnnotationToolButton(frame: .zero)
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
        if let oldBtn = toolButtons[selectedTool] as? AnnotationToolButton {
            oldBtn.isSelectedTool = false
        }
        toolButtons[selectedTool]?.layer?.backgroundColor = nil
        selectedTool = tool
        toolButtons[tool]?.wantsLayer = true
        toolButtons[tool]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        toolButtons[tool]?.layer?.cornerRadius = 6
        if let newBtn = toolButtons[tool] as? AnnotationToolButton {
            newBtn.isSelectedTool = true
        }
    }

    func setCropApplyVisible(_ visible: Bool) {
        cropApplyButton?.isHidden = !visible
    }

    func selectToolExternally(_ tool: AnnotationTool) {
        selectTool(tool)
    }

    @objc private func showColorPopover(_ sender: NSButton) {
        let controller = ColorPopoverController()
        controller.onColorPicked = { [weak self] color in
            self?.onColorChanged?(color)
            sender.layer?.backgroundColor = color.cgColor
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        colorPopover = popover
    }

    @objc private func lineWidthChanged(_ sender: NSSlider) { onLineWidthChanged?(CGFloat(sender.doubleValue)) }
    @objc private func cropTapped()       { onApplyCrop?() }
    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
}

// MARK: – Annotation tool button with hover + press feedback

@MainActor
private final class AnnotationToolButton: NSButton {

    var isSelectedTool = false
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        guard !isSelectedTool else { return }
        wantsLayer = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        guard !isSelectedTool else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.layer?.backgroundColor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let scale = CATransform3DMakeScale(0.92, 0.92, 1)
        layer?.transform = scale
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.92
        spring.toValue = 1.0
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 15
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "bounceBack")
        layer?.transform = CATransform3DIdentity
        super.mouseUp(with: event)
    }
}

// MARK: - Color Presets Popover

@MainActor
final class ColorPopoverController: NSViewController {
    var onColorPicked: ((NSColor) -> Void)?
    private var currentColor: NSColor = .systemRed

    private let presets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    override func loadView() {
        let width: CGFloat = 160
        let btnSize: CGFloat = 28
        let gap: CGFloat = 8
        let padding: CGFloat = 12
        let rows = 2
        let cols = 4
        let gridH = CGFloat(rows) * btnSize + CGFloat(rows - 1) * gap
        let height = padding * 2 + gridH + 8 + 24

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var y = height - padding
        for row in 0..<rows {
            y -= btnSize
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < presets.count else { break }
                let x = padding + CGFloat(col) * (btnSize + gap)
                let btn = NSButton(frame: NSRect(x: x, y: y, width: btnSize, height: btnSize))
                btn.wantsLayer = true
                btn.layer?.cornerRadius = btnSize / 2
                btn.layer?.backgroundColor = presets[idx].cgColor
                btn.layer?.borderWidth = presets[idx] == .white ? 1 : 0
                btn.layer?.borderColor = NSColor.separatorColor.cgColor
                btn.isBordered = false
                btn.bezelStyle = .regularSquare
                btn.tag = idx
                btn.target = self
                btn.action = #selector(presetTapped(_:))
                container.addSubview(btn)
            }
            y -= gap
        }

        y -= 2
        let customBtn = NSButton(title: "Custom\u{2026}", target: self, action: #selector(customTapped))
        customBtn.bezelStyle = .inline
        customBtn.font = .systemFont(ofSize: 11)
        customBtn.frame = NSRect(x: padding, y: y - 20, width: width - padding * 2, height: 20)
        container.addSubview(customBtn)

        self.view = container
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let color = presets[sender.tag]
        currentColor = color
        onColorPicked?(color)
        dismiss(nil)
    }

    @objc private func customTapped() {
        dismiss(nil)
        let panel = NSColorPanel.shared
        panel.color = currentColor
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        currentColor = sender.color
        onColorPicked?(sender.color)
    }
}
