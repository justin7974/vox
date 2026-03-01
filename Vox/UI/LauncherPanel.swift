import Cocoa
import QuartzCore

/// Spotlight-style floating panel for Launcher mode.
/// Shows recording state, transcription, matched action, and execution result.
class LauncherPanel {
    private var panel: FloatingPanel?

    // UI elements
    private var dotView: LauncherDotView?
    private var statusLabel: NSTextField?
    private var transcriptionLabel: NSTextField?
    private var actionIcon: NSTextField?
    private var actionLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var penLabel: NSTextField?

    // Design tokens
    private static let panelWidth: CGFloat = 480
    private static let minHeight: CGFloat = 64
    private static let maxHeight: CGFloat = 160
    private static let hPadding: CGFloat = 20
    private static let vPadding: CGFloat = 16
    private static let lineSpacing: CGFloat = 8

    private static let terracotta = NSColor(red: 0xd4/255, green: 0x71/255, blue: 0x6a/255, alpha: 1.0)
    private static let fern = NSColor(red: 0x5f/255, green: 0xbc/255, blue: 0x82/255, alpha: 1.0)
    private static let amber = NSColor(red: 0xd4/255, green: 0xa0/255, blue: 0x4e/255, alpha: 1.0)
    private static let slateBlue = NSColor(red: 0x5a/255, green: 0x98/255, blue: 0xd0/255, alpha: 1.0)

    // MARK: - Public API

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.showAnimated()
    }

    func hide() {
        panel?.hideAnimated()
    }

    func showRecording() {
        ensurePanel()
        resetContent()

        dotView?.isHidden = false
        dotView?.setColor(LauncherPanel.terracotta)
        dotView?.startPulse()
        penLabel?.isHidden = true
        statusLabel?.stringValue = "正在聆听…"
        statusLabel?.textColor = .labelColor
        statusLabel?.isHidden = false

        panel?.resizeTo(height: LauncherPanel.minHeight)
    }

    func showProcessing() {
        ensurePanel()

        dotView?.stopPulse()
        dotView?.isHidden = true
        penLabel?.isHidden = false
        startWritingAnimation()
        statusLabel?.stringValue = "识别中…"
        statusLabel?.textColor = .labelColor
    }

    func showTranscription(_ text: String) {
        ensurePanel()
        resetContent()

        transcriptionLabel?.stringValue = "\"\(text)\""
        transcriptionLabel?.isHidden = false

        // Show "匹配中…" in the action row (below transcription) to avoid overlap with statusLabel
        actionIcon?.stringValue = "●"
        actionIcon?.textColor = .tertiaryLabelColor
        actionIcon?.isHidden = false
        actionLabel?.stringValue = "匹配中…"
        actionLabel?.textColor = .secondaryLabelColor
        actionLabel?.isHidden = false

        panel?.resizeTo(height: 96)
    }

    func showExecuting(action: ActionDefinition) {
        ensurePanel()

        actionIcon?.stringValue = "▶"
        actionIcon?.textColor = LauncherPanel.fern
        actionIcon?.isHidden = false
        actionLabel?.stringValue = action.name
        actionLabel?.textColor = .labelColor
        actionLabel?.isHidden = false
        statusLabel?.isHidden = true

        panel?.resizeTo(height: 120)
    }

    func showResult(_ result: ActionResult) {
        ensurePanel()
        resetContent()

        if result.success {
            actionIcon?.stringValue = "✓"
            actionIcon?.textColor = LauncherPanel.fern
            actionLabel?.stringValue = result.message
            actionLabel?.textColor = .labelColor
        } else {
            actionIcon?.stringValue = "—"
            actionIcon?.textColor = LauncherPanel.amber
            actionLabel?.stringValue = result.message
            actionLabel?.textColor = LauncherPanel.amber
        }
        actionIcon?.isHidden = false
        actionLabel?.isHidden = false

        panel?.resizeTo(height: 80)
    }

    func showQuickAnswer(answer: String) {
        ensurePanel()
        resetContent()

        actionIcon?.stringValue = "●"
        actionIcon?.textColor = LauncherPanel.slateBlue
        actionIcon?.isHidden = false
        actionLabel?.stringValue = answer
        actionLabel?.textColor = .labelColor
        actionLabel?.lineBreakMode = .byWordWrapping
        actionLabel?.maximumNumberOfLines = 4
        actionLabel?.isHidden = false

        let lineCount = min(4, max(1, answer.count / 30 + 1))
        let height = CGFloat(60 + lineCount * 20)
        panel?.resizeTo(height: min(height, LauncherPanel.maxHeight))
    }

    func showNoMatch(originalText: String) {
        ensurePanel()
        resetContent()

        transcriptionLabel?.stringValue = "\"\(originalText)\""
        transcriptionLabel?.isHidden = false

        actionIcon?.stringValue = "—"
        actionIcon?.textColor = LauncherPanel.amber
        actionIcon?.isHidden = false
        actionLabel?.stringValue = "未找到匹配的操作"
        actionLabel?.textColor = LauncherPanel.amber
        actionLabel?.isHidden = false

        detailLabel?.stringValue = "Enter → Spotlight 搜索 | 按住热键重试"
        detailLabel?.textColor = .tertiaryLabelColor
        detailLabel?.isHidden = false

        panel?.resizeTo(height: LauncherPanel.maxHeight)
    }

    func showError(_ error: Error) {
        ensurePanel()
        resetContent()

        actionIcon?.stringValue = "—"
        actionIcon?.textColor = LauncherPanel.amber
        actionIcon?.isHidden = false
        actionLabel?.stringValue = error.localizedDescription
        actionLabel?.textColor = LauncherPanel.amber
        actionLabel?.isHidden = false

        panel?.resizeTo(height: 80)
    }

    // MARK: - Setup

    private func ensurePanel() {
        if panel == nil { createPanel() }
    }

    private func createPanel() {
        let p = FloatingPanel(
            width: LauncherPanel.panelWidth,
            height: LauncherPanel.minHeight,
            cornerRadius: 16
        )
        panel = p

        let box = p.contentBox
        let hp = LauncherPanel.hPadding
        let vp = LauncherPanel.vPadding

        // Dot view (recording indicator)
        let dot = LauncherDotView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        box.addSubview(dot)
        dotView = dot

        // Pen label (processing indicator)
        let pen = makeLabel(fontSize: 11, weight: .regular)
        pen.stringValue = "✏️"
        pen.alignment = .center
        pen.isHidden = true
        box.addSubview(pen)
        penLabel = pen

        // Status label ("正在聆听…", "识别中…", etc.)
        let status = makeLabel(fontSize: 16, weight: .medium)
        status.textColor = .labelColor
        status.isHidden = true
        box.addSubview(status)
        statusLabel = status

        // Transcription label (user's spoken text)
        let trans = makeLabel(fontSize: 16, weight: .medium)
        trans.textColor = .labelColor
        trans.isHidden = true
        box.addSubview(trans)
        transcriptionLabel = trans

        // Action icon ("▶", "✓", "—")
        let icon = makeLabel(fontSize: 16, weight: .medium)
        icon.isHidden = true
        box.addSubview(icon)
        actionIcon = icon

        // Action label (action name or result message)
        let action = makeLabel(fontSize: 16, weight: .medium)
        action.isHidden = true
        box.addSubview(action)
        actionLabel = action

        // Detail label (parameter preview or helper text)
        let detail = makeLabel(fontSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.isHidden = true
        box.addSubview(detail)
        detailLabel = detail

        // Layout
        NSLayoutConstraint.activate([
            // Dot
            dot.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: hp),
            dot.centerYAnchor.constraint(equalTo: box.topAnchor, constant: LauncherPanel.minHeight / 2),
            dot.widthAnchor.constraint(equalToConstant: 24),
            dot.heightAnchor.constraint(equalToConstant: 24),

            // Pen centered over dot position
            pen.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            pen.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            // Status label (next to dot)
            status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -hp),

            // Transcription (top line)
            trans.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: hp),
            trans.topAnchor.constraint(equalTo: box.topAnchor, constant: vp),
            trans.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -hp),

            // Action icon
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: hp),
            icon.topAnchor.constraint(equalTo: trans.bottomAnchor, constant: LauncherPanel.lineSpacing + 4),

            // Action label (next to icon)
            action.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            action.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            action.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -hp),

            // Detail label (below action)
            detail.leadingAnchor.constraint(equalTo: action.leadingAnchor),
            detail.topAnchor.constraint(equalTo: action.bottomAnchor, constant: 4),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -hp),
        ])
    }

    private func makeLabel(fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.isBordered = false
        label.isEditable = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func resetContent() {
        dotView?.isHidden = true
        dotView?.stopPulse()
        penLabel?.isHidden = true
        penLabel?.layer?.removeAllAnimations()
        statusLabel?.isHidden = true
        transcriptionLabel?.isHidden = true
        actionIcon?.isHidden = true
        actionLabel?.isHidden = true
        detailLabel?.isHidden = true
    }

    // MARK: - Animations

    private func startWritingAnimation() {
        guard let layer = penLabel?.layer else { return }

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

// MARK: - LauncherDotView (Reusable dot indicator)

private class LauncherDotView: NSView {
    private let dotLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private static let baseSize: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        glowLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
        layer?.addSublayer(glowLayer)

        dotLayer.fillColor = NSColor.systemRed.cgColor
        layer?.addSublayer(dotLayer)

        updatePaths()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setColor(_ color: NSColor) {
        dotLayer.fillColor = color.cgColor
        glowLayer.fillColor = color.withAlphaComponent(0.25).cgColor
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

    private func updatePaths() {
        let size = LauncherDotView.baseSize
        let glowSize = size + 4
        let dotRect = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size, height: size
        )
        dotLayer.path = CGPath(ellipseIn: dotRect, transform: nil)

        let glowRect = CGRect(
            x: (bounds.width - glowSize) / 2,
            y: (bounds.height - glowSize) / 2,
            width: glowSize, height: glowSize
        )
        glowLayer.path = CGPath(ellipseIn: glowRect, transform: nil)
    }
}
