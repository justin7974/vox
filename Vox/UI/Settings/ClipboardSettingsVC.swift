import Cocoa

class ClipboardSettingsVC: NSObject {

    private let config = ConfigService.shared
    lazy var view: NSView = buildView()

    private var monitorSwitch: NSSwitch!
    private var maxItemsPopup: NSPopUpButton!
    private var countLabel: NSTextField!

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Clipboard History"))
        stack.addArrangedSubview(SettingsUI.makeSublabel(
            "Vox monitors your clipboard and keeps a history of copied text for quick pasting."
        ))

        monitorSwitch = NSSwitch()
        monitorSwitch.state = config.clipboardMonitoringEnabled ? .on : .off
        monitorSwitch.target = self
        monitorSwitch.action = #selector(monitorToggled)
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Enable Monitoring",
            sublabel: "Track clipboard changes in the background",
            control: monitorSwitch
        ))

        maxItemsPopup = NSPopUpButton()
        maxItemsPopup.addItems(withTitles: ["25 items", "50 items", "100 items", "200 items"])
        let maxValues = [25, 50, 100, 200]
        let current = config.clipboardMaxItems
        if let idx = maxValues.firstIndex(of: current) {
            maxItemsPopup.selectItem(at: idx)
        } else {
            maxItemsPopup.selectItem(at: 1)
        }
        maxItemsPopup.target = self
        maxItemsPopup.action = #selector(maxItemsChanged)
        maxItemsPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Maximum Items",
            control: maxItemsPopup
        ))

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // Stats
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Status"))

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        updateCountLabel()
        stack.addArrangedSubview(countLabel)

        let clearBtn = SettingsUI.makeButton("Clear Clipboard History")
        clearBtn.target = self
        clearBtn.action = #selector(clearHistory)
        stack.addArrangedSubview(clearBtn)

        return scroll
    }

    private func updateCountLabel() {
        let count = ClipboardService.shared.history.count
        countLabel.stringValue = "\(count) item\(count == 1 ? "" : "s") in clipboard history"
    }

    @objc private func monitorToggled() {
        let enabled = monitorSwitch.state == .on
        config.write(key: "clipboardMonitoringEnabled", value: enabled)
        if enabled {
            ClipboardService.shared.startMonitoring()
        } else {
            ClipboardService.shared.stopMonitoring()
        }
    }

    @objc private func maxItemsChanged() {
        let maxValues = [25, 50, 100, 200]
        let idx = maxItemsPopup.indexOfSelectedItem
        if idx >= 0 && idx < maxValues.count {
            let value = maxValues[idx]
            config.write(key: "clipboardMaxItems", value: value)
            ClipboardService.shared.setMaxItems(value)
        }
    }

    @objc private func clearHistory() {
        ClipboardService.shared.clearHistory()
        updateCountLabel()
    }
}
