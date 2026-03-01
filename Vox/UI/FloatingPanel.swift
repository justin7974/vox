import Cocoa

/// Base class for Spotlight-style floating panels.
/// Shared by LauncherPanel and ClipboardPanel.
/// Key traits: non-activating (doesn't steal focus), HUD blur background,
/// positions on the screen where the mouse cursor is.
class FloatingPanel: NSPanel {
    let blurView = NSVisualEffectView()
    let contentBox = NSView()
    private let panelCornerRadius: CGFloat

    init(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 16) {
        self.panelCornerRadius = cornerRadius
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

        // Wrapper (shadow carrier)
        let wrapper = NSView(frame: frame)
        wrapper.wantsLayer = true

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 20
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        wrapper.shadow = shadow

        // Blur background — use maskImage for proper rounded corners.
        // NSVisualEffectView renders at the window compositor level so
        // CALayer.masksToBounds does NOT clip it. maskImage is the only
        // reliable approach on macOS.
        blurView.frame = wrapper.bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.maskImage = Self.roundedMask(radius: cornerRadius)
        wrapper.addSubview(blurView)

        // Content container (on top of blur, also clipped)
        contentBox.frame = wrapper.bounds
        contentBox.autoresizingMask = [.width, .height]
        contentBox.wantsLayer = true
        contentBox.layer?.cornerRadius = cornerRadius
        contentBox.layer?.cornerCurve = .continuous
        contentBox.layer?.masksToBounds = true
        wrapper.addSubview(contentBox)

        contentView = wrapper
    }

    // MARK: - Rounded Mask

    /// Creates a stretchable mask image for NSVisualEffectView.
    /// capInsets + resizingMode ensure the corners stay rounded as the view resizes.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1  // minimal size: 2 corners + 1px stretch
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius
        )
        image.resizingMode = .stretch
        return image
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
