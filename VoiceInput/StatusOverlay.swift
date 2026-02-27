import Cocoa
import QuartzCore

/// Floating status overlay at the bottom-center of the screen.
/// Shows recording / processing state with animation.
class StatusOverlay {
    private var window: NSWindow?
    private var contentView: OverlayContentView?
    private var pulseTimer: Timer?

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
            contentView.configure(icon: "●", text: "正在录音…", color: .systemRed)
            startPulse()
        case .processing:
            contentView.configure(icon: "◌", text: "正在处理…", color: .systemOrange)
            stopPulse()
            startSpin()
        case .idle:
            break
        }

        positionWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1.0
        }
    }

    func hide() {
        stopPulse()
        guard let window = window else { return }
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
        let y = screenFrame.origin.y + 80  // 80pt above bottom
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Animations

    private func startPulse() {
        pulseTimer?.invalidate()
        var bright = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let contentView = self?.contentView else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                contentView.animator().alphaValue = bright ? 0.6 : 1.0
            }
            bright.toggle()
        }
    }

    private func startSpin() {
        // Simple text-based rotation of processing icon
        let frames = ["◐", "◓", "◑", "◒"]
        var i = 0
        pulseTimer?.invalidate()
        contentView?.alphaValue = 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.contentView?.updateIcon(frames[i % frames.count])
            i += 1
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        contentView?.alphaValue = 1.0
    }
}

// MARK: - Overlay View

private class OverlayContentView: NSView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let blurView = NSVisualEffectView()

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

        // Icon
        iconLabel.font = .systemFont(ofSize: 16)
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)

        // Text
        textLabel.font = .systemFont(ofSize: 14, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            textLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: String, text: String, color: NSColor) {
        iconLabel.stringValue = icon
        iconLabel.textColor = color
        textLabel.stringValue = text
    }

    func updateIcon(_ icon: String) {
        iconLabel.stringValue = icon
    }
}
