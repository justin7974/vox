import Cocoa

/// Displays voice input history grouped by day, with a modern clean design,
/// SF Symbol icon buttons, dynamic row heights, and translation support.
class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow!
    private var tableView: NSTableView!
    private var records: [HistoryService.Record] = []
    private var displayItems: [DisplayItem] = []
    private var emptyLabel: NSTextField!
    private var countLabel: NSTextField!

    private let mainTextFont = NSFont.systemFont(ofSize: 13.5)
    private let origTextFont = NSFont.systemFont(ofSize: 12)

    // MARK: - Display Model

    private enum DisplayItem {
        case dayHeader(String)
        case record(index: Int, record: HistoryService.Record)
    }

    // MARK: - Show

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        records = HistoryService.shared.getRecords()
        buildDisplayItems()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Voice Input History"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 300)

        let root = window.contentView!

        // Toolbar: count + clear button
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        countLabel = NSTextField(labelWithString: countString())
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(countLabel)

        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(clearButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            countLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        // Table view
        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.title = ""
        tableView.addTableColumn(col)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Empty state
        emptyLabel = NSTextField(labelWithString: "No history records yet.\nStart using voice input to see records here.")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = !records.isEmpty
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build Display Items

    private func buildDisplayItems() {
        displayItems.removeAll()
        guard !records.isEmpty else { return }

        var currentDateKey = ""

        for (i, record) in records.enumerated() {
            let dateKey = dayKey(for: record.timestamp)
            if dateKey != currentDateKey {
                currentDateKey = dateKey
                displayItems.append(.dayHeader(dayLabel(for: record.timestamp)))
            }
            displayItems.append(.record(index: i, record: record))
        }
    }

    private func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: date)
    }

    private func countString() -> String {
        records.count == 1 ? "1 record" : "\(records.count) records"
    }

    // MARK: - Text Height Estimation

    private func textHeight(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let lineH = ceil(font.ascender - font.descender + font.leading)
        return min(ceil(rect.height), lineH * CGFloat(maxLines))
    }

    // MARK: - Actions

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all voice input history records."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            HistoryService.shared.clearAll()
            records.removeAll()
            buildDisplayItems()
            tableView.reloadData()
            countLabel.stringValue = "0 records"
            emptyLabel.isHidden = false
        }
    }

    @objc private func copyRecord(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < displayItems.count else { return }
        if case .record(_, let record) = displayItems[row] {
            let pb = NSPasteboard.general
            pb.clearContents()

            // For translations, copy both languages
            if record.translationMode, let orig = record.originalText, !orig.isEmpty {
                pb.setString("\(orig)\n\n\(record.text)", forType: .string)
            } else {
                pb.setString(record.text, forType: .string)
            }

            // Feedback: swap icon to checkmark briefly
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let origImage = sender.image
            let origTint = sender.contentTintColor
            sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(config)
            sender.contentTintColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                sender.image = origImage
                sender.contentTintColor = origTint
            }
        }
    }

    @objc private func deleteRecord(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < displayItems.count else { return }
        if case .record(let index, _) = displayItems[row] {
            HistoryService.shared.deleteRecord(at: index)
            records = HistoryService.shared.getRecords()
            buildDisplayItems()
            tableView.reloadData()
            countLabel.stringValue = countString()
            emptyLabel.isHidden = !records.isEmpty
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayItems.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch displayItems[row] {
        case .dayHeader:
            return 38
        case .record(_, let record):
            // Available width for text: table width minus time(55) + buttons(65) + padding(30)
            let w = max(tableView.bounds.width - 150, 260)
            let mainH = textHeight(record.text, font: mainTextFont, width: w, maxLines: 4)
            var total = 14 + mainH + 14 // top padding + text + bottom padding

            if record.translationMode, let orig = record.originalText, !orig.isEmpty {
                let origH = textHeight(orig, font: origTextFont, width: w, maxLines: 2)
                total += 4 + origH
            }

            return max(50, total)
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .dayHeader = displayItems[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch displayItems[row] {
        case .dayHeader(let label):
            return makeDayHeaderView(label: label)
        case .record(_, let record):
            return makeRecordView(record: record, row: row)
        }
    }

    // MARK: - Day Header View

    private func makeDayHeaderView(label: String) -> NSView {
        let v = NSView()

        let tf = NSTextField(labelWithString: label)
        tf.font = .systemFont(ofSize: 13, weight: .semibold)
        tf.textColor = .secondaryLabelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(tf)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(sep)

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            tf.bottomAnchor.constraint(equalTo: sep.topAnchor, constant: -4),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            sep.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        return v
    }

    // MARK: - Record View

    private func makeRecordView(record: HistoryService.Record, row: Int) -> NSView {
        let cell = HoverableRowView()
        cell.wantsLayer = true

        // Time label
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let timeLabel = NSTextField(labelWithString: timeFmt.string(from: record.timestamp))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(timeLabel)

        // Translation badge (between time and text)
        var badgeView: NSView?
        if record.translationMode {
            let badge = makeBadge()
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            badgeView = badge
        }

        // Main text (up to 4 lines with word wrapping)
        let textLabel = NSTextField(wrappingLabelWithString: record.text)
        textLabel.font = mainTextFont
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 4
        textLabel.isSelectable = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textLabel)

        // Original Chinese text (translation mode only, up to 2 lines)
        var origLabel: NSTextField?
        if record.translationMode, let orig = record.originalText, !orig.isEmpty {
            let ol = NSTextField(wrappingLabelWithString: orig)
            ol.font = origTextFont
            ol.textColor = .secondaryLabelColor
            ol.maximumNumberOfLines = 2
            ol.isSelectable = false
            ol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            ol.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(ol)
            origLabel = ol
        }

        // Hover buttons (appear on mouse enter)
        let btns = NSView()
        btns.translatesAutoresizingMaskIntoConstraints = false
        btns.isHidden = true
        cell.addSubview(btns)

        let copyBtn = makeIconButton(symbol: "doc.on.doc", action: #selector(copyRecord(_:)), tag: row)
        let delBtn = makeIconButton(symbol: "trash", action: #selector(deleteRecord(_:)), tag: row, tint: .systemRed)
        btns.addSubview(copyBtn)
        btns.addSubview(delBtn)

        // Bottom separator (aligned with text column)
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(sep)

        // Text leading: after badge if translation, otherwise after time
        let textLeading: NSLayoutXAxisAnchor
        if let badge = badgeView {
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 8),
                badge.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            ])
            textLeading = badge.trailingAnchor
        } else {
            textLeading = timeLabel.trailingAnchor
        }

        var constraints = [
            // Time
            timeLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            timeLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 16),
            timeLabel.widthAnchor.constraint(equalToConstant: 38),

            // Text
            textLabel.leadingAnchor.constraint(equalTo: textLeading, constant: 10),
            textLabel.trailingAnchor.constraint(equalTo: btns.leadingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),

            // Buttons container (top-right, fixed size)
            btns.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            btns.topAnchor.constraint(equalTo: cell.topAnchor, constant: 12),
            btns.widthAnchor.constraint(equalToConstant: 56),
            btns.heightAnchor.constraint(equalToConstant: 24),

            // Copy icon button
            copyBtn.leadingAnchor.constraint(equalTo: btns.leadingAnchor),
            copyBtn.centerYAnchor.constraint(equalTo: btns.centerYAnchor),
            copyBtn.widthAnchor.constraint(equalToConstant: 24),
            copyBtn.heightAnchor.constraint(equalToConstant: 24),

            // Delete icon button
            delBtn.leadingAnchor.constraint(equalTo: copyBtn.trailingAnchor, constant: 6),
            delBtn.centerYAnchor.constraint(equalTo: btns.centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 24),
            delBtn.heightAnchor.constraint(equalToConstant: 24),

            // Separator at bottom
            sep.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ]

        // Original text below main text (translation mode)
        if let ol = origLabel {
            constraints.append(contentsOf: [
                ol.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
                ol.trailingAnchor.constraint(equalTo: textLabel.trailingAnchor),
                ol.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 4),
            ])
        }

        NSLayoutConstraint.activate(constraints)
        cell.buttonsContainer = btns
        return cell
    }

    // MARK: - Helpers

    /// Creates an SF Symbol icon button (fixed 24x24, borderless)
    private func makeIconButton(symbol: String, action: Selector, tag: Int, tint: NSColor = .secondaryLabelColor) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.isBordered = false
        btn.tag = tag
        btn.target = self
        btn.action = action
        btn.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?.withSymbolConfiguration(config)
        btn.contentTintColor = tint
        btn.imagePosition = .imageOnly

        return btn
    }

    /// Creates a small blue "EN" badge for translation records
    private func makeBadge() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor

        let label = NSTextField(labelWithString: "EN")
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .systemBlue
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        // Let window be garbage collected
    }
}

// MARK: - HoverableRowView

/// A custom view that shows/hides buttons and a subtle highlight on mouse hover.
class HoverableRowView: NSView {
    var buttonsContainer: NSView?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        buttonsContainer?.isHidden = false
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        buttonsContainer?.isHidden = true
        layer?.backgroundColor = .clear
    }
}
