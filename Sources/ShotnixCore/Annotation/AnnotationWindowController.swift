import AppKit
import UniformTypeIdentifiers

/// Manages the full annotation editor window.
@MainActor
final class AnnotationWindowController: NSWindowController {

    private static let trafficLightReservedWidth: CGFloat = 92
    private static let minimumEditorWidth = trafficLightReservedWidth + AnnotationToolbar.requiredWidth + 20
    private static let initialScreenWidthFraction: CGFloat = 0.96
    private static let initialScreenHeightFraction: CGFloat = 0.92
    private static let initialScreenEdgeInset: CGFloat = 24

    private let canvas: AnnotationCanvas
    private let toolbar: AnnotationToolbar
    private let historyItem: HistoryItem?
    private let historyManager: HistoryManager?
    private var image: NSImage
    private var backgroundOptions = ScreenshotBackgroundOptions.editorDefault

    // Strong references so controllers aren't deallocated while their window is open
    private static var openControllers: [AnnotationWindowController] = []

    static var hasOpenEditors: Bool {
        !openControllers.isEmpty
    }

    static func bringOpenEditorsToFront() {
        guard hasOpenEditors else { return }
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        for controller in openControllers {
            controller.bringEditorToFront()
        }
    }

    static func open(image: NSImage, historyItem: HistoryItem? = nil, historyManager: HistoryManager? = nil) {
        let controller = AnnotationWindowController(image: image, historyItem: historyItem, historyManager: historyManager)
        openControllers.append(controller)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if let win = controller.window {
            win.alphaValue = 0
            controller.bringEditorToFront()
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
        let toolbarHeight: CGFloat = 76
        let toolbarDockHeight: CGFloat = 56
        let stageInset: CGFloat = 18

        // Open as large as the visible display safely allows so the image starts with less scrolling.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minimumEditorHeight = 260 + toolbarHeight
        let screenSafeWidth = max(1, screenFrame.width - Self.initialScreenEdgeInset * 2)
        let screenSafeHeight = max(1, screenFrame.height - Self.initialScreenEdgeInset * 2)
        let maxWindowWidth = min(screenSafeWidth, screenFrame.width * Self.initialScreenWidthFraction)
        let maxWindowHeight = min(screenSafeHeight, screenFrame.height * Self.initialScreenHeightFraction)
        let effectiveMinimumWidth = min(Self.minimumEditorWidth, maxWindowWidth)
        let effectiveMinimumHeight = min(minimumEditorHeight, maxWindowHeight)
        let desiredWindowWidth = canvasSize.width + stageInset * 2
        let desiredWindowHeight = canvasSize.height + toolbarHeight + stageInset
        let winW = max(min(desiredWindowWidth, maxWindowWidth), effectiveMinimumWidth)
        let winH = max(min(desiredWindowHeight, maxWindowHeight), effectiveMinimumHeight)
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
        win.level = .floating
        win.minSize = NSSize(width: effectiveMinimumWidth, height: effectiveMinimumHeight)
        win.center()

        super.init(window: win)

        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: canvasSize)

        // Scroll view for canvas — clips content properly
        let scrollView = NSScrollView(frame: NSRect(
            x: stageInset,
            y: stageInset,
            width: winW - stageInset * 2,
            height: winH - toolbarHeight - stageInset
        ))
        // Center canvas when viewport is larger than the image (eliminates blank side areas)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.autoresizingMask = [.width, .height]
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 18
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = ShotnixColors.editorChromeBorder.cgColor
        scrollView.layer?.shadowColor = NSColor.black.cgColor
        scrollView.layer?.shadowOpacity = 0.24
        scrollView.layer?.shadowRadius = 32
        scrollView.layer?.shadowOffset = CGSize(width: 0, height: -18)

        // Floating toolbar dock positioned at top of window
        let toolbarWidth = min(AnnotationToolbar.requiredWidth, max(0, winW - Self.trafficLightReservedWidth - stageInset))
        let toolbarX = max(Self.trafficLightReservedWidth, round((winW - toolbarWidth) / 2))
        toolbar.frame = NSRect(
            x: toolbarX,
            y: winH - toolbarDockHeight - 10,
            width: toolbarWidth,
            height: toolbarDockHeight
        )
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        toolbar.onToolChanged     = { [weak self] tool in
            self?.canvas.activeTool = tool
            // Clear crop state when switching away from crop tool
            if tool != .crop {
                self?.canvas.cropRect = nil
                self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
                self?.toolbar.setCropApplyVisible(false)
            }
        }
        toolbar.onColorChanged    = { [weak self] color in self?.canvas.setActiveColor(color) }
        toolbar.onLineWidthChanged = { [weak self] w   in self?.canvas.setActiveLineWidth(w) }
        toolbar.onSave            = { [weak self] in self?.save() }
        toolbar.onCopy            = { [weak self] in self?.copyToClipboard() }
        toolbar.onApplyCrop       = { [weak self] in self?.applyCrop() }
        toolbar.onBackgroundOptionsChanged = { [weak self] options in self?.applyBackgroundOptions(options) }

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
        let container = PremiumEditorStageView(frame: NSRect(origin: .zero, size: windowSize))
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

    private func bringEditorToFront() {
        guard let window else { return }
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.level = .floating
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
    }

    // MARK: – Actions

    private func save() {
        canvas.commitTextField()
        let flat = exportImage()
        ImageExporter.saveWithPanel(image: flat, suggestedName: ImageExporter.timestampedName, presentingWindow: window) { [weak self] result in
            self?.bringEditorToFront()
            guard case .saved(let url) = result else { return }
            ToastWindow.show(message: Self.savedScreenshotMessage(for: url), duration: 3.0)
        }
    }

    private func copyToClipboard() {
        canvas.commitTextField()
        let flat = exportImage()
        ImageExporter.copyToClipboard(image: flat)
        ToastWindow.show(message: "Copied to clipboard")
    }

    private func exportImage() -> NSImage {
        canvas.flatten()
    }

    private func applyBackgroundOptions(_ options: ScreenshotBackgroundOptions) {
        canvas.commitTextField()

        let oldPadding = previewPadding(for: backgroundOptions)
        let newPadding = previewPadding(for: options)
        backgroundOptions = options

        canvas.backgroundOptions = options
        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: previewSize(for: options))
        canvas.offsetContent(by: CGPoint(x: newPadding - oldPadding, y: newPadding - oldPadding))
        canvas.setNeedsDisplay(canvas.bounds)
    }

    private func previewSize(for options: ScreenshotBackgroundOptions) -> NSSize {
        let padding = previewPadding(for: options)
        return NSSize(width: image.size.width + padding * 2, height: image.size.height + padding * 2)
    }

    private func previewPadding(for options: ScreenshotBackgroundOptions) -> CGFloat {
        guard options.isEnabled else { return 0 }
        return min(max(options.padding, 0), 240)
    }

    private func applyCrop() {
        if let cropped = canvas.applyCrop() {
            image = cropped
            backgroundOptions = .editorDefault
            toolbar.setBackgroundOptionsExternally(backgroundOptions)
            canvas.backgroundOptions = backgroundOptions
            canvas.backgroundImage = cropped
            canvas.frame = NSRect(origin: .zero, size: cropped.size)
            canvas.objects.removeAll()
            canvas.setNeedsDisplay(canvas.bounds)
        }
    }

    private static func savedScreenshotMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        return "Saved to \(destination): \(url.lastPathComponent)"
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
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
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

@MainActor
private final class PremiumEditorStageView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [ShotnixColors.editorStageTop.cgColor, ShotnixColors.editorStageBottom.cgColor] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        } else {
            ShotnixColors.editorStageTop.setFill()
            rect.fill()
        }

        drawGlow(in: ctx, rect: rect, color: NSColor.controlAccentColor.withAlphaComponent(0.18), center: CGPoint(x: rect.maxX * 0.72, y: rect.minY + 24), radius: max(rect.width, rect.height) * 0.42)
        drawGlow(in: ctx, rect: rect, color: NSColor.systemPurple.withAlphaComponent(0.12), center: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY + 20), radius: max(rect.width, rect.height) * 0.36)
    }

    private func drawGlow(in context: CGContext, rect: CGRect, color: NSColor, center: CGPoint, radius: CGFloat) {
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

// MARK: – Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    static let requiredWidth: CGFloat = 984

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onBackgroundOptionsChanged: ((ScreenshotBackgroundOptions) -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var selectedTool: AnnotationTool = .arrow
    private var colorButton: NSButton?
    private var colorPopover: NSPopover?
    private var cropApplyButton: NSButton?
    private var backgroundButton: NSButton?
    private var backgroundPopover: NSPopover?
    private var backgroundOptions = ScreenshotBackgroundOptions.editorDefault

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -10)

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        addSubview(blur)

        let border = NSView(frame: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.cornerRadius = 18
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1
        border.layer?.borderColor = ShotnixColors.editorDockBorder.cgColor
        addSubview(border)

        var x: CGFloat = 8

        // Drawing tools group
        let drawingTools: [AnnotationTool] = [.select, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .freehand]
        addToolbarGroupBackground(x: x - 3, width: CGFloat(drawingTools.count) * 36 + 2)
        for tool in drawingTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        x += 10

        // Annotation tools group
        let annotationTools: [AnnotationTool] = [.text, .numberedStep, .highlighter]
        addToolbarGroupBackground(x: x - 3, width: CGFloat(annotationTools.count) * 36 + 2)
        for tool in annotationTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        x += 10

        // Effect tools group
        let effectTools: [AnnotationTool] = [.blur, .pixelate, .crop]
        addToolbarGroupBackground(x: x - 3, width: CGFloat(effectTools.count) * 36 + 2)
        for tool in effectTools {
            let btn = makeToolButton(tool: tool)
            btn.frame = NSRect(x: x, y: 8, width: 34, height: 34)
            addSubview(btn)
            toolButtons[tool] = btn
            x += 36
        }

        x += 10

        addToolbarGroupBackground(x: x - 6, width: 168)

        // Color button (circular, shows current color)
        let colorBtn = NSButton(title: "", target: self, action: #selector(showColorPopover(_:)))
        colorBtn.frame = NSRect(x: x, y: 10, width: 30, height: 30)
        colorBtn.title = ""
        colorBtn.alternateTitle = ""
        colorBtn.attributedTitle = NSAttributedString(string: "")
        colorBtn.imagePosition = .noImage
        colorBtn.wantsLayer = true
        colorBtn.layer?.cornerRadius = 15
        colorBtn.layer?.backgroundColor = NSColor.systemRed.cgColor
        colorBtn.layer?.borderWidth = 2
        colorBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        colorBtn.isBordered = false
        colorBtn.bezelStyle = .regularSquare
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

        x += 10

        let backgroundBtn = PremiumToolbarActionButton(title: "Background", target: self, action: #selector(backgroundTapped(_:)))
        backgroundBtn.bezelStyle = .regularSquare
        backgroundBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        backgroundBtn.imagePosition = .noImage
        backgroundBtn.toolTip = "Background"
        backgroundBtn.frame = NSRect(x: x, y: 10, width: 110, height: 30)
        addSubview(backgroundBtn)
        backgroundButton = backgroundBtn
        x += 116

        x += 2

        // Action buttons
        for (title, sel) in [("Copy", #selector(copyTapped)), ("Save", #selector(saveTapped))] {
            let btn = PremiumToolbarActionButton(title: title, target: self, action: sel)
            btn.bezelStyle = .regularSquare
            btn.font = .systemFont(ofSize: 11, weight: title == "Save" ? .semibold : .regular)
            btn.frame = NSRect(x: x, y: 10, width: 54, height: 30)
            addSubview(btn); x += 58
        }

        // Crop apply button (only visible when a crop region is drawn)
        let cropBtn = PremiumToolbarActionButton(title: "Crop\u{2713}", target: self, action: #selector(cropTapped))
        cropBtn.bezelStyle = .regularSquare
        cropBtn.font = .systemFont(ofSize: 11)
        cropBtn.frame = NSRect(x: x, y: 11, width: 60, height: 28)
        cropBtn.isHidden = true
        addSubview(cropBtn)
        cropApplyButton = cropBtn

        selectTool(.arrow)
    }

    private func addToolbarGroupBackground(x: CGFloat, width: CGFloat) {
        let group = NSView(frame: NSRect(x: x, y: 6, width: width, height: 40))
        group.wantsLayer = true
        group.layer?.cornerRadius = 11
        group.layer?.cornerCurve = .continuous
        group.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        group.layer?.borderWidth = 1
        group.layer?.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
        addSubview(group)
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
        toolButtons[tool]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        toolButtons[tool]?.layer?.cornerRadius = 8
        toolButtons[tool]?.layer?.cornerCurve = .continuous
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

    func setBackgroundOptionsExternally(_ options: ScreenshotBackgroundOptions) {
        backgroundOptions = options
        backgroundButton?.contentTintColor = options.isEnabled ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.86)
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
    @objc private func backgroundTapped(_ sender: NSButton) {
        if !backgroundOptions.isEnabled {
            backgroundOptions.isEnabled = true
            backgroundButton?.contentTintColor = .controlAccentColor
            onBackgroundOptionsChanged?(backgroundOptions)
        }

        let controller = BackgroundPopoverController(options: backgroundOptions)
        controller.onChange = { [weak self] options in
            self?.backgroundOptions = options
            self?.backgroundButton?.contentTintColor = options.isEnabled ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.86)
            self?.onBackgroundOptionsChanged?(options)
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        controller.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        backgroundPopover = popover
    }
    @objc private func cropTapped()       { onApplyCrop?() }
    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
}

// MARK: - Per-image background popover

@MainActor
private final class BackgroundPopoverController: NSViewController {
    var onChange: ((ScreenshotBackgroundOptions) -> Void)?
    weak var popover: NSPopover?

    private var options: ScreenshotBackgroundOptions
    private let enabledButton = NSButton(checkboxWithTitle: "Apply background to this image", target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let uploadImageButton = NSButton(title: "Upload Custom Image", target: nil, action: nil)
    private let paddingSlider = NSSlider()
    private let radiusSlider = NSSlider()
    private let shadowSlider = NSSlider()
    private let paddingValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let shadowValue = NSTextField(labelWithString: "")
    private var styleLabel: NSTextField?
    private var presetLabel: NSTextField?
    private var paddingLabel: NSTextField?
    private var radiusLabel: NSTextField?
    private var shadowLabel: NSTextField?
    private var imagePresetButtons: [NSButton] = []
    private let popoverWidth: CGFloat = 300
    private let compactPopoverHeight: CGFloat = 250
    private let imagePopoverHeight: CGFloat = 452

    private let solidPresets: [(String, String)] = [
        ("Porcelain", "#f4eadb"),
        ("Graphite", "#111827"),
        ("Bone", "#eee7d6"),
        ("Silver", "#d8dde7"),
        ("Space Gray", "#2b3038"),
        ("Moss", "#243528"),
        ("Clay", "#7c3f2d")
    ]
    private let gradientPresets: [(name: String, start: String, end: String, accents: [String])] = [
        ("Neo Pop", "#6a2cff", "#ffd36a", ["#ff7ac8", "#6af7ff", "#fff6b0"]),
        ("Polar Dawn", "#07131e", "#6db8ff", ["#e9f6ff", "#173c63", "#a8d8ff"]),
        ("Aurora Blue", "#050816", "#67d7ff", ["#7c3aed", "#38f8d4", "#d8f7ff"]),
        ("Tahoe Ice", "#eaf4ff", "#1b6fe0", ["#ffffff", "#8dd7ff", "#3155d4"]),
        ("Lavender Glass", "#f7f2ff", "#5b56f5", ["#ffb7e8", "#a3e8ff", "#ffffff"]),
        ("Sunset Coral", "#fff0d8", "#ea4e79", ["#ffb86b", "#ffd1df", "#7c2d12"]),
        ("Coastal Haze", "#071722", "#89e8f2", ["#0e5a78", "#e8fbff", "#2dd4bf"]),
        ("Midnight Graphite", "#090b10", "#404c67", ["#99a4c7", "#1f2937", "#dbe4ff"]),
        ("Ember Fog", "#160c0a", "#f4b06a", ["#6c2d1e", "#ffe7c8", "#ff6b3d"]),
        ("Moss Glow", "#0e1b16", "#7fd3a0", ["#235543", "#eaf9f0", "#d4a95a"])
    ]

    init(options: ScreenshotBackgroundOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: imagePopoverHeight))
        var y: CGFloat = 416

        enabledButton.frame = NSRect(x: 16, y: y, width: 260, height: 22)
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        container.addSubview(enabledButton)

        y -= 38
        styleLabel = addLabel("Style", x: 16, y: y + 4, to: container)
        stylePopup.frame = NSRect(x: 106, y: y, width: 170, height: 26)
        stylePopup.addItems(withTitles: ["Gradient", "Solid Color", "Image"])
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        container.addSubview(stylePopup)

        y -= 36
        presetLabel = addLabel("Preset", x: 16, y: y + 4, to: container)
        presetPopup.frame = NSRect(x: 106, y: y, width: 170, height: 26)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        container.addSubview(presetPopup)

        uploadImageButton.frame = NSRect(x: 16, y: 302, width: 260, height: 30)
        uploadImageButton.bezelStyle = .rounded
        uploadImageButton.font = .systemFont(ofSize: 12, weight: .semibold)
        uploadImageButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        uploadImageButton.imagePosition = .imageLeading
        uploadImageButton.target = self
        uploadImageButton.action = #selector(uploadCustomImage)
        container.addSubview(uploadImageButton)

        addImagePresetGrid(to: container)

        y = 124
        paddingLabel = addSliderRow("Padding", slider: paddingSlider, valueLabel: paddingValue, y: y, min: 0, max: 240, to: container)
        y -= 38
        radiusLabel = addSliderRow("Radius", slider: radiusSlider, valueLabel: radiusValue, y: y, min: 0, max: 36, to: container)
        y -= 38
        shadowLabel = addSliderRow("Shadow", slider: shadowSlider, valueLabel: shadowValue, y: y, min: 0, max: 1, to: container)

        view = container
        syncControls()
    }

    @discardableResult
    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to view: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.frame = NSRect(x: x, y: y, width: 80, height: 16)
        view.addSubview(label)
        return label
    }

    private func addImagePresetGrid(to view: NSView) {
        let buttonSize = NSSize(width: 42, height: 34)
        let gap: CGFloat = 10
        let startX: CGFloat = 16
        let startY: CGFloat = 256
        let columns = 5

        for (index, preset) in ScreenshotBackgroundOptions.imagePresets.enumerated() {
            let row = index / columns
            let col = index % columns
            let button = NSButton(frame: NSRect(
                x: startX + CGFloat(col) * (buttonSize.width + gap),
                y: startY - CGFloat(row) * (buttonSize.height + gap),
                width: buttonSize.width,
                height: buttonSize.height
            ))
            button.image = ScreenshotBackgroundComposer.previewImage(options: imageOptions(for: preset), size: NSSize(width: 84, height: 68))
            button.imageScaling = .scaleAxesIndependently
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = preset.name
            button.tag = index
            button.target = self
            button.action = #selector(imagePresetTapped(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.cornerCurve = .continuous
            button.layer?.masksToBounds = true
            view.addSubview(button)
            imagePresetButtons.append(button)
        }
    }

    @discardableResult
    private func addSliderRow(_ title: String, slider: NSSlider, valueLabel: NSTextField, y: CGFloat, min: Double, max: Double, to view: NSView) -> NSTextField {
        let label = addLabel(title, x: 16, y: y + 6, to: view)
        slider.minValue = min
        slider.maxValue = max
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.frame = NSRect(x: 106, y: y, width: 126, height: 26)
        view.addSubview(slider)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 236, y: y + 5, width: 40, height: 16)
        view.addSubview(valueLabel)
        return label
    }

    private func layoutControls() {
        let isImageStyle = options.style == .image
        let height = isImageStyle ? imagePopoverHeight : compactPopoverHeight
        let size = NSSize(width: popoverWidth, height: height)
        view.setFrameSize(size)
        preferredContentSize = size
        popover?.contentSize = size

        let enabledY = height - 36
        let styleY = enabledY - 38
        let presetY = styleY - 36
        let uploadY = presetY - 40
        let imageGridStartY = uploadY - 46
        let sliderY = isImageStyle ? CGFloat(124) : presetY - 48

        enabledButton.frame = NSRect(x: 16, y: enabledY, width: 260, height: 22)
        styleLabel?.frame = NSRect(x: 16, y: styleY + 4, width: 80, height: 16)
        stylePopup.frame = NSRect(x: 106, y: styleY, width: 170, height: 26)
        presetLabel?.frame = NSRect(x: 16, y: presetY + 4, width: 80, height: 16)
        presetPopup.frame = NSRect(x: 106, y: presetY, width: 170, height: 26)
        uploadImageButton.frame = NSRect(x: 16, y: uploadY, width: 260, height: 30)
        layoutImagePresetButtons(startY: imageGridStartY)
        layoutSliderRow(label: paddingLabel, slider: paddingSlider, valueLabel: paddingValue, y: sliderY)
        layoutSliderRow(label: radiusLabel, slider: radiusSlider, valueLabel: radiusValue, y: sliderY - 38)
        layoutSliderRow(label: shadowLabel, slider: shadowSlider, valueLabel: shadowValue, y: sliderY - 76)
        view.needsDisplay = true
    }

    private func layoutImagePresetButtons(startY: CGFloat) {
        let buttonSize = NSSize(width: 42, height: 34)
        let gap: CGFloat = 10
        let startX: CGFloat = 16
        let columns = 5

        for (index, button) in imagePresetButtons.enumerated() {
            let row = index / columns
            let col = index % columns
            button.frame = NSRect(
                x: startX + CGFloat(col) * (buttonSize.width + gap),
                y: startY - CGFloat(row) * (buttonSize.height + gap),
                width: buttonSize.width,
                height: buttonSize.height
            )
        }
    }

    private func layoutSliderRow(label: NSTextField?, slider: NSSlider, valueLabel: NSTextField, y: CGFloat) {
        label?.frame = NSRect(x: 16, y: y + 6, width: 80, height: 16)
        slider.frame = NSRect(x: 106, y: y, width: 126, height: 26)
        valueLabel.frame = NSRect(x: 236, y: y + 5, width: 40, height: 16)
    }

    private func syncControls() {
        enabledButton.state = options.isEnabled ? .on : .off
        switch options.style {
        case .gradient: stylePopup.selectItem(at: 0)
        case .solid: stylePopup.selectItem(at: 1)
        case .image: stylePopup.selectItem(at: 2)
        }
        paddingSlider.doubleValue = Double(options.padding)
        radiusSlider.doubleValue = Double(options.cornerRadius)
        shadowSlider.doubleValue = Double(options.shadow)
        rebuildPresetPopup()
        updateStyleVisibility()
        updateValueLabels()
        updateImagePresetSelection()
    }

    private func rebuildPresetPopup() {
        presetPopup.removeAllItems()
        switch options.style {
        case .solid:
            presetPopup.addItems(withTitles: solidPresets.map(\.0))
            if let index = solidPresets.firstIndex(where: { $0.0 == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .gradient:
            presetPopup.addItems(withTitles: gradientPresets.map(\.name))
            if let index = gradientPresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .image:
            presetPopup.addItems(withTitles: ScreenshotBackgroundOptions.imagePresets.map(\.name))
            if let index = ScreenshotBackgroundOptions.imagePresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        }
    }

    private func updateStyleVisibility() {
        let isImageStyle = options.style == .image
        layoutControls()
        presetLabel?.isHidden = isImageStyle
        presetPopup.isHidden = isImageStyle
        uploadImageButton.isHidden = !isImageStyle
        imagePresetButtons.forEach { $0.isHidden = !isImageStyle }
        uploadImageButton.title = options.customImageName.map { "Custom: \($0)" } ?? "Upload Custom Image"
    }

    private func updateImagePresetSelection() {
        for (index, button) in imagePresetButtons.enumerated() {
            let preset = ScreenshotBackgroundOptions.imagePresets[index]
            let selected = options.style == .image && options.customImageData == nil && preset.name == options.presetName
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.18).cgColor
        }
    }

    private func updateValueLabels() {
        paddingValue.stringValue = "\(Int(options.padding))"
        radiusValue.stringValue = "\(Int(options.cornerRadius))"
        shadowValue.stringValue = "\(Int(options.shadow * 100))%"
    }

    private func emitChange() {
        updateStyleVisibility()
        updateImagePresetSelection()
        updateValueLabels()
        onChange?(options)
    }

    @objc private func enabledChanged() {
        options.isEnabled = enabledButton.state == .on
        emitChange()
    }

    @objc private func styleChanged() {
        switch stylePopup.indexOfSelectedItem {
        case 1:
            options.style = .solid
        case 2:
            options.style = .image
            options.isEnabled = true
            if options.customImageData == nil,
               !ScreenshotBackgroundOptions.imagePresets.contains(where: { $0.name == options.presetName }) {
                let preset = ScreenshotBackgroundOptions.imagePresets[0]
                options.presetName = preset.name
                options.gradientStartHex = preset.startHex
                options.gradientEndHex = preset.endHex
                options.accentHexes = preset.accentHexes
            }
        default:
            options.style = .gradient
        }
        rebuildPresetPopup()
        if options.style == .image {
            emitChange()
        } else {
            presetChanged()
        }
    }

    @objc private func presetChanged() {
        let index = max(0, presetPopup.indexOfSelectedItem)
        switch options.style {
        case .solid:
            let preset = solidPresets[min(index, solidPresets.count - 1)]
            options.presetName = preset.0
            options.colorHex = preset.1
            options.accentHexes = []
        case .gradient:
            let preset = gradientPresets[min(index, gradientPresets.count - 1)]
            options.presetName = preset.name
            options.gradientStartHex = preset.start
            options.gradientEndHex = preset.end
            options.accentHexes = preset.accents
            options.customImageData = nil
            options.customImageName = nil
        case .image:
            let preset = ScreenshotBackgroundOptions.imagePresets[min(index, ScreenshotBackgroundOptions.imagePresets.count - 1)]
            applyImagePreset(preset)
        }
        emitChange()
    }

    @objc private func imagePresetTapped(_ sender: NSButton) {
        let preset = ScreenshotBackgroundOptions.imagePresets[min(sender.tag, ScreenshotBackgroundOptions.imagePresets.count - 1)]
        applyImagePreset(preset)
        emitChange()
    }

    @objc private func uploadCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url),
              NSImage(data: data) != nil else { return }

        options.isEnabled = true
        options.style = .image
        options.presetName = "Custom Image"
        options.customImageData = data
        options.customImageName = url.lastPathComponent
        stylePopup.selectItem(at: 2)
        emitChange()
    }

    private func applyImagePreset(_ preset: ScreenshotBackgroundImagePreset) {
        options.isEnabled = true
        options.style = .image
        options.presetName = preset.name
        options.gradientStartHex = preset.startHex
        options.gradientEndHex = preset.endHex
        options.accentHexes = preset.accentHexes
        options.customImageData = nil
        options.customImageName = nil
    }

    private func imageOptions(for preset: ScreenshotBackgroundImagePreset) -> ScreenshotBackgroundOptions {
        var preview = options
        preview.isEnabled = true
        preview.style = .image
        preview.presetName = preset.name
        preview.gradientStartHex = preset.startHex
        preview.gradientEndHex = preset.endHex
        preview.accentHexes = preset.accentHexes
        preview.customImageData = nil
        preview.customImageName = nil
        return preview
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        if sender === paddingSlider { options.padding = CGFloat(sender.doubleValue.rounded()) }
        if sender === radiusSlider { options.cornerRadius = CGFloat(sender.doubleValue.rounded()) }
        if sender === shadowSlider { options.shadow = CGFloat(sender.doubleValue) }
        emitChange()
    }
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
        wantsLayer = true
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

@MainActor
private final class PremiumToolbarActionButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
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
        animateBackground(ShotnixColors.cornerButtonHover.cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateBackground(ShotnixColors.editorActionBackground.cgColor)
    }

    override func mouseDown(with event: NSEvent) {
        animateBackground(ShotnixColors.cornerButtonPressed.cgColor)
        layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        animateBackground(isHovered ? ShotnixColors.cornerButtonHover.cgColor : ShotnixColors.editorActionBackground.cgColor)
        layer?.transform = CATransform3DIdentity
        super.mouseUp(with: event)
    }

    private func configureLayer() {
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShotnixColors.editorActionBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShotnixColors.editorDockBorder.cgColor
    }

    private func animateBackground(_ color: CGColor) {
        wantsLayer = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            self.layer?.backgroundColor = color
        }
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
                btn.title = ""
                btn.alternateTitle = ""
                btn.attributedTitle = NSAttributedString(string: "")
                btn.imagePosition = .noImage
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
