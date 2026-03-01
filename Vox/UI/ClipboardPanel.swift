import Cocoa

protocol ClipboardPanelDelegate: AnyObject {
    func clipboardPanelDidSelectItem(_ item: ClipboardItem)
    func clipboardPanelDidDismiss()
}

/// Alfred-style clipboard history panel with left-right split layout.
/// Left column: 9 items per page with numbered shortcuts.
/// Right column: full preview of selected item + metadata.
class ClipboardPanel {
    weak var delegate: ClipboardPanelDelegate?

    private var panel: FloatingPanel?
    private var items: [ClipboardItem] = []
    private var currentPage = 0
    private var selectedIndex = 0
    private let itemsPerPage = 9
    private var previousApp: NSRunningApplication?

    // Left column
    private var rowViews: [ClipboardRowView] = []
    private var titleLabel: NSTextField?
    private var pageLabel: NSTextField?
    private var hintLabel: NSTextField?

    // Right column
    private var previewScrollView: NSScrollView?
    private var previewTextView: NSTextView?
    private var metadataLabel: NSTextField?

    // Key monitors
    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Design tokens
    private static let panelWidth: CGFloat = 680
    private static let panelHeight: CGFloat = 420
    private static let leftWidth: CGFloat = 320
    private static let rowHeight: CGFloat = 36
    private static let headerHeight: CGFloat = 36
    private static let leftPadding: CGFloat = 8
    private static let rightPadding: CGFloat = 16
    private static let numberWidth: CGFloat = 20

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Public API

    func show(items: [ClipboardItem]) {
        self.items = items
        currentPage = 0
        selectedIndex = 0
        previousApp = NSWorkspace.shared.frontmostApplication

        if panel == nil { createPanel() }

        updateContent()
        updateSelection()
        panel?.showAnimated()

        // Activate app to receive key events via local monitor
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
        installKeyMonitors()
    }

    func hide() {
        removeKeyMonitors()
        panel?.hideAnimated()

        // Restore previous app focus
        if let app = previousApp {
            app.activate()
            previousApp = nil
        }
        delegate?.clipboardPanelDidDismiss()
    }

    // MARK: - Key Handling

    private func installKeyMonitors() {
        removeKeyMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        // Fallback global monitor (can observe but not consume)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            _ = self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: moveSelection(by: -1); return true   // ↑
        case 125: moveSelection(by: 1); return true    // ↓
        case 123: changePage(by: -1); return true      // ←
        case 124: changePage(by: 1); return true       // →
        case 36:  pasteSelected(); return true          // Enter
        case 53:  hide(); return true                   // Esc
        default:
            if let chars = event.charactersIgnoringModifiers,
               let num = Int(chars), num >= 1, num <= 9 {
                pasteAtIndex(num - 1)
                return true
            }
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        let count = currentPageItems().count
        guard count > 0 else { return }
        let newIndex = selectedIndex + delta
        guard newIndex >= 0, newIndex < count else { return }
        selectedIndex = newIndex
        updateSelection()
    }

    private func changePage(by delta: Int) {
        let newPage = currentPage + delta
        guard newPage >= 0, newPage < totalPages else { return }
        currentPage = newPage
        selectedIndex = 0
        updateContent()
        updateSelection()
    }

    private func pasteSelected() {
        pasteAtIndex(selectedIndex)
    }

    private func pasteAtIndex(_ pageIndex: Int) {
        let globalIndex = currentPage * itemsPerPage + pageIndex
        guard globalIndex < items.count else { return }
        delegate?.clipboardPanelDidSelectItem(items[globalIndex])
        hide()
    }

    // MARK: - Data

    private func currentPageItems() -> [ClipboardItem] {
        let start = currentPage * itemsPerPage
        let end = min(start + itemsPerPage, items.count)
        guard start < items.count else { return [] }
        return Array(items[start..<end])
    }

    private var totalPages: Int {
        max(1, (items.count + itemsPerPage - 1) / itemsPerPage)
    }

    // MARK: - UI Updates

    private func updateContent() {
        let pageItems = currentPageItems()

        for (i, row) in rowViews.enumerated() {
            if i < pageItems.count {
                row.configure(number: i + 1, text: pageItems[i].text)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }

        pageLabel?.stringValue = "\(currentPage + 1) / \(totalPages)"
    }

    private func updateSelection() {
        let pageItems = currentPageItems()

        for (i, row) in rowViews.enumerated() {
            row.setSelected(i == selectedIndex)
        }

        if selectedIndex < pageItems.count {
            updatePreview(pageItems[selectedIndex])
        } else {
            previewTextView?.string = ""
            metadataLabel?.stringValue = ""
        }
    }

    private func updatePreview(_ item: ClipboardItem) {
        let isCode = looksLikeCode(item.text)
        previewTextView?.font = isCode
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 14)
        previewTextView?.string = item.text
        previewTextView?.textColor = NSColor.labelColor.withAlphaComponent(0.8)

        var meta = "复制于 \(formatTime(item.timestamp))"
        if let app = item.sourceApp { meta += "\n来自 \(app)" }
        metadataLabel?.stringValue = meta
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let indicators = ["{", "}", "func ", "import ", "//", "=>", "def ", "class ", "const ", "let ", "var "]
        return indicators.contains(where: { text.contains($0) })
    }

    private func formatTime(_ date: Date) -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let time = fmt.string(from: date)

        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let p = FloatingPanel(
            width: ClipboardPanel.panelWidth,
            height: ClipboardPanel.panelHeight,
            cornerRadius: 12
        )
        panel = p
        let box = p.contentBox

        // === Left Column ===
        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(left)

        // Header: title + page indicator
        let title = makeLabel(fontSize: 14, weight: .medium)
        title.stringValue = "剪贴板历史"
        title.textColor = .labelColor
        left.addSubview(title)
        titleLabel = title

        let page = makeLabel(fontSize: 12, weight: .regular)
        page.textColor = .secondaryLabelColor
        page.alignment = .right
        left.addSubview(page)
        pageLabel = page

        // 9 row views
        for i in 0..<itemsPerPage {
            let row = ClipboardRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.isHidden = true
            left.addSubview(row)
            rowViews.append(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: left.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: left.trailingAnchor),
                row.topAnchor.constraint(equalTo: left.topAnchor,
                    constant: ClipboardPanel.headerHeight + CGFloat(i) * ClipboardPanel.rowHeight),
                row.heightAnchor.constraint(equalToConstant: ClipboardPanel.rowHeight),
            ])
        }

        // Footer hint
        let hint = makeLabel(fontSize: 11, weight: .regular)
        hint.stringValue = "↑↓ 选择  ←→ 翻页  ⏎ 粘贴"
        hint.textColor = .tertiaryLabelColor
        left.addSubview(hint)
        hintLabel = hint

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            left.topAnchor.constraint(equalTo: box.topAnchor),
            left.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: ClipboardPanel.leftWidth),

            title.leadingAnchor.constraint(equalTo: left.leadingAnchor,
                constant: ClipboardPanel.leftPadding + ClipboardPanel.numberWidth + 8),
            title.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),

            page.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -ClipboardPanel.leftPadding),
            page.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: ClipboardPanel.leftPadding),
            hint.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8),
        ])

        // === Divider ===
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        box.addSubview(divider)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            divider.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])

        // === Right Column ===
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(right)

        // Preview text in scroll view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.8)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        right.addSubview(scrollView)
        previewScrollView = scrollView
        previewTextView = textView

        // Metadata label
        let meta = makeLabel(fontSize: 11, weight: .regular)
        meta.textColor = .tertiaryLabelColor
        meta.maximumNumberOfLines = 2
        right.addSubview(meta)
        metadataLabel = meta

        let rp = ClipboardPanel.rightPadding
        NSLayoutConstraint.activate([
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.topAnchor.constraint(equalTo: box.topAnchor),
            right.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: box.trailingAnchor),

            scrollView.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: rp),
            scrollView.topAnchor.constraint(equalTo: right.topAnchor, constant: rp),
            scrollView.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -rp),
            scrollView.bottomAnchor.constraint(equalTo: meta.topAnchor, constant: -8),

            meta.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: rp),
            meta.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -rp),
            meta.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -10),
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
}

// MARK: - ClipboardRowView

private class ClipboardRowView: NSView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let bgLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bgLayer)
        bgLayer.cornerRadius = 6

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .right
        numberLabel.isBordered = false
        numberLabel.isEditable = false
        numberLabel.backgroundColor = .clear
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)

        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isBordered = false
        textLabel.isEditable = false
        textLabel.backgroundColor = .clear
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 20),

            textLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(number: Int, text: String) {
        numberLabel.stringValue = "\(number)"
        // Single-line preview: join newlines, trim whitespace
        textLabel.stringValue = text.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    func setSelected(_ selected: Bool) {
        bgLayer.backgroundColor = selected
            ? NSColor(white: 1.0, alpha: 0.07).cgColor
            : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds.insetBy(dx: 4, dy: 1)
    }
}
