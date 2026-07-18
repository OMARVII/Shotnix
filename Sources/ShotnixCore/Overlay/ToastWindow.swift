import AppKit
import QuartzCore

@MainActor
final class ToastWindow: NSWindow {

    private static var current: ToastWindow?
    private var finalOrigin: NSPoint = .zero

    /// - Parameters:
    ///   - anchorView: when set, the toast points at this view (wins over `screen`).
    ///   - screen: non-anchored toasts appear on this screen instead of `NSScreen.main`
    ///     — pass the capture screen so feedback shows where the user is looking.
    ///   - action: when set, the toast becomes clickable and runs this on click.
    static func show(message: String, duration: TimeInterval = 2.0, anchorView: NSView? = nil, on screen: NSScreen? = nil, action: (() -> Void)? = nil) {
        current?.orderOut(nil)

        let toast = ToastWindow(message: message, anchorView: anchorView, screen: screen, action: action)
        current = toast

        // Start 12px below final position, scaled down
        toast.setFrameOrigin(NSPoint(x: toast.finalOrigin.x, y: toast.finalOrigin.y - 12))
        toast.alphaValue = 0
        if let layer = toast.contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        }
        toast.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 1
            toast.animator().setFrameOrigin(toast.finalOrigin)
        }

        if let layer = toast.contentView?.layer {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92
            spring.toValue = 1.0
            spring.mass = 1.0
            spring.stiffness = 200
            spring.damping = 12
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak toast] in
            guard let toast else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                toast.animator().alphaValue = 0
            }, completionHandler: { [weak toast] in
                DispatchQueue.main.async {
                    toast?.orderOut(nil)
                    if ToastWindow.current === toast { ToastWindow.current = nil }
                }
            })
        }
    }

    private init(message: String, anchorView: NSView?, screen: NSScreen?, action: (() -> Void)?) {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let targetScreen = screen ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let screenScale = targetScreen?.backingScaleFactor ?? 2
        let horizontalInset: CGFloat = 40
        let paddingX: CGFloat = 28
        let paddingY: CGFloat = 12
        let textSafety: CGFloat = 34
        let maxWidth = min(760, max(320, screenFrame.width - horizontalInset * 2))
        let maxTextWidth = maxWidth - paddingX * 2
        let singleLineWidth = ceil((message as NSString).size(withAttributes: attrs).width)
        let targetTextWidth = min(singleLineWidth + textSafety, maxTextWidth)
        let textRect = (message as NSString).boundingRect(
            with: NSSize(width: targetTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let width = Self.pixelAligned(min(maxWidth, max(280, ceil(targetTextWidth) + paddingX * 2)), scale: screenScale)
        let labelWidth = Self.pixelAligned(width - paddingX * 2, scale: screenScale)
        let labelHeight = ceil(textRect.height)
        let bubbleHeight = Self.pixelAligned(max(42, labelHeight + paddingY * 2), scale: screenScale)
        let pointerHeight: CGFloat = anchorView == nil ? 0 : 9
        let height = bubbleHeight + pointerHeight
        let cornerRadius = min(18, bubbleHeight / 2)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        alphaValue = 0
        ignoresMouseEvents = true

        let container = ToastClickCatcherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.28
        container.layer?.shadowRadius = 18
        container.layer?.shadowOffset = CGSize(width: 0, height: -5)

        let pointer: ToastPointerView?
        if anchorView != nil {
            let view = ToastPointerView(frame: NSRect(x: width / 2 - 10, y: bubbleHeight - 1, width: 20, height: pointerHeight + 1))
            container.addSubview(view)
            pointer = view
        } else {
            pointer = nil
        }

        let clipView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: bubbleHeight))
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        container.addSubview(clipView)

        let effect = NSVisualEffectView(frame: clipView.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        clipView.addSubview(effect)

        contentView = container

        let label = NSTextField(wrappingLabelWithString: message)
        label.attributedStringValue = NSAttributedString(string: message, attributes: attrs)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byCharWrapping
        label.frame = NSRect(x: paddingX, y: (bubbleHeight - labelHeight) / 2, width: labelWidth, height: labelHeight)
        clipView.addSubview(label)

        // Clickable toasts (e.g. "click to reveal in Finder") accept mouse events;
        // plain toasts stay fully click-through.
        if let action {
            ignoresMouseEvents = false
            container.onClick = { [weak self, weak container] in
                container?.onClick = nil // fire at most once
                action()
                self?.dismissNow()
            }
        }

        if let anchorFrame = Self.screenFrame(for: anchorView), let screen = Self.screen(containing: anchorFrame) {
            let visible = screen.visibleFrame
            let x = max(visible.minX + 8, min(anchorFrame.midX - width / 2, visible.maxX - width - 8))
            let y = min(anchorFrame.minY - height + 13, visible.maxY - height - 4)
            finalOrigin = Self.pixelAligned(NSPoint(x: x, y: y), scale: screenScale)
            pointer?.frame.origin.x = Self.pixelAligned(max(14, min(anchorFrame.midX - finalOrigin.x - 10, width - 34)), scale: screenScale)
            setFrameOrigin(finalOrigin)
        } else if let screen = targetScreen {
            let visible = screen.visibleFrame
            let x = max(visible.minX + horizontalInset, min(visible.midX - width / 2, visible.maxX - width - horizontalInset))
            let y = visible.maxY - height - 40
            finalOrigin = Self.pixelAligned(NSPoint(x: x, y: y), scale: screenScale)
            setFrameOrigin(finalOrigin)
        }
    }

    /// Immediate fade-out after a click — the scheduled auto-dismiss becomes a no-op.
    private func dismissNow() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.orderOut(nil)
                if ToastWindow.current === self { ToastWindow.current = nil }
            }
        })
    }

    private static func screenFrame(for view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }

    private static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    private static func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}

/// Container view that turns the whole toast into a single click target when
/// an action is attached. First click lands even while the app is inactive
/// (LSUIElement apps are background processes most of the time).
@MainActor
private final class ToastClickCatcherView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        // Swallow subview hits (label, effect view) so the click always reaches us
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}

private final class ToastPointerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()

        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.minX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        path.close()
        path.fill()
    }
}

// MARK: – Capture-screen lookup (shared by overlay/pin/toast placement)

extension NSScreen {
    /// The screen whose frame overlaps the given rect the most, or nil when the
    /// rect touches no screen (e.g. a display was disconnected since capture).
    /// The rect is expected in AppKit screen coordinates (bottom-left origin) —
    /// the space `HistoryItem.captureRect` is stored in. Callers should fall
    /// back to `NSScreen.main` on nil so post-capture UI always appears somewhere.
    @MainActor
    static func screenContaining(rect: NSRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen
    }
}
