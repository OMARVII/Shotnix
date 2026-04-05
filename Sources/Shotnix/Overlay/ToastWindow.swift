import AppKit

/// Lightweight floating toast notification that auto-dismisses.
/// Replaces modal NSAlert for non-blocking feedback (e.g. OCR result).
@MainActor
final class ToastWindow: NSWindow {

    private static var current: ToastWindow?

    static func show(message: String, duration: TimeInterval = 2.0) {
        // Dismiss any existing toast
        current?.orderOut(nil)

        let toast = ToastWindow(message: message)
        current = toast
        toast.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toast.animator().alphaValue = 1
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
        effect.layer?.masksToBounds = true
        contentView = effect

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: padding, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        effect.addSubview(label)

        // Position at top-center of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - width / 2
            let y = screen.visibleFrame.maxY - height - 40
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
