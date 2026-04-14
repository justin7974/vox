import Cocoa

// Dictionary management: view/edit ~/.vox/dictionary.json terms, scan history
// for ASR-error suggestions, and batch-accept corrections into the dictionary.
//
// Source of truth remains the JSON file — this VC is a view + mutation surface
// that calls DictionaryService, which persists every change.

final class DictionarySettingsVC: NSObject {

    private let dict = DictionaryService.shared
    private let log = LogService.shared

    lazy var view: NSView = buildView()

    // Terms table
    private var termsTableView: NSTableView!
    private var terms: [String] = []
    private var termsCountLabel: NSTextField!

    // Suggestions table
    private var suggestionsTableView: NSTableView!
    private var suggestionsCountLabel: NSTextField!
    private var scanButton: NSButton!
    private var acceptButton: NSButton!
    private var scanSpinner: NSProgressIndicator!
    private var providerPopup: NSPopUpButton!
    private var providerNames: [String] = []
    private var suggestions: [Suggestion] = []
    private var accepted: Set<Int> = []  // by index into suggestions

    struct Suggestion {
        var wrong: String
        var suggested: String
        var context: String
        var occurrences: Int
    }

    // MARK: - View Construction

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        // === Section 1: Current Dictionary ===
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Dictionary Terms"))

        let desc = SettingsUI.makeSublabel("Proper nouns and names Vox will use to correct ASR errors. Applied in the LLM post-processing step.")
        stack.addArrangedSubview(desc)

        termsCountLabel = NSTextField(labelWithString: "")
        termsCountLabel.font = .systemFont(ofSize: 11)
        termsCountLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(termsCountLabel)

        stack.addArrangedSubview(buildTermsTable())

        let termsBtnRow = NSStackView()
        termsBtnRow.orientation = .horizontal
        termsBtnRow.spacing = 8

        let addBtn = SettingsUI.makeButton("Add…")
        addBtn.target = self
        addBtn.action = #selector(addTermTapped)
        termsBtnRow.addArrangedSubview(addBtn)

        let removeBtn = SettingsUI.makeButton("Remove")
        removeBtn.target = self
        removeBtn.action = #selector(removeTermTapped)
        termsBtnRow.addArrangedSubview(removeBtn)

        let editJsonBtn = SettingsUI.makeButton("Edit JSON…")
        editJsonBtn.target = self
        editJsonBtn.action = #selector(editJsonTapped)
        termsBtnRow.addArrangedSubview(editJsonBtn)

        stack.addArrangedSubview(termsBtnRow)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // === Section 2: Scan History for Suggestions ===
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Scan History for Suggestions"))

        let scanDesc = SettingsUI.makeSublabel("Analyze recent transcriptions with the LLM to find repeated ASR errors. Review and accept to add to the dictionary.")
        stack.addArrangedSubview(scanDesc)

        let scanRow = NSStackView()
        scanRow.orientation = .horizontal
        scanRow.spacing = 8

        scanButton = SettingsUI.makeButton("Scan History")
        scanButton.target = self
        scanButton.action = #selector(scanHistoryTapped)
        scanRow.addArrangedSubview(scanButton)

        let usingLabel = NSTextField(labelWithString: "with")
        usingLabel.font = .systemFont(ofSize: 12)
        usingLabel.textColor = .secondaryLabelColor
        scanRow.addArrangedSubview(usingLabel)

        providerPopup = NSPopUpButton()
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerNames = ConfigService.shared.availableLLMProviders
        if providerNames.isEmpty {
            providerPopup.addItem(withTitle: "(none configured)")
            providerPopup.isEnabled = false
        } else {
            for name in providerNames {
                let title = providerTitle(for: name)
                providerPopup.addItem(withTitle: title)
            }
            let current = ConfigService.shared.llmProvider ?? providerNames.first!
            if let idx = providerNames.firstIndex(of: current) {
                providerPopup.selectItem(at: idx)
            }
        }
        providerPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        scanRow.addArrangedSubview(providerPopup)

        scanSpinner = NSProgressIndicator()
        scanSpinner.style = .spinning
        scanSpinner.controlSize = .small
        scanSpinner.isDisplayedWhenStopped = false
        scanSpinner.translatesAutoresizingMaskIntoConstraints = false
        scanSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        scanSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        scanRow.addArrangedSubview(scanSpinner)

        suggestionsCountLabel = NSTextField(labelWithString: "")
        suggestionsCountLabel.font = .systemFont(ofSize: 11)
        suggestionsCountLabel.textColor = .secondaryLabelColor
        scanRow.addArrangedSubview(suggestionsCountLabel)

        stack.addArrangedSubview(scanRow)

        stack.addArrangedSubview(buildSuggestionsTable())

        acceptButton = SettingsUI.makeButton("Accept Checked")
        acceptButton.target = self
        acceptButton.action = #selector(acceptCheckedTapped)
        acceptButton.isEnabled = false
        stack.addArrangedSubview(acceptButton)

        reloadTerms()
        updateSuggestionsCount()

        return scroll
    }

    private func buildTermsTable() -> NSView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        col.resizingMask = .autoresizingMask
        col.isEditable = true
        table.addTableColumn(col)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(beginEditSelectedTerm)

        termsTableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        return scroll
    }

    private func buildSuggestionsTable() -> NSView {
        let table = NSTableView()
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        let cAccept = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accept"))
        cAccept.title = ""
        cAccept.width = 22
        cAccept.minWidth = 22
        cAccept.maxWidth = 22
        table.addTableColumn(cAccept)

        let cWrong = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wrong"))
        cWrong.title = "Heard"
        cWrong.width = 100
        table.addTableColumn(cWrong)

        let cSuggested = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggested"))
        cSuggested.title = "Should be"
        cSuggested.width = 100
        table.addTableColumn(cSuggested)

        let cOcc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("occ"))
        cOcc.title = "×"
        cOcc.width = 30
        cOcc.minWidth = 30
        cOcc.maxWidth = 40
        table.addTableColumn(cOcc)

        let cCtx = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ctx"))
        cCtx.title = "Context"
        cCtx.width = 220
        table.addTableColumn(cCtx)

        table.dataSource = self
        table.delegate = self
        suggestionsTableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        return scroll
    }

    // MARK: - Terms Actions

    private func reloadTerms() {
        terms = dict.terms
        termsCountLabel.stringValue = "\(terms.count) term\(terms.count == 1 ? "" : "s")"
        termsTableView.reloadData()
    }

    @objc private func addTermTapped() {
        let alert = NSAlert()
        alert.messageText = "Add Dictionary Term"
        alert.informativeText = "Enter a proper noun or name to help Vox correct ASR errors."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "e.g. PingCAP"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !dict.addTerm(value) {
                showInfo("\"\(value)\" is already in the dictionary.")
                return
            }
            reloadTerms()
        }
    }

    @objc private func removeTermTapped() {
        let row = termsTableView.selectedRow
        guard row >= 0 && row < terms.count else { return }
        dict.removeTerm(at: row)
        reloadTerms()
    }

    @objc private func beginEditSelectedTerm() {
        let row = termsTableView.selectedRow
        guard row >= 0 else { return }
        termsTableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func editJsonTapped() {
        NSWorkspace.shared.open(URL(fileURLWithPath: dict.dictPath))
    }

    // MARK: - Scan History

    @objc private func scanHistoryTapped() {
        let records = HistoryService.shared.getRecords()
        guard !records.isEmpty else {
            showInfo("No history records to scan.")
            return
        }
        let idx = providerPopup.indexOfSelectedItem
        guard idx >= 0 && idx < providerNames.count else {
            showInfo("No LLM provider configured. Set one up in Voice settings first.")
            return
        }
        let chosenProvider = providerNames[idx]

        scanButton.isEnabled = false
        acceptButton.isEnabled = false
        scanSpinner.startAnimation(nil)
        suggestionsCountLabel.stringValue = "Scanning \(records.count) records with \(providerTitle(for: chosenProvider))…"

        let recentTexts = records.prefix(150).map { $0.text }
        let existing = dict.terms

        Task {
            let found = await Self.runScan(records: recentTexts, existing: existing, providerName: chosenProvider)
            await MainActor.run {
                self.scanSpinner.stopAnimation(nil)
                self.scanButton.isEnabled = true
                self.suggestions = found
                self.accepted.removeAll()
                self.suggestionsTableView.reloadData()
                self.updateSuggestionsCount()
                self.acceptButton.isEnabled = false
                if found.isEmpty {
                    self.suggestionsCountLabel.stringValue = "No suggestions returned. Try a different model or check LLM config."
                }
            }
        }
    }

    private func providerTitle(for name: String) -> String {
        if let cfg = ConfigService.shared.llmProviderConfig(for: name) {
            return "\(name) (\(cfg.model))"
        }
        return name
    }

    private func updateSuggestionsCount() {
        if suggestions.isEmpty {
            suggestionsCountLabel.stringValue = ""
        } else {
            suggestionsCountLabel.stringValue = "\(suggestions.count) suggestion\(suggestions.count == 1 ? "" : "s") • \(accepted.count) checked"
        }
    }

    @objc private func acceptCheckedTapped() {
        let picked = accepted.sorted().compactMap { idx -> String? in
            guard idx < suggestions.count else { return nil }
            return suggestions[idx].suggested
        }
        guard !picked.isEmpty else { return }
        let added = dict.addTerms(picked)
        // Remove accepted rows from the suggestions list
        let toRemove = accepted.sorted(by: >)
        for idx in toRemove where idx < suggestions.count {
            suggestions.remove(at: idx)
        }
        accepted.removeAll()
        reloadTerms()
        suggestionsTableView.reloadData()
        updateSuggestionsCount()
        acceptButton.isEnabled = false
        showInfo("Added \(added) new term\(added == 1 ? "" : "s") to the dictionary.")
    }

    // MARK: - Helpers

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - LLM Scan

    private static func runScan(records: [String], existing: [String], providerName: String) async -> [Suggestion] {
        let joined = records.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        let existingList = existing.isEmpty ? "(none)" : existing.joined(separator: ", ")

        let systemPrompt = """
        You are an ASR-error auditor. You are given a user's recent voice-transcription history. Your job is to identify repeated ASR mis-recognitions of proper nouns (product names, people, companies, technical terms) that should be added to the user's dictionary so future transcriptions are corrected.

        HARD RULES:
        - Only flag errors with clear, objective evidence from the transcripts — context must make the correct form obvious.
        - Only flag items that appear at least twice OR where context overwhelmingly determines the correction.
        - Do NOT flag items already in the existing dictionary.
        - Do NOT invent corrections. If unsure, skip it.
        - Prefer items that are repeated across multiple records.
        - Skip generic words, common nouns, or stylistic rewrites.

        Existing dictionary: \(existingList)

        OUTPUT:
        Return a single JSON object (no markdown, no prose) with this shape:
        {"suggestions": [{"wrong": "Cloud", "suggested": "Claude", "context": "用 Cloud 写代码", "occurrences": 5}, ...]}
        If there are no high-confidence suggestions, return {"suggestions": []}.
        """

        let userMsg = "Transcription history:\n\n\(joined)"
        guard let raw = await LLMService.shared.completeWithNamedProvider(
            providerName,
            userMessage: userMsg,
            systemPrompt: systemPrompt
        ), !raw.isEmpty else {
            return []
        }
        return parseSuggestions(raw)
    }

    private static func parseSuggestions(_ raw: String) -> [Suggestion] {
        // Strip common code-fence wrappers defensively.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fenceEnd = s.range(of: "```", options: .backwards) {
                s = String(s[..<fenceEnd.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["suggestions"] as? [[String: Any]] else {
            return []
        }

        return arr.compactMap { item in
            guard let wrong = item["wrong"] as? String, !wrong.isEmpty,
                  let suggested = item["suggested"] as? String, !suggested.isEmpty else {
                return nil
            }
            let context = (item["context"] as? String) ?? ""
            let occurrences = (item["occurrences"] as? Int) ?? 1
            return Suggestion(wrong: wrong, suggested: suggested, context: context, occurrences: occurrences)
        }
    }
}

// MARK: - Table Data Source / Delegate

extension DictionarySettingsVC: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === termsTableView { return terms.count }
        if tableView === suggestionsTableView { return suggestions.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === termsTableView {
            return termCellView(row: row)
        }
        if tableView === suggestionsTableView {
            return suggestionCellView(row: row, column: tableColumn)
        }
        return nil
    }

    // --- Terms ---

    private func termCellView(row: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("termCell")
        let cell = (termsTableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField()
            tf.isBordered = false
            tf.drawsBackground = false
            tf.font = .systemFont(ofSize: 13)
            tf.isEditable = true
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.delegate = self
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = terms[row]
        cell.textField?.tag = row
        return cell
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let row = tf.tag
        let fieldId = tf.identifier?.rawValue ?? ""
        let newValue = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch fieldId {
        case "sug-wrong":
            guard row >= 0 && row < suggestions.count else { return }
            if newValue.isEmpty { tf.stringValue = suggestions[row].wrong; return }
            suggestions[row].wrong = newValue

        case "sug-suggested":
            guard row >= 0 && row < suggestions.count else { return }
            if newValue.isEmpty { tf.stringValue = suggestions[row].suggested; return }
            suggestions[row].suggested = newValue

        default:
            // Terms table cell (no explicit identifier set on its textField).
            guard row >= 0 && row < terms.count else { return }
            if newValue == terms[row] { return }
            if newValue.isEmpty {
                tf.stringValue = terms[row]
                return
            }
            if !dict.updateTerm(at: row, to: newValue) {
                tf.stringValue = terms[row]
                showInfo("\"\(newValue)\" is already in the dictionary or invalid.")
                return
            }
            reloadTerms()
        }
    }

    // --- Suggestions ---

    private func suggestionCellView(row: Int, column: NSTableColumn?) -> NSView? {
        guard row < suggestions.count, let colId = column?.identifier.rawValue else { return nil }
        let item = suggestions[row]

        switch colId {
        case "accept":
            let id = NSUserInterfaceItemIdentifier("acceptCell")
            let container = NSTableCellView()
            container.identifier = id
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleAccept(_:)))
            checkbox.state = accepted.contains(row) ? .on : .off
            checkbox.tag = row
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        case "wrong":
            return makeEditableSuggestionCell(text: item.wrong, row: row, fieldId: "sug-wrong", bold: false)
        case "suggested":
            return makeEditableSuggestionCell(text: item.suggested, row: row, fieldId: "sug-suggested", bold: true)
        case "occ":
            return makeTextCell("\(item.occurrences)×", monospace: true)
        case "ctx":
            return makeTextCell(item.context, monospace: false, secondary: true)
        default:
            return nil
        }
    }

    private func makeEditableSuggestionCell(text: String, row: Int, fieldId: String, bold: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField()
        tf.stringValue = text
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.identifier = NSUserInterfaceItemIdentifier(fieldId)
        tf.tag = row
        tf.delegate = self
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeTextCell(_ text: String, monospace: Bool, bold: Bool = false, secondary: Bool = false) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        if monospace {
            tf.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        } else if bold {
            tf.font = .systemFont(ofSize: 13, weight: .semibold)
        } else {
            tf.font = .systemFont(ofSize: 13)
        }
        if secondary { tf.textColor = .secondaryLabelColor }
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggleAccept(_ sender: NSButton) {
        let row = sender.tag
        if sender.state == .on {
            accepted.insert(row)
        } else {
            accepted.remove(row)
        }
        acceptButton.isEnabled = !accepted.isEmpty
        updateSuggestionsCount()
    }
}
