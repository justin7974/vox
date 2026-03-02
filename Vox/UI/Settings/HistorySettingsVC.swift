import Cocoa

class HistorySettingsVC: NSObject {

    private let config = ConfigService.shared
    lazy var view: NSView = buildView()

    private var enabledSwitch: NSSwitch!
    private var retentionPopup: NSPopUpButton!
    private var countLabel: NSTextField!
    private var listStack: NSStackView!

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Transcription History"))

        enabledSwitch = NSSwitch()
        enabledSwitch.state = config.historyEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledToggled)
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Save History",
            sublabel: "Keep a log of your transcriptions",
            control: enabledSwitch
        ))

        retentionPopup = NSPopUpButton()
        retentionPopup.addItems(withTitles: ["1 day", "3 days", "7 days", "14 days", "30 days"])
        let retentionValues = [1, 3, 7, 14, 30]
        let current = config.historyRetentionDays
        if let idx = retentionValues.firstIndex(of: current) {
            retentionPopup.selectItem(at: idx)
        } else {
            retentionPopup.selectItem(at: 2) // default 7 days
        }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        retentionPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Keep History For",
            control: retentionPopup
        ))

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // Recent entries
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Recent Entries"))

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(countLabel)

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 6
        stack.addArrangedSubview(listStack)

        reloadEntries()

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 12

        let viewAllBtn = SettingsUI.makeButton("View All History")
        viewAllBtn.target = self
        viewAllBtn.action = #selector(viewAll)
        btnRow.addArrangedSubview(viewAllBtn)

        let clearBtn = SettingsUI.makeButton("Clear All History")
        clearBtn.target = self
        clearBtn.action = #selector(clearAll)
        btnRow.addArrangedSubview(clearBtn)

        stack.addArrangedSubview(btnRow)

        return scroll
    }

    private func reloadEntries() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let records = HistoryService.shared.getRecords()
        let total = records.count
        countLabel.stringValue = "\(total) total record\(total == 1 ? "" : "s")"

        let preview = Array(records.prefix(10))
        if preview.isEmpty {
            listStack.addArrangedSubview(SettingsUI.makeSublabel("No history yet"))
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for (index, record) in preview.enumerated() {
            let card = HistoryCardView(
                record: record,
                index: index,
                dateFormatter: dateFormatter,
                onCopy: { [weak self] idx in self?.copyRecord(at: idx) },
                onDelete: { [weak self] idx in self?.deleteRecord(at: idx) }
            )
            listStack.addArrangedSubview(card)
        }

        if total > 10 {
            listStack.addArrangedSubview(SettingsUI.makeSublabel("... and \(total - 10) more"))
        }
    }

    // MARK: - Record Actions

    private func copyRecord(at index: Int) {
        let records = HistoryService.shared.getRecords()
        guard index >= 0 && index < records.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records[index].text, forType: .string)
    }

    private func deleteRecord(at index: Int) {
        HistoryService.shared.deleteRecord(at: index)
        reloadEntries()
    }

    // MARK: - Actions

    @objc private func enabledToggled() {
        config.historyEnabled = enabledSwitch.state == .on
        HistoryService.shared.isEnabled = config.historyEnabled
    }

    @objc private func retentionChanged() {
        let values = [1, 3, 7, 14, 30]
        let idx = retentionPopup.indexOfSelectedItem
        if idx >= 0 && idx < values.count {
            config.historyRetentionDays = values[idx]
            HistoryService.shared.retentionDays = config.historyRetentionDays
        }
    }

    @objc private func viewAll() {
        // Use the dedicated history window
        if let app = NSApp.delegate as? AppDelegate {
            app.openHistoryWindow()
        }
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all transcription records."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            HistoryService.shared.clearAll()
            reloadEntries()
        }
    }
}

// MARK: - HistoryCardView (hover to reveal copy/delete buttons)

private class HistoryCardView: NSView {

    // Only one card shows hover buttons at a time
    private static weak var currentlyHovered: HistoryCardView?

    private let index: Int
    private let onCopy: (Int) -> Void
    private let onDelete: (Int) -> Void
    private var actionButtons: NSStackView!
    private var trackingArea: NSTrackingArea?

    init(record: HistoryService.Record, index: Int, dateFormatter: DateFormatter,
         onCopy: @escaping (Int) -> Void, onDelete: @escaping (Int) -> Void) {
        self.index = index
        self.onCopy = onCopy
        self.onDelete = onDelete
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        // Content stack
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.spacing = 2
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardStack)

        // Text label
        let truncated = String(record.text.prefix(120))
        let textLabel = SettingsUI.makeLabel(truncated + (record.text.count > 120 ? "..." : ""))
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 2
        cardStack.addArrangedSubview(textLabel)

        // Meta label
        var meta = dateFormatter.string(from: record.timestamp)
        if record.translationMode {
            meta += " • Translation"
        }
        let metaLabel = SettingsUI.makeSublabel(meta)
        metaLabel.font = .systemFont(ofSize: 10)
        cardStack.addArrangedSubview(metaLabel)

        // Hover action buttons (hidden by default)
        let copyBtn = makeIconButton(symbolName: "doc.on.doc", tooltip: "Copy")
        copyBtn.target = self
        copyBtn.action = #selector(copyTapped)

        let deleteBtn = makeIconButton(symbolName: "trash", tooltip: "Delete")
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteTapped)
        deleteBtn.contentTintColor = .systemRed

        actionButtons = NSStackView(views: [copyBtn, deleteBtn])
        actionButtons.orientation = .horizontal
        actionButtons.spacing = 2
        actionButtons.translatesAutoresizingMaskIntoConstraints = false
        actionButtons.isHidden = true
        addSubview(actionButtons)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cardStack.trailingAnchor.constraint(equalTo: actionButtons.leadingAnchor, constant: -8),

            actionButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButtons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Icon Button Factory

    private func makeIconButton(symbolName: String, tooltip: String) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            btn.image = img.withSymbolConfiguration(config)
        }
        btn.contentTintColor = .secondaryLabelColor
        btn.imagePosition = .imageOnly
        return btn
    }

    // MARK: - Tracking Area (hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        // Dismiss previous card's buttons (single-selection guarantee)
        if let prev = HistoryCardView.currentlyHovered, prev !== self {
            prev.dismissHover()
        }
        HistoryCardView.currentlyHovered = self
        actionButtons.isHidden = false
        layer?.backgroundColor = NSColor.controlBackgroundColor.blended(
            withFraction: 0.05, of: .labelColor
        )?.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        dismissHover()
        if HistoryCardView.currentlyHovered === self {
            HistoryCardView.currentlyHovered = nil
        }
    }

    private func dismissHover() {
        actionButtons.isHidden = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    // MARK: - Actions

    @objc private func copyTapped() {
        onCopy(index)
    }

    @objc private func deleteTapped() {
        onDelete(index)
    }
}
