import Cocoa

class ActionsSettingsVC: NSObject {

    lazy var view: NSView = buildView()

    private var listStack: NSStackView!

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Voice Actions"))
        stack.addArrangedSubview(SettingsUI.makeSublabel(
            "Actions are Markdown files with YAML frontmatter in ~/Library/Application Support/Vox/Actions/. Say a trigger phrase to activate."
        ))

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 8
        stack.addArrangedSubview(listStack)

        reloadActions()

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        let reloadBtn = SettingsUI.makeButton("Reload Actions")
        reloadBtn.target = self
        reloadBtn.action = #selector(reloadTapped)
        stack.addArrangedSubview(reloadBtn)

        return scroll
    }

    private func reloadActions() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let actions = ActionService.shared.actions
        if actions.isEmpty {
            let empty = SettingsUI.makeSublabel("No actions found.")
            listStack.addArrangedSubview(empty)
            return
        }

        for action in actions {
            let card = makeActionCard(action)
            listStack.addArrangedSubview(card)
        }
    }

    private func makeActionCard(_ action: ActionDefinition) -> NSView {
        let card = SettingsUI.makeConfigCard()

        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.spacing = 4
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])

        // Title row: name + type badge
        let nameLabel = SettingsUI.makeLabel(action.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let typeBadge = NSTextField(labelWithString: action.type.rawValue.uppercased())
        typeBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        typeBadge.textColor = .secondaryLabelColor
        typeBadge.wantsLayer = true
        typeBadge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        typeBadge.layer?.cornerRadius = 3

        let titleRow = NSStackView(views: [nameLabel, typeBadge])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        cardStack.addArrangedSubview(titleRow)

        // Description
        if !action.description.isEmpty {
            let desc = SettingsUI.makeSublabel(action.description)
            cardStack.addArrangedSubview(desc)
        }

        // Triggers
        if !action.triggers.isEmpty {
            let triggersText = "Triggers: " + action.triggers.joined(separator: ", ")
            let triggers = SettingsUI.makeSublabel(triggersText)
            triggers.textColor = .secondaryLabelColor
            cardStack.addArrangedSubview(triggers)
        }

        return card
    }

    @objc private func reloadTapped() {
        ActionService.shared.loadActions()
        reloadActions()
    }

}
