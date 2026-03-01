import Cocoa

/// Base class for Spotlight-style floating panels.
/// Shared by LauncherPanel and ClipboardPanel.
/// Key traits: non-activating (doesn't steal focus), HUD blur background,
/// positions on the screen where the mouse cursor is.
class FloatingPanel: NSPanel {
    let blurView = NSVisualEffectView()
    let contentBox = NSView()

    init(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 16) {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Build content
        let wrapper = NSView(frame: frame)
        wrapper.wantsLayer = true

        // Blur background
        blurView.frame = wrapper.bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = cornerRadius
        blurView.layer?.masksToBounds = true
        wrapper.addSubview(blurView)

        // Shadow
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 20
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        wrapper.shadow = shadow

        // Content container
        contentBox.frame = wrapper.bounds
        contentBox.autoresizingMask = [.width, .height]
        wrapper.addSubview(contentBox)

        contentView = wrapper
    }

    // MARK: - Positioning

    /// Position the panel at the upper 1/3 of the screen containing the mouse cursor.
    func positionOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }

        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.origin.y + screenFrame.height * 2 / 3 - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Show / Hide with animation

    func showAnimated() {
        positionOnScreen()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
    }

    func hideAnimated(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }

    // MARK: - Resize

    func resizeTo(height: CGFloat) {
        let currentOrigin = frame.origin
        let heightDelta = height - frame.height
        let newFrame = NSRect(
            x: currentOrigin.x,
            y: currentOrigin.y - heightDelta,  // grow upward
            width: frame.width,
            height: height
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }
    }
}
