import Cocoa

class VoiceSettingsVC: NSObject {

    private let config = ConfigService.shared
    lazy var view: NSView = buildView()

    // ASR controls
    private var asrPopup: NSPopUpButton!
    private var asrKeyField: NSTextField!
    private var asrKeyRow: NSView!
    private var asrBaseURLField: NSTextField!
    private var asrBaseURLRow: NSView!
    private var asrModelField: NSTextField!
    private var asrModelRow: NSView!
    private var whisperExecField: NSTextField!
    private var whisperExecRow: NSView!
    private var whisperModelField: NSTextField!
    private var whisperModelRow: NSView!

    // LLM controls
    private var llmPopup: NSPopUpButton!
    private var llmKeyField: NSTextField!
    private var llmKeyRow: NSView!
    private var llmBaseURLField: NSTextField!
    private var llmBaseURLRow: NSView!
    private var llmModelField: NSTextField!
    private var llmModelRow: NSView!
    private var llmFormatPopup: NSPopUpButton!
    private var llmFormatRow: NSView!

    // Per-provider key caches
    private var llmKeys: [String: String] = [:]
    private var savedASRKey: String = ""

    // Track previous selection so llmProviderChanged can cache the key to the provider
    // we're leaving (not the one we're entering — indexOfSelectedItem returns the new value
    // by the time the action fires).
    private var lastLLMIndex: Int = 0

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        // ── ASR PROVIDER ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Speech Recognition"))

        asrPopup = NSPopUpButton()
        for p in SetupWindow.asrProviders {
            asrPopup.addItem(withTitle: p.name)
        }
        selectCurrentASR()
        asrPopup.target = self
        asrPopup.action = #selector(asrProviderChanged)
        asrPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "ASR Provider", control: asrPopup))

        // ASR config card
        let asrCard = SettingsUI.makeConfigCard()

        let asrCardStack = NSStackView()
        asrCardStack.orientation = .vertical
        asrCardStack.spacing = 8
        asrCardStack.translatesAutoresizingMaskIntoConstraints = false
        asrCard.addSubview(asrCardStack)
        NSLayoutConstraint.activate([
            asrCardStack.topAnchor.constraint(equalTo: asrCard.topAnchor, constant: 12),
            asrCardStack.bottomAnchor.constraint(equalTo: asrCard.bottomAnchor, constant: -12),
            asrCardStack.leadingAnchor.constraint(equalTo: asrCard.leadingAnchor, constant: 16),
            asrCardStack.trailingAnchor.constraint(equalTo: asrCard.trailingAnchor, constant: -16),
        ])

        asrKeyField = NSSecureTextField()
        asrKeyField.placeholderString = "API Key"
        asrKeyField.font = .systemFont(ofSize: 12)
        asrKeyRow = SettingsUI.makeCardRow(label: "API Key", field: asrKeyField)
        asrCardStack.addArrangedSubview(asrKeyRow)

        asrBaseURLField = NSTextField()
        asrBaseURLField.placeholderString = "https://..."
        asrBaseURLField.font = .systemFont(ofSize: 12)
        asrBaseURLRow = SettingsUI.makeCardRow(label: "Base URL", field: asrBaseURLField)
        asrCardStack.addArrangedSubview(asrBaseURLRow)

        asrModelField = NSTextField()
        asrModelField.placeholderString = "Model name"
        asrModelField.font = .systemFont(ofSize: 12)
        asrModelRow = SettingsUI.makeCardRow(label: "Model", field: asrModelField)
        asrCardStack.addArrangedSubview(asrModelRow)

        whisperExecField = NSTextField()
        whisperExecField.stringValue = config.whisperExecPath
        whisperExecField.font = .systemFont(ofSize: 12)
        whisperExecRow = SettingsUI.makeCardRow(label: "Executable", field: whisperExecField)
        asrCardStack.addArrangedSubview(whisperExecRow)

        whisperModelField = NSTextField()
        whisperModelField.stringValue = config.whisperModelPath
        whisperModelField.font = .systemFont(ofSize: 12)
        whisperModelRow = SettingsUI.makeCardRow(label: "Model", field: whisperModelField)
        asrCardStack.addArrangedSubview(whisperModelRow)

        stack.addArrangedSubview(asrCard)

        loadASRFields()
        updateASRFieldVisibility()

        let saveASRBtn = SettingsUI.makeButton("Save ASR Config")
        saveASRBtn.target = self
        saveASRBtn.action = #selector(saveASRConfig)
        stack.addArrangedSubview(saveASRBtn)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── LLM PROVIDER ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Post-Processing (LLM)"))
        stack.addArrangedSubview(SettingsUI.makeSublabel(
            "LLM cleans up raw transcription: fixes punctuation, removes filler words, and applies your custom prompt."
        ))

        llmPopup = NSPopUpButton()
        for p in SetupWindow.llmProviders {
            llmPopup.addItem(withTitle: p.name)
        }
        selectCurrentLLM()
        llmPopup.target = self
        llmPopup.action = #selector(llmProviderChanged)
        llmPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(label: "LLM Provider", control: llmPopup))

        // LLM config card
        let llmCard = SettingsUI.makeConfigCard()

        let llmCardStack = NSStackView()
        llmCardStack.orientation = .vertical
        llmCardStack.spacing = 8
        llmCardStack.translatesAutoresizingMaskIntoConstraints = false
        llmCard.addSubview(llmCardStack)
        NSLayoutConstraint.activate([
            llmCardStack.topAnchor.constraint(equalTo: llmCard.topAnchor, constant: 12),
            llmCardStack.bottomAnchor.constraint(equalTo: llmCard.bottomAnchor, constant: -12),
            llmCardStack.leadingAnchor.constraint(equalTo: llmCard.leadingAnchor, constant: 16),
            llmCardStack.trailingAnchor.constraint(equalTo: llmCard.trailingAnchor, constant: -16),
        ])

        llmKeyField = NSSecureTextField()
        llmKeyField.placeholderString = "API Key"
        llmKeyField.font = .systemFont(ofSize: 12)
        llmKeyRow = SettingsUI.makeCardRow(label: "API Key", field: llmKeyField)
        llmCardStack.addArrangedSubview(llmKeyRow)

        llmBaseURLField = NSTextField()
        llmBaseURLField.placeholderString = "https://..."
        llmBaseURLField.font = .systemFont(ofSize: 12)
        llmBaseURLRow = SettingsUI.makeCardRow(label: "Base URL", field: llmBaseURLField)
        llmCardStack.addArrangedSubview(llmBaseURLRow)

        llmModelField = NSTextField()
        llmModelField.placeholderString = "Model name"
        llmModelField.font = .systemFont(ofSize: 12)
        llmModelRow = SettingsUI.makeCardRow(label: "Model", field: llmModelField)
        llmCardStack.addArrangedSubview(llmModelRow)

        llmFormatPopup = NSPopUpButton()
        llmFormatPopup.addItems(withTitles: ["OpenAI", "Anthropic"])
        llmFormatRow = SettingsUI.makeCardRow(label: "Format", field: NSTextField()) // placeholder
        // Replace with a proper popup row
        llmFormatRow.subviews.forEach { $0.removeFromSuperview() }
        let fmtLabel = SettingsUI.makeLabel("Format")
        fmtLabel.translatesAutoresizingMaskIntoConstraints = false
        llmFormatPopup.translatesAutoresizingMaskIntoConstraints = false
        llmFormatRow.addSubview(fmtLabel)
        llmFormatRow.addSubview(llmFormatPopup)
        NSLayoutConstraint.activate([
            fmtLabel.leadingAnchor.constraint(equalTo: llmFormatRow.leadingAnchor),
            fmtLabel.centerYAnchor.constraint(equalTo: llmFormatRow.centerYAnchor),
            fmtLabel.widthAnchor.constraint(equalToConstant: 80),
            llmFormatPopup.leadingAnchor.constraint(equalTo: fmtLabel.trailingAnchor, constant: 8),
            llmFormatPopup.trailingAnchor.constraint(equalTo: llmFormatRow.trailingAnchor),
            llmFormatPopup.centerYAnchor.constraint(equalTo: llmFormatRow.centerYAnchor),
            llmFormatRow.heightAnchor.constraint(equalToConstant: 28),
        ])
        llmCardStack.addArrangedSubview(llmFormatRow)

        stack.addArrangedSubview(llmCard)

        loadLLMFields()
        updateLLMFieldVisibility()

        let saveLLMBtn = SettingsUI.makeButton("Save LLM Config")
        saveLLMBtn.target = self
        saveLLMBtn.action = #selector(saveLLMConfig)
        stack.addArrangedSubview(saveLLMBtn)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── PROMPT ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Custom Prompt"))

        let editPromptBtn = SettingsUI.makeButton("Edit Prompt File")
        editPromptBtn.target = self
        editPromptBtn.action = #selector(editPrompt)
        stack.addArrangedSubview(editPromptBtn)

        return scroll
    }

    // MARK: - ASR Selection

    private func selectCurrentASR() {
        let current = config.asrProvider
        if let idx = SetupWindow.asrProviders.firstIndex(where: { $0.configKey == current }) {
            asrPopup.selectItem(at: idx)
        }
    }

    private func loadASRFields() {
        let current = config.asrProvider
        switch current {
        case "qwen":
            asrKeyField.stringValue = config.qwenASRApiKey ?? ""
            savedASRKey = asrKeyField.stringValue
        case "custom":
            if let cfg = config.customASRConfig {
                asrBaseURLField.stringValue = cfg.baseURL
                asrKeyField.stringValue = cfg.apiKey
                asrModelField.stringValue = cfg.model
            }
        case "whisper":
            whisperExecField.stringValue = config.whisperExecPath
            whisperModelField.stringValue = config.whisperModelPath
        default:
            break
        }
    }

    private func updateASRFieldVisibility() {
        let idx = asrPopup.indexOfSelectedItem
        guard idx >= 0 && idx < SetupWindow.asrProviders.count else { return }
        let key = SetupWindow.asrProviders[idx].configKey

        asrKeyRow.isHidden = (key == "whisper")
        asrBaseURLRow.isHidden = (key != "custom")
        asrModelRow.isHidden = (key != "custom")
        whisperExecRow.isHidden = (key != "whisper")
        whisperModelRow.isHidden = (key != "whisper")
    }

    @objc private func asrProviderChanged() {
        updateASRFieldVisibility()
    }

    @objc private func saveASRConfig() {
        let idx = asrPopup.indexOfSelectedItem
        guard idx >= 0 && idx < SetupWindow.asrProviders.count else { return }
        let provider = SetupWindow.asrProviders[idx]

        config.write(key: "asr", value: provider.configKey)

        switch provider.configKey {
        case "qwen":
            let key = asrKeyField.stringValue.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                config.write(key: "qwen-asr", value: ["apiKey": key])
            }
        case "custom":
            let base = asrBaseURLField.stringValue.trimmingCharacters(in: .whitespaces)
            let key = asrKeyField.stringValue.trimmingCharacters(in: .whitespaces)
            let model = asrModelField.stringValue.trimmingCharacters(in: .whitespaces)
            config.write(key: "custom-asr", value: [
                "baseURL": base, "apiKey": key, "model": model,
            ])
        case "whisper":
            let exec = whisperExecField.stringValue.trimmingCharacters(in: .whitespaces)
            let model = whisperModelField.stringValue.trimmingCharacters(in: .whitespaces)
            config.write(key: "whisper", value: ["executablePath": exec, "modelPath": model])
        default:
            break
        }

        config.reload()
        NSLog("Vox: ASR config saved — provider: \(provider.configKey)")
    }

    // MARK: - LLM Selection

    private func selectCurrentLLM() {
        let current = config.llmProvider ?? "none"
        if let idx = SetupWindow.llmProviders.firstIndex(where: { $0.configKey == current }) {
            llmPopup.selectItem(at: idx)
            lastLLMIndex = idx
        }
    }

    private func loadLLMFields() {
        guard let providerKey = config.llmProvider else { return }
        if let cfg = config.llmProviderConfig(for: providerKey) {
            llmKeyField.stringValue = cfg.apiKey
            llmBaseURLField.stringValue = cfg.baseURL
            llmModelField.stringValue = cfg.model
            if let fmt = cfg.format {
                llmFormatPopup.selectItem(withTitle: fmt == "anthropic" ? "Anthropic" : "OpenAI")
            }
            llmKeys[providerKey] = cfg.apiKey
        }
    }

    private func updateLLMFieldVisibility() {
        let idx = llmPopup.indexOfSelectedItem
        guard idx >= 0 && idx < SetupWindow.llmProviders.count else { return }
        let provider = SetupWindow.llmProviders[idx]

        let isNone = provider.configKey == "none"
        let isCustom = provider.configKey == "custom-llm"

        llmKeyRow.isHidden = isNone
        llmBaseURLRow.isHidden = !isCustom
        llmModelRow.isHidden = !isCustom
        llmFormatRow.isHidden = !isCustom

        // Pre-fill from provider defaults when switching (unless custom)
        if !isNone && !isCustom {
            llmBaseURLField.stringValue = provider.baseURL
            llmModelField.stringValue = provider.model
            llmFormatPopup.selectItem(withTitle: provider.format == "anthropic" ? "Anthropic" : "OpenAI")
            // Restore cached key for this provider
            if let cached = llmKeys[provider.configKey] {
                llmKeyField.stringValue = cached
            } else {
                llmKeyField.stringValue = ""
            }
        }
    }

    @objc private func llmProviderChanged() {
        // Cache the key under the PREVIOUS provider (indexOfSelectedItem is already the new value here).
        if lastLLMIndex >= 0 && lastLLMIndex < SetupWindow.llmProviders.count {
            let prevKey = SetupWindow.llmProviders[lastLLMIndex].configKey
            if prevKey != "none" && !llmKeyField.stringValue.isEmpty {
                llmKeys[prevKey] = llmKeyField.stringValue
            }
        }
        updateLLMFieldVisibility()
        lastLLMIndex = llmPopup.indexOfSelectedItem
    }

    @objc private func saveLLMConfig() {
        let idx = llmPopup.indexOfSelectedItem
        guard idx >= 0 && idx < SetupWindow.llmProviders.count else { return }
        let provider = SetupWindow.llmProviders[idx]

        if provider.configKey == "none" {
            config.write(key: "provider", value: "none")
        } else {
            config.write(key: "provider", value: provider.configKey)

            let key = llmKeyField.stringValue.trimmingCharacters(in: .whitespaces)
            let baseURL = provider.configKey == "custom-llm"
                ? llmBaseURLField.stringValue.trimmingCharacters(in: .whitespaces)
                : provider.baseURL
            let model = provider.configKey == "custom-llm"
                ? llmModelField.stringValue.trimmingCharacters(in: .whitespaces)
                : provider.model
            let format = provider.configKey == "custom-llm"
                ? (llmFormatPopup.indexOfSelectedItem == 1 ? "anthropic" : "openai")
                : provider.format

            var cfgDict: [String: Any] = [
                "baseURL": baseURL,
                "apiKey": key,
                "model": model,
            ]
            cfgDict["format"] = format
            config.write(key: provider.configKey, value: cfgDict)
        }

        config.reload()
        NSLog("Vox: LLM config saved — provider: \(provider.configKey)")
    }

    @objc private func editPrompt() {
        let promptPath = NSHomeDirectory() + "/.vox/prompt.txt"
        if !FileManager.default.fileExists(atPath: promptPath) {
            let dir = NSHomeDirectory() + "/.vox"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? LLMService.defaultPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: promptPath))
    }
}
