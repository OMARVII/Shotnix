import AppKit
import UniformTypeIdentifiers

// MARK: – Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    static let toolGroups: [[AnnotationTool]] = [
        [.select, .arrow, .rectangle, .filledRectangle, .ellipse, .line, .freehand],
        [.text, .callout, .numberedStep, .highlighter, .freehandHighlighter],
        [.blur, .pixelate, .spotlight, .crop],
    ]
    // Geometry. Everything sits on the dock's midline, and the insets are
    // concentric: 8 pt from the dock's edge to each group, 3 pt from a group's
    // edge to its tool buttons on every side, with corner radii stepping down
    // to match (18 → 10 → 7).
    static let height: CGFloat = 56
    private static let edgeInset: CGFloat = 8
    private static let groupHeight: CGFloat = height - 2 * edgeInset
    private static let groupPadding: CGFloat = 3
    private static let groupSpacing: CGFloat = 8
    private static let buttonSize: CGFloat = 34
    private static let toolPitch: CGFloat = 36
    private static let controlHeight: CGFloat = 30
    private static let dockRadius: CGFloat = 18
    private static let groupRadius: CGFloat = dockRadius - edgeInset
    static let buttonRadius: CGFloat = groupRadius - groupPadding
    /// The color button sits as far from its group's edge as from its top.
    private static let colorInset: CGFloat = (groupHeight - controlHeight) / 2
    /// The contextual area after the color button: size, text, strength,
    /// spotlight, or crop controls depending on the tool or selection.
    private static let optionsWidth: CGFloat = 164
    /// Controls in the options area end this far before its right side.
    private static let optionsTrailing: CGFloat = 10
    private static let actionFont = NSFont.systemFont(ofSize: 11)
    private static let prominentActionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The least room between a button's title and its edges when a
    /// translation needs more than the design width.
    private static let titleInset: CGFloat = 8

    /// 110 pt, or wider when the title needs it (English always fits).
    private static var backgroundButtonWidth: CGFloat {
        fittedWidth(L("Background"), font: prominentActionFont, atLeast: 110)
    }

    /// Copy and Save share one width: 54 pt, or what the longer title needs.
    private static var actionButtonWidth: CGFloat {
        max(fittedWidth(L("Copy"), font: actionFont, atLeast: 54),
            fittedWidth(L("Save"), font: prominentActionFont, atLeast: 54))
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func fittedWidth(_ title: String, font: NSFont, atLeast minimum: CGFloat) -> CGFloat {
        max(minimum, textWidth(title, font: font) + 2 * titleInset)
    }

    private static func toolGroupWidth(_ count: Int) -> CGFloat {
        2 * groupPadding + CGFloat(count) * buttonSize + CGFloat(count - 1) * (toolPitch - buttonSize)
    }

    private static let optionsGroupWidth: CGFloat =
        colorInset + controlHeight + 10 + (optionsWidth - optionsTrailing) + colorInset

    /// Grows with the action buttons' titles in the user's language.
    static var requiredWidth: CGFloat {
        let tools = toolGroups.reduce(0) { $0 + toolGroupWidth($1.count) + groupSpacing }
        // Background, gap, Copy, gap, Save
        let actions = backgroundButtonWidth + 8 + actionButtonWidth + 4 + actionButtonWidth
        return edgeInset + tools + optionsGroupWidth + groupSpacing + actions + edgeInset
    }

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onBoldChanged: ((Bool) -> Void)?
    var onRedactionStrengthChanged: ((CGFloat) -> Void)?
    var onRoundedCornersChanged: ((Bool) -> Void)?
    var onSpotlightShapeChanged: ((_ ellipse: Bool) -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onResetCrop: (() -> Void)?
    var onBackgroundOptionsChanged: ((ScreenshotBackgroundOptions) -> Void)?

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    /// Group backgrounds, left to right, and the last control's right edge
    /// (layout tests).
    private(set) var groupFrames: [NSRect] = []
    private(set) var trailingControlMaxX: CGFloat = 0
    private var selectedTool: AnnotationTool = .arrow
    private var colorButton: NSButton?
    private var currentColor: NSColor = .systemRed
    private var colorPopover: NSPopover?
    private var backgroundButton: NSButton?
    private var backgroundPopover: NSPopover?
    private var backgroundOptions = ScreenshotBackgroundOptions.editorDefault
    private(set) var options = AnnotationToolOptions()

    // Contextual options
    private let optionsContainer = NSView()
    private let sizeLabel = NSTextField(labelWithString: L("Size"))
    private let lineWidthSlider = NSSlider(value: 3, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let roundedCornersButton = ToolbarToggleButton(symbol: "app", label: L("Rounded corners"), toolTip: L("Rounded Corners (\u{2325}R)"))
    private let fontSizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = ToolbarToggleButton(symbol: "bold", label: L("Bold"), toolTip: L("Bold"))
    private let strengthLabel = NSTextField(labelWithString: L("Strength"))
    private let strengthSlider = NSSlider(
        value: Double(AnnotationRedaction.defaultStrength),
        minValue: Double(AnnotationRedaction.strengthRange.lowerBound),
        maxValue: Double(AnnotationRedaction.strengthRange.upperBound),
        target: nil, action: nil
    )
    private let shapeLabel = NSTextField(labelWithString: L("Shape"))
    private let spotlightShapeControl = NSSegmentedControl()
    private let applyCropButton = PremiumToolbarActionButton(title: L("Apply"), target: nil, action: nil)
    private let resetCropButton = PremiumToolbarActionButton(title: L("Reset"), target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    static let fontSizes: [Int] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 80, 96]

    /// The shared color panel talks to one toolbar at a time.
    private static weak var colorPanelClient: AnnotationToolbar?

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
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(L("Annotation tools"))

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

        let midY = Self.height / 2
        let controlY = midY - Self.controlHeight / 2
        var x = Self.edgeInset

        // Tool groups: shapes, markup, effects
        for group in Self.toolGroups {
            let width = Self.toolGroupWidth(group.count)
            addToolbarGroupBackground(x: x, width: width)
            var buttonX = x + Self.groupPadding
            for tool in group {
                let btn = makeToolButton(tool: tool)
                btn.frame = NSRect(x: buttonX, y: midY - Self.buttonSize / 2, width: Self.buttonSize, height: Self.buttonSize)
                addSubview(btn)
                toolButtons[tool] = btn
                buttonX += Self.toolPitch
            }
            x += width + Self.groupSpacing
        }

        addToolbarGroupBackground(x: x, width: Self.optionsGroupWidth)
        x += Self.colorInset

        // Color button (circular, shows current color)
        let colorBtn = NSButton(title: "", target: self, action: #selector(showColorPopover(_:)))
        colorBtn.frame = NSRect(x: x, y: controlY, width: Self.controlHeight, height: Self.controlHeight)
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
        colorBtn.toolTip = L("Color")
        colorBtn.setAccessibilityLabel(L("Color"))
        colorBtn.setAccessibilityValue(Self.colorName(currentColor))
        addSubview(colorBtn)
        colorButton = colorBtn
        x += Self.controlHeight + 10

        optionsContainer.frame = NSRect(x: x, y: midY - 25, width: Self.optionsWidth, height: 50)
        addSubview(optionsContainer)
        buildOptionControls()
        x += Self.optionsWidth - Self.optionsTrailing + Self.colorInset + Self.groupSpacing

        let backgroundWidth = Self.backgroundButtonWidth
        let backgroundBtn = PremiumToolbarActionButton(title: L("Background"), target: self, action: #selector(backgroundTapped(_:)))
        backgroundBtn.bezelStyle = .regularSquare
        backgroundBtn.font = Self.prominentActionFont
        backgroundBtn.imagePosition = .noImage
        backgroundBtn.toolTip = L("Background")
        backgroundBtn.frame = NSRect(x: x, y: controlY, width: backgroundWidth, height: Self.controlHeight)
        addSubview(backgroundBtn)
        backgroundButton = backgroundBtn
        x += backgroundWidth + 8

        // Action buttons
        let actionWidth = Self.actionButtonWidth
        let actions: [(title: String, action: Selector, help: String, font: NSFont)] = [
            (L("Copy"), #selector(copyTapped), L("Copy (\u{2318}C)"), Self.actionFont),
            (L("Save"), #selector(saveTapped), L("Save (\u{2318}S)"), Self.prominentActionFont),
        ]
        for item in actions {
            let btn = PremiumToolbarActionButton(title: item.title, target: self, action: item.action)
            btn.bezelStyle = .regularSquare
            btn.font = item.font
            btn.frame = NSRect(x: x, y: controlY, width: actionWidth, height: Self.controlHeight)
            btn.toolTip = item.help
            addSubview(btn)
            trailingControlMaxX = btn.frame.maxX
            x += actionWidth + 4
        }

        selectTool(.arrow)
        showOptions(options)
    }

    private func buildOptionControls() {
        for label in [sizeLabel, strengthLabel, shapeLabel] {
            label.font = .systemFont(ofSize: 11)
            optionsContainer.addSubview(label)
        }

        lineWidthSlider.target = self
        lineWidthSlider.action = #selector(lineWidthChanged(_:))
        lineWidthSlider.toolTip = L("Line width")
        lineWidthSlider.setAccessibilityLabel(L("Line width"))
        optionsContainer.addSubview(lineWidthSlider)

        roundedCornersButton.target = self
        roundedCornersButton.action = #selector(roundedCornersToggled(_:))
        optionsContainer.addSubview(roundedCornersButton)

        fontSizePopUp.font = .systemFont(ofSize: 11)
        fontSizePopUp.target = self
        fontSizePopUp.action = #selector(fontSizeChanged(_:))
        fontSizePopUp.toolTip = L("Text size")
        fontSizePopUp.setAccessibilityLabel(L("Text size"))
        rebuildFontSizeItems(selecting: options.fontSize)
        optionsContainer.addSubview(fontSizePopUp)

        boldButton.target = self
        boldButton.action = #selector(boldToggled(_:))
        optionsContainer.addSubview(boldButton)

        strengthSlider.target = self
        strengthSlider.action = #selector(strengthChanged(_:))
        strengthSlider.toolTip = L("How strongly blur and pixelate hide what's under them")
        strengthSlider.setAccessibilityLabel(L("Redaction strength"))
        optionsContainer.addSubview(strengthSlider)

        spotlightShapeControl.segmentCount = 2
        spotlightShapeControl.trackingMode = .selectOne
        spotlightShapeControl.setImage(NSImage(systemSymbolName: "rectangle", accessibilityDescription: L("Rectangle")), forSegment: 0)
        spotlightShapeControl.setImage(NSImage(systemSymbolName: "circle", accessibilityDescription: L("Ellipse")), forSegment: 1)
        spotlightShapeControl.setToolTip(L("Rectangle"), forSegment: 0)
        spotlightShapeControl.setToolTip(L("Ellipse"), forSegment: 1)
        spotlightShapeControl.selectedSegment = 0
        spotlightShapeControl.target = self
        spotlightShapeControl.action = #selector(spotlightShapeChanged(_:))
        spotlightShapeControl.setAccessibilityLabel(L("Spotlight shape"))
        optionsContainer.addSubview(spotlightShapeControl)

        applyCropButton.target = self
        applyCropButton.action = #selector(applyCropTapped)
        applyCropButton.font = Self.prominentActionFont
        applyCropButton.toolTip = L("Apply the crop (Return)")
        applyCropButton.setAccessibilityLabel(L("Apply crop"))
        optionsContainer.addSubview(applyCropButton)

        resetCropButton.target = self
        resetCropButton.action = #selector(resetCropTapped)
        resetCropButton.font = Self.actionFont
        resetCropButton.toolTip = L("Show the whole screenshot again")
        resetCropButton.setAccessibilityLabel(L("Reset crop"))
        optionsContainer.addSubview(resetCropButton)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        optionsContainer.addSubview(hintLabel)
    }

    private var optionControls: [NSView] {
        [sizeLabel, lineWidthSlider, roundedCornersButton, fontSizePopUp, boldButton,
         strengthLabel, strengthSlider, shapeLabel, spotlightShapeControl,
         applyCropButton, resetCropButton, hintLabel]
    }

    /// Shows the controls for the current tool or selection with its values.
    func showOptions(_ newOptions: AnnotationToolOptions) {
        options = newOptions
        let visible: [NSView]
        // Controls end 10 pt before the group's edge, matching the color button's inset.
        // A label keeps its design width unless its translation needs more;
        // the control beside it then gives up that room.
        let end = Self.optionsWidth - Self.optionsTrailing
        switch newOptions.context {
        case .stroke:
            let label = Self.labelWidth(sizeLabel, atLeast: 30)
            sizeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            lineWidthSlider.frame = NSRect(x: label + 2, y: 11, width: end - label - 2, height: 28)
            visible = [sizeLabel, lineWidthSlider]
        case .rectangle:
            let label = Self.labelWidth(sizeLabel, atLeast: 30)
            sizeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            lineWidthSlider.frame = NSRect(x: label + 2, y: 11, width: 116 - label - 2, height: 28)
            roundedCornersButton.frame = NSRect(x: 124, y: 10, width: 30, height: 30)
            visible = [sizeLabel, lineWidthSlider, roundedCornersButton]
        case .text:
            fontSizePopUp.frame = NSRect(x: 0, y: 11, width: 92, height: 28)
            boldButton.frame = NSRect(x: 98, y: 10, width: 30, height: 30)
            visible = [fontSizePopUp, boldButton]
        case .redaction:
            let label = Self.labelWidth(strengthLabel, atLeast: 50)
            strengthLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            strengthSlider.frame = NSRect(x: label + 2, y: 11, width: end - label - 2, height: 28)
            visible = [strengthLabel, strengthSlider]
        case .spotlight:
            let label = Self.labelWidth(shapeLabel, atLeast: 38)
            shapeLabel.frame = NSRect(x: 0, y: 17, width: label, height: 16)
            spotlightShapeControl.frame = NSRect(x: label + 4, y: 13, width: 84, height: 24)
            visible = [shapeLabel, spotlightShapeControl]
        case .crop:
            let (apply, reset) = Self.cropButtonWidths(apply: applyCropButton.title, reset: resetCropButton.title)
            applyCropButton.frame = NSRect(x: 0, y: 10, width: apply, height: 30)
            resetCropButton.frame = NSRect(x: end - reset, y: 10, width: reset, height: 30)
            visible = [applyCropButton, resetCropButton]
        case .none:
            showHint(selectedTool == .numberedStep ? L("Click to add the next step") : L("Click an annotation to edit it"), width: end)
            visible = [hintLabel]
        }
        for control in optionControls {
            control.isHidden = !visible.contains(where: { $0 === control })
        }

        lineWidthSlider.doubleValue = Double(newOptions.lineWidth)
        roundedCornersButton.state = newOptions.roundedCorners ? .on : .off
        rebuildFontSizeItems(selecting: newOptions.fontSize)
        boldButton.state = newOptions.isBold ? .on : .off
        strengthSlider.doubleValue = Double(newOptions.redactionStrength)
        spotlightShapeControl.selectedSegment = newOptions.spotlightEllipse ? 1 : 0
        applyCropButton.isEnabled = newOptions.canApplyCrop
        resetCropButton.isEnabled = newOptions.canResetCrop
        applyCropButton.alphaValue = newOptions.canApplyCrop ? 1 : 0.45
        resetCropButton.alphaValue = newOptions.canResetCrop ? 1 : 0.45
    }

    /// A label's design width, or the width its translation needs plus a
    /// small gap before the control beside it.
    private static func labelWidth(_ label: NSTextField, atLeast minimum: CGFloat) -> CGFloat {
        max(minimum, ceil(label.intrinsicContentSize.width) + 4)
    }

    /// Apply and Reset share the crop row: 74 pt each, or, when a
    /// translation needs more, each its title plus an even share of the rest.
    private static func cropButtonWidths(apply: String, reset: String) -> (apply: CGFloat, reset: CGFloat) {
        let applyText = textWidth(apply, font: prominentActionFont)
        let resetText = textWidth(reset, font: actionFont)
        let inset: CGFloat = 6
        if applyText + 2 * inset <= 74, resetText + 2 * inset <= 74 { return (74, 74) }
        let row = optionsWidth - optionsTrailing - 6
        let spare = max(0, row - applyText - resetText) / 2
        return (applyText + spare, resetText + spare)
    }

    /// One line where the hint fits, as it always does in English; a longer
    /// translation wraps to two lines, centered the same way.
    private func showHint(_ text: String, width: CGFloat) {
        hintLabel.stringValue = text
        let fits = Self.textWidth(text, font: hintLabel.font ?? Self.actionFont) + 1 <= width
        hintLabel.cell?.wraps = !fits
        hintLabel.cell?.truncatesLastVisibleLine = !fits
        hintLabel.maximumNumberOfLines = fits ? 0 : 2
        hintLabel.lineBreakMode = fits ? .byTruncatingTail : .byWordWrapping
        hintLabel.frame = fits
            ? NSRect(x: 0, y: 17, width: width, height: 16)
            : NSRect(x: 0, y: 11, width: width, height: 28)
    }

    /// Standard sizes, plus the exact size of the selection when a resize
    /// left it between them.
    private func rebuildFontSizeItems(selecting size: CGFloat) {
        let rounded = Int(size.rounded())
        var sizes = Self.fontSizes
        if !sizes.contains(rounded) {
            sizes.append(rounded)
            sizes.sort()
        }
        if fontSizePopUp.itemArray.map(\.tag) != sizes {
            fontSizePopUp.removeAllItems()
            for value in sizes {
                // Point sizes as plain digits.
                fontSizePopUp.addItem(withTitle: L("\(String(value)) pt"))
                fontSizePopUp.lastItem?.tag = value
            }
        }
        fontSizePopUp.selectItem(withTag: rounded)
    }

    private func addToolbarGroupBackground(x: CGFloat, width: CGFloat) {
        let group = NSView(frame: NSRect(x: x, y: Self.edgeInset, width: width, height: Self.groupHeight))
        groupFrames.append(group.frame)
        group.wantsLayer = true
        group.layer?.cornerRadius = Self.groupRadius
        group.layer?.cornerCurve = .continuous
        group.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        group.layer?.borderWidth = 1
        group.layer?.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
        addSubview(group)
    }

    private func makeToolButton(tool: AnnotationTool) -> NSButton {
        let btn = AnnotationToolButton(frame: .zero)
        btn.wantsLayer = true
        btn.layer?.cornerRadius = Self.buttonRadius
        btn.layer?.cornerCurve = .continuous
        btn.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: tool.name)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.toolTip = tool.tooltip
        btn.target = self
        btn.action = #selector(toolTapped(_:))
        btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
        // Tools are mutually exclusive: VoiceOver reads them as radio buttons.
        btn.setAccessibilityRole(.radioButton)
        btn.setAccessibilityLabel(tool.name)
        btn.setAccessibilityHelp(tool.tooltip)
        btn.setAccessibilityValue(NSNumber(value: 0))
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
        toolButtons[selectedTool]?.setAccessibilityValue(NSNumber(value: 0))
        selectedTool = tool
        toolButtons[tool]?.wantsLayer = true
        toolButtons[tool]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        toolButtons[tool]?.setAccessibilityValue(NSNumber(value: 1))
        if let newBtn = toolButtons[tool] as? AnnotationToolButton {
            newBtn.isSelectedTool = true
        }
    }

    func frame(of tool: AnnotationTool) -> NSRect? {
        toolButtons[tool]?.frame
    }

    var colorButtonFrame: NSRect? { colorButton?.frame }

    func selectToolExternally(_ tool: AnnotationTool) {
        selectTool(tool)
    }

    func setColorExternally(_ color: NSColor) {
        currentColor = color
        colorButton?.layer?.backgroundColor = color.cgColor
        colorButton?.setAccessibilityValue(Self.colorName(color))
    }

    func setBackgroundOptionsExternally(_ options: ScreenshotBackgroundOptions) {
        backgroundOptions = options
        backgroundButton?.contentTintColor = options.isEnabled ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.86)
    }

    /// Accessibility helpers for tests: the control a VoiceOver user reaches.
    func toolButton(for tool: AnnotationTool) -> NSButton? { toolButtons[tool] }
    var colorControl: NSButton? { colorButton }
    var visibleOptionControls: [NSView] { optionControls.filter { !$0.isHidden } }

    static func colorName(_ color: NSColor) -> String {
        let names: [(NSColor, String)] = [
            (.systemRed, L("Red")), (.systemOrange, L("Orange")), (.systemYellow, L("Yellow")), (.systemGreen, L("Green")),
            (.systemBlue, L("Blue")), (.systemPurple, L("Purple")), (.white, L("White")), (.black, L("Black")),
        ]
        if let match = names.first(where: { $0.0 == color }) { return match.1 }
        guard let rgb = color.usingColorSpace(.sRGB) else { return L("Custom color") }
        let hex = String(format: "%02X%02X%02X",
                         Int((rgb.redComponent * 255).rounded()),
                         Int((rgb.greenComponent * 255).rounded()),
                         Int((rgb.blueComponent * 255).rounded()))
        return L("Custom color #\(hex)")
    }

    // MARK: Color

    @objc private func showColorPopover(_ sender: NSButton) {
        let controller = ColorPopoverController(currentColor: currentColor)
        controller.onColorPicked = { [weak self] color in
            self?.applyPickedColor(color)
        }
        controller.onCustomColorRequested = { [weak self] in
            self?.showColorPanel()
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        colorPopover = popover
    }

    private func applyPickedColor(_ color: NSColor) {
        setColorExternally(color)
        onColorChanged?(color)
    }

    /// The system color panel, targeting this toolbar and kept above the
    /// editor window so it can't open behind it.
    func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.color = currentColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        Self.colorPanelClient = self
        if let window, panel.level.rawValue <= window.level.rawValue {
            panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        }
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        applyPickedColor(sender.color)
    }

    /// Stops the shared color panel from messaging this toolbar once its
    /// editor closes.
    func detachColorPanel() {
        guard Self.colorPanelClient === self else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        Self.colorPanelClient = nil
    }

    // MARK: Options actions

    @objc private func lineWidthChanged(_ sender: NSSlider) { onLineWidthChanged?(CGFloat(sender.doubleValue)) }

    @objc private func roundedCornersToggled(_ sender: NSButton) {
        roundedCornersButton.refreshAppearance()
        onRoundedCornersChanged?(sender.state == .on)
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag > 0 else { return }
        onFontSizeChanged?(CGFloat(tag))
    }

    @objc private func boldToggled(_ sender: NSButton) {
        boldButton.refreshAppearance()
        onBoldChanged?(sender.state == .on)
    }

    @objc private func strengthChanged(_ sender: NSSlider) { onRedactionStrengthChanged?(CGFloat(sender.doubleValue)) }

    @objc private func spotlightShapeChanged(_ sender: NSSegmentedControl) {
        onSpotlightShapeChanged?(sender.selectedSegment == 1)
    }

    @objc private func applyCropTapped() { onApplyCrop?() }
    @objc private func resetCropTapped() { onResetCrop?() }

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
    @objc private func copyTapped()       { onCopy?() }
    @objc private func saveTapped()       { onSave?() }
}

/// Icon toggle in the options area, tinted like a selected tool while on.
@MainActor
final class ToolbarToggleButton: NSButton {
    convenience init(symbol: String, label: String, toolTip: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        setButtonType(.pushOnPushOff)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        self.toolTip = toolTip
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = AnnotationToolbar.buttonRadius
        layer?.cornerCurve = .continuous
    }

    override var state: NSControl.StateValue {
        didSet { refreshAppearance() }
    }

    func refreshAppearance() {
        layer?.backgroundColor = state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor : nil
        contentTintColor = state == .on ? .controlAccentColor : nil
    }
}

// MARK: - Per-image background popover

@MainActor
final class BackgroundPopoverController: NSViewController {
    var onChange: ((ScreenshotBackgroundOptions) -> Void)?
    weak var popover: NSPopover?

    private var options: ScreenshotBackgroundOptions
    private let enabledButton = NSButton(checkboxWithTitle: L("Apply background to this image"), target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let uploadImageButton = NSButton(title: L("Upload Custom Image"), target: nil, action: nil)
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

    // `name` identifies a preset (it's stored in the options); `title` is shown.
    private let solidPresets: [(name: String, title: String, hex: String)] = [
        ("Porcelain", L("Porcelain"), "#f4eadb"),
        ("Graphite", L("Graphite"), "#111827"),
        ("Bone", L("Bone"), "#eee7d6"),
        ("Silver", L("Silver"), "#d8dde7"),
        ("Space Gray", L("Space Gray"), "#2b3038"),
        ("Moss", L("Moss"), "#243528"),
        ("Clay", L("Clay"), "#7c3f2d")
    ]
    private let gradientPresets: [(name: String, title: String, start: String, end: String, accents: [String])] = [
        ("Neo Pop", L("Neo Pop"), "#6a2cff", "#ffd36a", ["#ff7ac8", "#6af7ff", "#fff6b0"]),
        ("Polar Dawn", L("Polar Dawn"), "#07131e", "#6db8ff", ["#e9f6ff", "#173c63", "#a8d8ff"]),
        ("Aurora Blue", L("Aurora Blue"), "#050816", "#67d7ff", ["#7c3aed", "#38f8d4", "#d8f7ff"]),
        ("Tahoe Ice", L("Tahoe Ice"), "#eaf4ff", "#1b6fe0", ["#ffffff", "#8dd7ff", "#3155d4"]),
        ("Lavender Glass", L("Lavender Glass"), "#f7f2ff", "#5b56f5", ["#ffb7e8", "#a3e8ff", "#ffffff"]),
        ("Sunset Coral", L("Sunset Coral"), "#fff0d8", "#ea4e79", ["#ffb86b", "#ffd1df", "#7c2d12"]),
        ("Coastal Haze", L("Coastal Haze"), "#071722", "#89e8f2", ["#0e5a78", "#e8fbff", "#2dd4bf"]),
        ("Midnight Graphite", L("Midnight Graphite"), "#090b10", "#404c67", ["#99a4c7", "#1f2937", "#dbe4ff"]),
        ("Ember Fog", L("Ember Fog"), "#160c0a", "#f4b06a", ["#6c2d1e", "#ffe7c8", "#ff6b3d"]),
        ("Moss Glow", L("Moss Glow"), "#0e1b16", "#7fd3a0", ["#235543", "#eaf9f0", "#d4a95a"])
    ]

    init(options: ScreenshotBackgroundOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: imagePopoverHeight))
        var y: CGFloat = 416

        enabledButton.frame = NSRect(x: 16, y: y, width: 268, height: 22)
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        container.addSubview(enabledButton)

        y -= 38
        styleLabel = addLabel(L("Style"), x: 16, y: y + 4, to: container)
        stylePopup.frame = NSRect(x: 106, y: y, width: 170, height: 26)
        stylePopup.addItems(withTitles: [L("Gradient"), L("Solid Color"), L("Image")])
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        container.addSubview(stylePopup)

        y -= 36
        presetLabel = addLabel(L("Preset"), x: 16, y: y + 4, to: container)
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
        paddingLabel = addSliderRow(L("Padding"), slider: paddingSlider, valueLabel: paddingValue, y: y, min: 0, max: 240, to: container)
        y -= 38
        radiusLabel = addSliderRow(L("Radius"), slider: radiusSlider, valueLabel: radiusValue, y: y, min: 0, max: 36, to: container)
        y -= 38
        shadowLabel = addSliderRow(L("Shadow"), slider: shadowSlider, valueLabel: shadowValue, y: y, min: 0, max: 1, to: container)

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
            button.toolTip = preset.title
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

        enabledButton.frame = NSRect(x: 16, y: enabledY, width: 268, height: 22)
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
            presetPopup.addItems(withTitles: solidPresets.map(\.title))
            if let index = solidPresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .gradient:
            presetPopup.addItems(withTitles: gradientPresets.map(\.title))
            if let index = gradientPresets.firstIndex(where: { $0.name == options.presetName }) {
                presetPopup.selectItem(at: index)
            }
        case .image:
            presetPopup.addItems(withTitles: ScreenshotBackgroundOptions.imagePresets.map(\.title))
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
        uploadImageButton.title = options.customImageName.map { L("Custom: \($0)") } ?? L("Upload Custom Image")
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
        // Point sizes as plain digits.
        paddingValue.stringValue = String(Int(options.padding))
        radiusValue.stringValue = String(Int(options.cornerRadius))
        shadowValue.stringValue = L("\(Int(options.shadow * 100))%")
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
            options.presetName = preset.name
            options.colorHex = preset.hex
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

    /// Presses in about its center. NSButton tracks the click inside
    /// `super.mouseDown` and never gets `mouseUp`, so the spring back runs
    /// when that returns.
    override func mouseDown(with event: NSEvent) {
        wantsLayer = true
        guard let layer else { return super.mouseDown(with: event) }
        let pressed = layer.scaledAboutCenter(0.92)
        layer.transform = pressed
        super.mouseDown(with: event)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: pressed)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 15
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "bounceBack")
        layer.transform = CATransform3DIdentity
    }
}

extension CALayer {
    /// A scale about the layer's center, whatever its anchor point. Layers of
    /// layer-backed views anchor at a corner, so a plain scale would pull a
    /// button toward that corner.
    func scaledAboutCenter(_ scale: CGFloat) -> CATransform3D {
        let dx = bounds.width * (0.5 - anchorPoint.x)
        let dy = bounds.height * (0.5 - anchorPoint.y)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
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

    /// NSButton tracks the click inside `super.mouseDown` and never gets
    /// `mouseUp`, so the release look is restored when that returns.
    override func mouseDown(with event: NSEvent) {
        animateBackground(ShotnixColors.cornerButtonPressed.cgColor)
        if let layer { layer.transform = layer.scaledAboutCenter(0.97) }
        super.mouseDown(with: event)
        animateBackground(isHovered ? ShotnixColors.cornerButtonHover.cgColor : ShotnixColors.editorActionBackground.cgColor)
        layer?.transform = CATransform3DIdentity
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
    /// "Custom…" — the toolbar opens the system color panel.
    var onCustomColorRequested: (() -> Void)?
    private var currentColor: NSColor

    private let presets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black
    ]

    init(currentColor: NSColor = .systemRed) {
        self.currentColor = currentColor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

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
                let name = AnnotationToolbar.colorName(presets[idx])
                btn.toolTip = name
                btn.setAccessibilityLabel(name)
                container.addSubview(btn)
            }
            y -= gap
        }

        y -= 2
        let customBtn = NSButton(title: L("Custom\u{2026}"), target: self, action: #selector(customTapped))
        customBtn.bezelStyle = .inline
        customBtn.font = .systemFont(ofSize: 11)
        customBtn.frame = NSRect(x: padding, y: y - 20, width: width - padding * 2, height: 20)
        customBtn.setAccessibilityLabel(L("Custom color"))
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
        onCustomColorRequested?()
    }
}
