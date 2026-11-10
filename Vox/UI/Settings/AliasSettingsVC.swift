import Cocoa

// Alias management: view/edit ~/.vox/aliases.json — pre-LLM deterministic
// substitutions for ASR homophones (e.g. "cloud code" → "Claude Code").
// Mirrors DictionarySettingsVC pattern: source of truth is JSON file,
// this VC is a view + mutation surface that calls AliasService.

final class AliasSettingsVC: NSObject {

    private let svc = AliasService.shared
    private let log = LogService.shared

    lazy var view: NSView = buildView()

    private var aliasesTableView: NSTableView!
    private var aliases: [AliasService.Alias] = []
    private var countLabel: NSTextField!

    // MARK: - View Construction

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Aliases (Pre-LLM)"))

        let desc = SettingsUI.makeSublabel(
            "Deterministic text substitutions applied BEFORE the LLM post-processing step. "
            + "Use this to fix predictable ASR errors that the LLM keeps missing "
            + "(e.g. \"cloud code\" → \"Claude Code\"). Each rule is a one-shot replacement; "
            + "rules do NOT chain (output of one rule is not fed into another)."
        )
        stack.addArrangedSubview(desc)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(countLabel)

        stack.addArrangedSubview(buildTable())

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let addBtn = SettingsUI.makeButton("Add…")
        addBtn.target = self
        addBtn.action = #selector(addAliasTapped)
        btnRow.addArrangedSubview(addBtn)

        let editBtn = SettingsUI.makeButton("Edit…")
        editBtn.target = self
        editBtn.action = #selector(editAliasTapped)
        btnRow.addArrangedSubview(editBtn)

        let removeBtn = SettingsUI.makeButton("Remove")
        removeBtn.target = self
        removeBtn.action = #selector(removeAliasTapped)
        btnRow.addArrangedSubview(removeBtn)

        let editJsonBtn = SettingsUI.makeButton("Edit JSON…")
        editJsonBtn.target = self
        editJsonBtn.action = #selector(editJsonTapped)
        btnRow.addArrangedSubview(editJsonBtn)

        let resetBtn = SettingsUI.makeButton("Reset to Defaults…")
        resetBtn.target = self
        resetBtn.action = #selector(resetToDefaultsTapped)
        btnRow.addArrangedSubview(resetBtn)

        stack.addArrangedSubview(btnRow)

        reload()

        return scroll
    }

    private func buildTable() -> NSView {
        let table = NSTableView()
        table.rowHeight = 22
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        let cFrom = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("from"))
        cFrom.title = "From"
        cFrom.width = 180
        table.addTableColumn(cFrom)

        let cTo = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("to"))
        cTo.title = "To"
        cTo.width = 180
        table.addTableColumn(cTo)

        let cMode = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        cMode.title = "Mode"
        cMode.width = 90
        table.addTableColumn(cMode)

        let cCase = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("case"))
        cCase.title = "Case"
        cCase.width = 60
        table.addTableColumn(cCase)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editAliasTapped)

        aliasesTableView = table

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        return scroll
    }

    // MARK: - Actions

    private func reload() {
        aliases = svc.aliases
        countLabel.stringValue = "\(aliases.count) alias\(aliases.count == 1 ? "" : "es")"
        aliasesTableView.reloadData()
    }

    @objc private func addAliasTapped() {
        guard let edited = runEditDialog(initial: nil, title: "Add Alias") else { return }
        if !svc.addAlias(edited) {
            showInfo("Alias already exists or is invalid (from is empty or equals to).")
            return
        }
        reload()
    }

    @objc private func editAliasTapped() {
        let row = aliasesTableView.selectedRow
        guard row >= 0 && row < aliases.count else {
            showInfo("Select an alias first.")
            return
        }
        let current = aliases[row]
        guard let edited = runEditDialog(initial: current, title: "Edit Alias") else { return }
        if !svc.updateAlias(at: row, to: edited) {
            showInfo("Cannot save: from is empty, equals to, or conflicts with another row.")
            return
        }
        reload()
    }

    @objc private func removeAliasTapped() {
        let row = aliasesTableView.selectedRow
        guard row >= 0 && row < aliases.count else { return }
        svc.removeAlias(at: row)
        reload()
    }

    @objc private func editJsonTapped() {
        NSWorkspace.shared.open(URL(fileURLWithPath: svc.aliasPath))
    }

    @objc private func resetToDefaultsTapped() {
        let alert = NSAlert()
        alert.messageText = "Reset aliases to defaults?"
        alert.informativeText = "This replaces all current aliases with the bundled defaults. Your custom rules will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        svc.resetToDefaults()
        reload()
    }

    // MARK: - Edit dialog

    private func runEditDialog(initial: AliasService.Alias?, title: String) -> AliasService.Alias? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Pre-LLM substitution rule. Empty input or from==to will be rejected."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))

        // From field
        let fromLabel = NSTextField(labelWithString: "From:")
        fromLabel.frame = NSRect(x: 0, y: 104, width: 60, height: 20)
        container.addSubview(fromLabel)
        let fromField = NSTextField(frame: NSRect(x: 64, y: 104, width: 256, height: 22))
        fromField.placeholderString = "e.g. cloud code"
        fromField.stringValue = initial?.from ?? ""
        container.addSubview(fromField)

        // To field
        let toLabel = NSTextField(labelWithString: "To:")
        toLabel.frame = NSRect(x: 0, y: 76, width: 60, height: 20)
        container.addSubview(toLabel)
        let toField = NSTextField(frame: NSRect(x: 64, y: 76, width: 256, height: 22))
        toField.placeholderString = "e.g. Claude Code"
        toField.stringValue = initial?.to ?? ""
        container.addSubview(toField)

        // Mode popup
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modeLabel.frame = NSRect(x: 0, y: 44, width: 60, height: 20)
        container.addSubview(modeLabel)
        let modePopup = NSPopUpButton(frame: NSRect(x: 64, y: 40, width: 160, height: 26))
        modePopup.addItem(withTitle: "Word boundary (Latin)")
        modePopup.addItem(withTitle: "Substring (CJK / any)")
        modePopup.addItem(withTitle: "Regex (advanced)")
        let modeIdx: Int
        switch initial?.matchMode ?? .word {
        case .word: modeIdx = 0
        case .substring: modeIdx = 1
        case .regex: modeIdx = 2
        }
        modePopup.selectItem(at: modeIdx)
        container.addSubview(modePopup)

        // Case sensitive checkbox
        let caseCheckbox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
        caseCheckbox.frame = NSRect(x: 64, y: 8, width: 200, height: 22)
        caseCheckbox.state = (initial?.caseSensitive ?? false) ? .on : .off
        container.addSubview(caseCheckbox)

        alert.accessoryView = container
        alert.window.initialFirstResponder = fromField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let modes: [AliasService.MatchMode] = [.word, .substring, .regex]
        let mode = modes[modePopup.indexOfSelectedItem]
        return AliasService.Alias.make(
            from: fromField.stringValue,
            to: toField.stringValue,
            matchMode: mode,
            caseSensitive: caseCheckbox.state == .on
        )
    }

    private func showInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Aliases"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Table data source / delegate

extension AliasSettingsVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return aliases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < aliases.count, let col = tableColumn else { return nil }
        let alias = aliases[row]
        let id = col.identifier.rawValue
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: 12)
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        switch id {
        case "from": tf.stringValue = alias.from
        case "to": tf.stringValue = alias.to
        case "mode":
            switch alias.matchMode {
            case .word: tf.stringValue = "word"
            case .substring: tf.stringValue = "substring"
            case .regex: tf.stringValue = "regex"
            }
        case "case":
            tf.stringValue = alias.caseSensitive ? "yes" : "no"
        default: tf.stringValue = ""
        }
        return cell
    }
}
