import AppKit
import QuartzCore

@MainActor
final class ToastWindow: NSWindow {

    private static var current: ToastWindow?
    private var finalOrigin: NSPoint = .zero

    static func show(message: String, duration: TimeInterval = 2.0) {
        current?.orderOut(nil)

        let toast = ToastWindow(message: message)
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

    private init(message: String) {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
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
        let height = Self.pixelAligned(max(42, labelHeight + paddingY * 2), scale: screenScale)
        let cornerRadius = min(18, height / 2)

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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.28
        container.layer?.shadowRadius = 18
        container.layer?.shadowOffset = CGSize(width: 0, height: -5)

        let clipView = NSView(frame: container.bounds)
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
        label.frame = NSRect(x: paddingX, y: (height - labelHeight) / 2, width: labelWidth, height: labelHeight)
        clipView.addSubview(label)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = max(visible.minX + horizontalInset, min(visible.midX - width / 2, visible.maxX - width - horizontalInset))
            let y = visible.maxY - height - 40
            finalOrigin = Self.pixelAligned(NSPoint(x: x, y: y), scale: screenScale)
            setFrameOrigin(finalOrigin)
        }
    }

    private static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    private static func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}
