import Cocoa

class AudioLevelView: NSView {
    private var barLayers: [CALayer] = []
    private var levels: [CGFloat] = []
    private let barCount = 30
    private let barSpacing: CGFloat = 2.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        levels = Array(repeating: 0, count: barCount)
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.controlAccentColor.cgColor
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        redrawBars()
    }

    func updateLevel(_ level: Float) {
        levels.removeFirst()
        let normalized = CGFloat(max(0, min(1, (level + 50) / 40)))
        levels.append(normalized)
        redrawBars()
    }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        redrawBars()
    }

    private func redrawBars() {
        guard bounds.width > 0 else { return }
        let totalSpacing = barSpacing * CGFloat(barCount - 1)
        let barWidth = max(2, (bounds.width - totalSpacing) / CGFloat(barCount))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let level = levels[i]
            let minH: CGFloat = 3
            let h = max(minH, level * bounds.height)
            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - h) / 2

            bar.frame = CGRect(x: x, y: y, width: barWidth, height: h)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(max(0.3, level)).cgColor
        }
        CATransaction.commit()
    }
}
