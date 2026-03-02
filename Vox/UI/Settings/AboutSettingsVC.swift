import Cocoa

class AboutSettingsVC: NSObject {

    lazy var view: NSView = buildView()

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        // App icon + name
        let iconView = NSImageView()
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let nameLabel = NSTextField(labelWithString: "Vox")
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.textColor = .labelColor

        let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1"
        let buildString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "Version \(versionString)" + (buildString.isEmpty ? "" : " (\(buildString))"))
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 4
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(nameLabel)
        headerStack.addArrangedSubview(versionLabel)
        stack.addArrangedSubview(headerStack)

        // Description
        let desc = SettingsUI.makeSublabel("Voice-powered input and command launcher for macOS.")
        desc.alignment = .center
        stack.addArrangedSubview(desc)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // Info
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Information"))

        let configDir = NSTextField(labelWithString: "~/.vox/")
        configDir.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        configDir.textColor = .secondaryLabelColor
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "Config Directory", control: configDir))

        let asrLabel = NSTextField(labelWithString: ConfigService.shared.asrProvider)
        asrLabel.font = .systemFont(ofSize: 13)
        asrLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "ASR Provider", control: asrLabel))

        let llmLabel = NSTextField(labelWithString: ConfigService.shared.llmProvider ?? "none")
        llmLabel.font = .systemFont(ofSize: 13)
        llmLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "LLM Provider", control: llmLabel))

        let hotkeyLabel = NSTextField(labelWithString: HotkeyService.shared.hotkeyDisplayString)
        hotkeyLabel.font = .systemFont(ofSize: 13)
        hotkeyLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "Hotkey", control: hotkeyLabel))

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // Actions
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Quick Links"))

        let openConfigBtn = SettingsUI.makeButton("Open Config Directory")
        openConfigBtn.target = self
        openConfigBtn.action = #selector(openConfigDir)

        let viewLogBtn = SettingsUI.makeButton("View Debug Log")
        viewLogBtn.target = self
        viewLogBtn.action = #selector(viewLog)

        let linkRow = NSStackView(views: [openConfigBtn, viewLogBtn])
        linkRow.orientation = .horizontal
        linkRow.spacing = 12
        stack.addArrangedSubview(linkRow)

        return scroll
    }

    @objc private func openConfigDir() {
        let path = NSHomeDirectory() + "/.vox"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func viewLog() {
        let path = NSHomeDirectory() + "/.vox/debug.log"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
