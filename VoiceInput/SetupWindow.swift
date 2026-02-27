import Cocoa

class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var asrPopup: NSPopUpButton!
    private var asrKeyField: NSTextField!
    private var asrKeyRow: NSView!
    private var llmPopup: NSPopUpButton!
    private var llmKeyField: NSTextField!
    private var llmKeyRow: NSView!
    private var statusLabel: NSTextField!

    // Pre-configured providers
    struct ASRProvider {
        let name: String
        let configKey: String
    }

    struct LLMProvider {
        let name: String
        let configKey: String
        let baseURL: String
        let model: String
        let format: String
    }

    static let asrProviders = [
        ASRProvider(name: "Alibaba Qwen ASR (Recommended)", configKey: "qwen"),
        ASRProvider(name: "Local Whisper (No API needed)", configKey: "whisper"),
    ]

    static let llmProviders = [
        LLMProvider(name: "Kimi (Recommended)", configKey: "kimi",
                    baseURL: "https://api.kimi.com/coding/v1/messages", model: "kimi-k2.5",
                    format: "anthropic"),
        LLMProvider(name: "Alibaba Qwen (Same key as ASR)", configKey: "qwen-llm",
                    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                    model: "qwen3.5-plus", format: "openai"),
        LLMProvider(name: "MiniMax (CN)", configKey: "minimax",
                    baseURL: "https://api.minimaxi.com/anthropic/v1/messages", model: "MiniMax-M2.5",
                    format: "anthropic"),
        LLMProvider(name: "MiniMax (Global)", configKey: "minimax-global",
                    baseURL: "https://api.minimax.io/anthropic/v1/messages", model: "MiniMax-M2.5",
                    format: "anthropic"),
        LLMProvider(name: "Moonshot", configKey: "moonshot",
                    baseURL: "https://api.moonshot.cn/anthropic/v1/messages", model: "moonshot-v1-auto",
                    format: "anthropic"),
        LLMProvider(name: "GLM (CN)", configKey: "glm",
                    baseURL: "https://open.bigmodel.cn/api/anthropic/v1/messages", model: "glm-4-plus",
                    format: "anthropic"),
        LLMProvider(name: "GLM (Global)", configKey: "glm-global",
                    baseURL: "https://api.z.ai/api/anthropic/v1/messages", model: "glm-4-plus",
                    format: "anthropic"),
        LLMProvider(name: "DeepSeek", configKey: "deepseek",
                    baseURL: "https://api.deepseek.com/chat/completions", model: "deepseek-chat",
                    format: "openai"),
        LLMProvider(name: "OpenRouter", configKey: "openrouter",
                    baseURL: "https://openrouter.ai/api/v1/chat/completions", model: "anthropic/claude-haiku",
                    format: "openai"),
        LLMProvider(name: "None (Skip)", configKey: "none",
                    baseURL: "", model: "", format: ""),
    ]

    // Per-provider key storage: configKey → apiKey
    private var llmKeys: [String: String] = [:]
    private var lastLLMIndex: Int = 0

    private var onComplete: (() -> Void)?

    func show(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        // Window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "VoiceInput"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(named: "windowBackgroundColor") ?? NSColor.windowBackgroundColor

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = stack
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // ── Header ──
        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 6

        let iconLabel = NSTextField(labelWithString: "🎙️")
        iconLabel.font = NSFont.systemFont(ofSize: 48)
        iconLabel.alignment = .center
        headerStack.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "VoiceInput")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.backgroundColor = .clear
        headerStack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Press Ctrl+` to speak, text appears at your cursor.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.isBordered = false
        subtitleLabel.isEditable = false
        subtitleLabel.backgroundColor = .clear
        headerStack.addArrangedSubview(subtitleLabel)

        stack.addArrangedSubview(headerStack)

        // ── Section 1: Speech Recognition ──
        let (asrCard, asrKeyRowRef) = buildASRSection()
        asrKeyRow = asrKeyRowRef
        stack.addArrangedSubview(asrCard)
        asrCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true

        // ── Section 2: Post-Processing ──
        let (llmCard, llmKeyRowRef) = buildLLMSection()
        llmKeyRow = llmKeyRowRef
        stack.addArrangedSubview(llmCard)
        llmCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true

        // ── Section 3: Permissions ──
        let permCard = buildPermissionsSection()
        stack.addArrangedSubview(permCard)
        permCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true

        // ── Footer: status + buttons ──
        let footer = buildFooter()
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true

        // Load existing config
        loadExistingConfig()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build sections

    private func buildASRSection() -> (NSView, NSView) {
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 16)

        let header = makeSectionHeader("Speech Recognition")
        cardStack.addArrangedSubview(header)

        let providerRow = makeFormRow(label: "Provider")
        asrPopup = NSPopUpButton()
        asrPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in SetupWindow.asrProviders { asrPopup.addItem(withTitle: p.name) }
        asrPopup.target = self
        asrPopup.action = #selector(asrProviderChanged)
        providerRow.addArrangedSubview(asrPopup)
        asrPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(providerRow)
        providerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        let keyRow = makeFormRow(label: "API Key")
        asrKeyField = NSTextField()
        asrKeyField.translatesAutoresizingMaskIntoConstraints = false
        asrKeyField.placeholderString = "sk-..."
        asrKeyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        asrKeyField.lineBreakMode = .byTruncatingMiddle
        keyRow.addArrangedSubview(asrKeyField)
        asrKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(keyRow)
        keyRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        let hint = NSTextField(labelWithString: "Get your key from bailian.console.aliyun.com")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.isBordered = false
        hint.isEditable = false
        hint.backgroundColor = .clear
        cardStack.addArrangedSubview(hint)

        return (card, keyRow)
    }

    private func buildLLMSection() -> (NSView, NSView) {
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 16)

        let header = makeSectionHeader("Text Post-Processing")
        cardStack.addArrangedSubview(header)

        let desc = NSTextField(labelWithString: "LLM cleans up speech: removes filler words, fixes typos, adds punctuation.")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.isBordered = false
        desc.isEditable = false
        desc.backgroundColor = .clear
        desc.preferredMaxLayoutWidth = 380
        cardStack.addArrangedSubview(desc)

        let providerRow = makeFormRow(label: "Provider")
        llmPopup = NSPopUpButton()
        llmPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in SetupWindow.llmProviders { llmPopup.addItem(withTitle: p.name) }
        llmPopup.target = self
        llmPopup.action = #selector(llmProviderChanged)
        providerRow.addArrangedSubview(llmPopup)
        llmPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(providerRow)
        providerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        let keyRow = makeFormRow(label: "API Key")
        llmKeyField = NSTextField()
        llmKeyField.translatesAutoresizingMaskIntoConstraints = false
        llmKeyField.placeholderString = "sk-..."
        llmKeyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        llmKeyField.lineBreakMode = .byTruncatingMiddle
        keyRow.addArrangedSubview(llmKeyField)
        llmKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(keyRow)
        keyRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        return (card, keyRow)
    }

    private func buildPermissionsSection() -> NSView {
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 16)

        let header = makeSectionHeader("Permissions")
        cardStack.addArrangedSubview(header)

        let items = [
            ("🎤", "Microphone", "Required for voice recording"),
            ("♿️", "Accessibility", "Required for auto-paste at cursor"),
        ]
        for (icon, title, desc) in items {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline

            let iconField = NSTextField(labelWithString: icon)
            iconField.font = NSFont.systemFont(ofSize: 14)
            iconField.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(iconField)

            let titleField = NSTextField(labelWithString: title)
            titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleField.textColor = .labelColor
            titleField.isBordered = false
            titleField.isEditable = false
            titleField.backgroundColor = .clear
            titleField.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(titleField)

            let dash = NSTextField(labelWithString: "—")
            dash.font = NSFont.systemFont(ofSize: 12)
            dash.textColor = .tertiaryLabelColor
            dash.isBordered = false
            dash.isEditable = false
            dash.backgroundColor = .clear
            dash.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(dash)

            let descField = NSTextField(labelWithString: desc)
            descField.font = NSFont.systemFont(ofSize: 12)
            descField.textColor = .secondaryLabelColor
            descField.isBordered = false
            descField.isEditable = false
            descField.backgroundColor = .clear
            row.addArrangedSubview(descField)

            cardStack.addArrangedSubview(row)
        }

        let note = NSTextField(labelWithString: "macOS will prompt when needed. Grant in System Settings > Privacy & Security.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.isBordered = false
        note.isEditable = false
        note.backgroundColor = .clear
        note.preferredMaxLayoutWidth = 380
        cardStack.addArrangedSubview(note)

        return card
    }

    private func buildFooter() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 8

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .systemRed
        statusLabel.isBordered = false
        statusLabel.isEditable = false
        statusLabel.backgroundColor = .clear
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(statusLabel)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelSetup))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}" // Escape
        cancelBtn.setContentHuggingPriority(.required, for: .horizontal)
        footer.addArrangedSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save & Start", target: self, action: #selector(saveConfig))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.hasDestructiveAction = false
        if #available(macOS 14.0, *) {
            // Accent color button
        }
        saveBtn.setContentHuggingPriority(.required, for: .horizontal)
        footer.addArrangedSubview(saveBtn)

        return footer
    }

    // MARK: - UI Helpers

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        if #available(macOS 14.0, *) {
            card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        } else {
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        card.layer?.borderWidth = 0.5
        return card
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.isBordered = false
        label.isEditable = false
        label.backgroundColor = .clear
        return label
    }

    private func makeFormRow(label: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.isBordered = false
        labelField.isEditable = false
        labelField.backgroundColor = .clear
        labelField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        labelField.alignment = .right
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(labelField)

        return row
    }

    private func pinInside(_ child: NSView, to parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        ])
    }

    // MARK: - Actions

    @objc private func asrProviderChanged() {
        let isQwen = asrPopup.indexOfSelectedItem == 0
        asrKeyRow.isHidden = !isQwen
    }

    @objc private func llmProviderChanged() {
        // Save key from previous provider
        let oldProvider = SetupWindow.llmProviders[lastLLMIndex]
        if oldProvider.configKey != "none" {
            llmKeys[oldProvider.configKey] = llmKeyField.stringValue
        }

        // Load key for new provider
        let newIndex = llmPopup.indexOfSelectedItem
        let newProvider = SetupWindow.llmProviders[newIndex]
        let isNone = newProvider.configKey == "none"
        let isQwenLLM = newProvider.configKey == "qwen-llm"
        llmKeyRow.isHidden = isNone || isQwenLLM

        if isQwenLLM {
            // Auto-fill from ASR key
            llmKeyField.stringValue = asrKeyField.stringValue
        } else {
            llmKeyField.stringValue = llmKeys[newProvider.configKey] ?? ""
        }

        lastLLMIndex = newIndex
    }

    @objc private func cancelSetup() {
        window.close()
    }

    @objc private func saveConfig() {
        let asrIndex = asrPopup.indexOfSelectedItem
        let llmIndex = llmPopup.indexOfSelectedItem
        let asrProvider = SetupWindow.asrProviders[asrIndex]
        let llmProvider = SetupWindow.llmProviders[llmIndex]

        // Validate
        if asrProvider.configKey == "qwen" && asrKeyField.stringValue.isEmpty {
            statusLabel.stringValue = "Please enter your Qwen ASR API key."
            return
        }
        if llmProvider.configKey != "none" && llmKeyField.stringValue.isEmpty {
            statusLabel.stringValue = "Please enter your LLM API key, or select None."
            return
        }

        // Build config
        var config: [String: Any] = [
            "asr": asrProvider.configKey,
            "userContext": ""
        ]

        if asrProvider.configKey == "qwen" {
            config["qwen-asr"] = ["apiKey": asrKeyField.stringValue]
        }

        // Save current field value to llmKeys
        if llmProvider.configKey != "none" {
            if llmProvider.configKey == "qwen-llm" {
                // Qwen LLM shares the ASR key
                llmKeys["qwen-llm"] = asrKeyField.stringValue
            } else {
                llmKeys[llmProvider.configKey] = llmKeyField.stringValue
            }
            config["provider"] = llmProvider.configKey
        }

        // Write all known provider keys to config
        for p in SetupWindow.llmProviders where p.configKey != "none" {
            if let key = llmKeys[p.configKey], !key.isEmpty {
                config[p.configKey] = [
                    "baseURL": p.baseURL,
                    "apiKey": key,
                    "model": p.model,
                    "format": p.format
                ]
            }
        }

        // Preserve userContext from existing config
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ctx = existing["userContext"] as? String, !ctx.isEmpty {
            config["userContext"] = ctx
        }

        // Ensure directory exists
        let configDir = NSHomeDirectory() + "/.voiceinput"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        // Write config
        if let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: configPath))
            NSLog("VoiceInput: Config saved to \(configPath)")
        }

        window.close()
        onComplete?()
    }

    // MARK: - Load existing config

    private func loadExistingConfig() {
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // ASR provider
        if let asr = json["asr"] as? String {
            if asr == "whisper" {
                asrPopup.selectItem(at: 1)
                asrKeyRow.isHidden = true
            } else if asr == "qwen" {
                asrPopup.selectItem(at: 0)
                if let qwenConfig = json["qwen-asr"] as? [String: Any],
                   let key = qwenConfig["apiKey"] as? String {
                    asrKeyField.stringValue = key
                }
            }
        }

        // LLM: load all provider keys from config
        for p in SetupWindow.llmProviders where p.configKey != "none" {
            if let providerConfig = json[p.configKey] as? [String: Any],
               let key = providerConfig["apiKey"] as? String {
                llmKeys[p.configKey] = key
            }
        }

        // LLM: select active provider and show its key
        if let provider = json["provider"] as? String {
            for (i, p) in SetupWindow.llmProviders.enumerated() {
                if p.configKey == provider {
                    llmPopup.selectItem(at: i)
                    llmKeyField.stringValue = llmKeys[provider] ?? ""
                    lastLLMIndex = i
                    break
                }
            }
        }
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        onComplete?()
        onComplete = nil
    }
}
