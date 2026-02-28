import Cocoa
import QuartzCore

/// Floating status overlay at the bottom-center of the screen.
/// Shows recording / processing state with animation.
class StatusOverlay {
    private var window: NSWindow?
    private var contentView: OverlayContentView?

    func show(state: AppState) {
        if state == .idle {
            hide()
            return
        }

        if window == nil {
            createWindow()
        }

        guard let contentView = contentView, let window = window else { return }

        switch state {
        case .recording:
            contentView.showRecording(text: "正在聆听…")
        case .processing:
            contentView.showProcessing(text: "奋笔疾书…")
        case .idle:
            break
        }

        positionWindow(window)

        // If window is already visible (e.g. recording → processing), just update content
        let alreadyVisible = window.isVisible && window.alphaValue > 0.5
        if alreadyVisible {
            window.alphaValue = 1.0
        } else {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                window.animator().alphaValue = 1.0
            }
        }
    }

    /// Update the recording dot size based on audio level (dB)
    func updateAudioLevel(_ level: Float) {
        // Map dB: -50 → 0.0, -10 → 1.0
        let normalized = max(0.0, min(1.0, (level + 50.0) / 40.0))
        let scale = 0.75 + CGFloat(normalized) * 0.75  // 0.75x to 1.5x
        contentView?.setDotScale(scale)
    }

    func hide() {
        guard let window = window else { return }
        contentView?.stopAllAnimations()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        })
    }

    // MARK: - Window Setup

    private func createWindow() {
        let view = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 160, height: 48))
        contentView = view

        let w = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.contentView = view
        window = w
    }

    private func positionWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        let y = screenFrame.origin.y + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Overlay Content View

private class OverlayContentView: NSView {
    private let blurView = NSVisualEffectView()
    private let textLabel = NSTextField(labelWithString: "")
    private let dotView = DotView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private let penLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Blur background
        blurView.frame = bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 12
        blurView.layer?.masksToBounds = true
        addSubview(blurView)

        // Dot view (unified indicator for both states)
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // Pen label (overlaid on dot during processing)
        penLabel.font = .systemFont(ofSize: 11)
        penLabel.alignment = .center
        penLabel.translatesAutoresizingMaskIntoConstraints = false
        penLabel.stringValue = "✏️"
        penLabel.isBordered = false
        penLabel.isEditable = false
        penLabel.backgroundColor = .clear
        penLabel.wantsLayer = true
        penLabel.isHidden = true
        addSubview(penLabel)

        // Text label
        textLabel.font = .systemFont(ofSize: 14, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 24),
            dotView.heightAnchor.constraint(equalToConstant: 24),

            // Pen centered over the dot
            penLabel.centerXAnchor.constraint(equalTo: dotView.centerXAnchor),
            penLabel.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),

            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showRecording(text: String) {
        stopAllAnimations()
        dotView.isHidden = false
        dotView.setColor(.systemRed)
        dotView.reset()
        penLabel.isHidden = true
        textLabel.stringValue = text
        alphaValue = 1.0
    }

    func showProcessing(text: String) {
        stopAllAnimations()
        dotView.isHidden = true
        penLabel.isHidden = false
        startWritingAnimation()
        textLabel.stringValue = text
        alphaValue = 1.0
    }

    func setDotScale(_ scale: CGFloat) {
        dotView.setScale(scale)
    }

    func stopAllAnimations() {
        dotView.stopPulse()
        penLabel.layer?.removeAllAnimations()
    }

    private func startWritingAnimation() {
        guard let layer = penLabel.layer else { return }

        let horizAnim = CABasicAnimation(keyPath: "transform.translation.x")
        horizAnim.fromValue = -3
        horizAnim.toValue = 3
        horizAnim.duration = 0.25
        horizAnim.autoreverses = true
        horizAnim.repeatCount = .infinity
        horizAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let vertAnim = CABasicAnimation(keyPath: "transform.translation.y")
        vertAnim.fromValue = -0.4
        vertAnim.toValue = 0.4
        vertAnim.duration = 0.125
        vertAnim.autoreverses = true
        vertAnim.repeatCount = .infinity
        vertAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        layer.add(horizAnim, forKey: "writing-x")
        layer.add(vertAnim, forKey: "writing-y")
    }
}

// MARK: - Unified Dot Indicator

private class DotView: NSView {
    private let dotLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private static let baseSize: CGFloat = 10
    private var currentColor: NSColor = .systemRed

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        glowLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        layer?.addSublayer(glowLayer)

        dotLayer.fillColor = NSColor.systemRed.cgColor
        layer?.addSublayer(dotLayer)

        updatePaths(scale: 1.0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ color: NSColor) {
        currentColor = color
        dotLayer.fillColor = color.cgColor
        glowLayer.fillColor = color.withAlphaComponent(0.25).cgColor
    }

    func reset() {
        stopPulse()
        updatePaths(scale: 1.0)
    }

    func setScale(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        updatePaths(scale: scale)
        CATransaction.commit()
    }

    func startPulse() {
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.85
        anim.toValue = 1.15
        anim.duration = 0.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(anim, forKey: "pulse")
        glowLayer.add(anim, forKey: "pulse")
    }

    func stopPulse() {
        dotLayer.removeAnimation(forKey: "pulse")
        glowLayer.removeAnimation(forKey: "pulse")
    }

    private func updatePaths(scale: CGFloat) {
        let size = DotView.baseSize * scale
        let glowSize = size + 4

        let dotRect = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        dotLayer.path = CGPath(ellipseIn: dotRect, transform: nil)

        let glowRect = CGRect(
            x: (bounds.width - glowSize) / 2,
            y: (bounds.height - glowSize) / 2,
            width: glowSize,
            height: glowSize
        )
        glowLayer.path = CGPath(ellipseIn: glowRect, transform: nil)

        glowLayer.opacity = Float(min(1.0, scale * 0.6))
    }
}
