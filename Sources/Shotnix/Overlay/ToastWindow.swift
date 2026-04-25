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
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (message as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 24
        let width = textSize.width + padding * 2
        let height: CGFloat = 36

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

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = height / 2
        effect.layer?.masksToBounds = false

        effect.layer?.shadowColor = NSColor.black.cgColor
        effect.layer?.shadowOpacity = 0.2
        effect.layer?.shadowRadius = 12
        effect.layer?.shadowOffset = CGSize(width: 0, height: -3)

        let clipView = NSView(frame: effect.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = height / 2
        clipView.layer?.masksToBounds = true
        effect.addSubview(clipView)

        contentView = effect

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: padding, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        clipView.addSubview(label)

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - width / 2
            let y = screen.visibleFrame.maxY - height - 40
            finalOrigin = NSPoint(x: x, y: y)
            setFrameOrigin(finalOrigin)
        }
    }
}
