import Cocoa

class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var asrPopup: NSPopUpButton!
    private var asrKeyField: NSSecureTextField!
    private var llmPopup: NSPopUpButton!
    private var llmKeyField: NSSecureTextField!
    private var statusLabel: NSTextField!

    // Pre-configured providers (CodePilot pattern: user only inputs API key)
    struct ASRProvider {
        let name: String
        let configKey: String  // key in config.json
    }

    struct LLMProvider {
        let name: String
        let configKey: String
        let baseURL: String
        let model: String
        let format: String  // "anthropic" or "openai"
    }

    static let asrProviders = [
        ASRProvider(name: "Alibaba Qwen ASR (Recommended)", configKey: "qwen"),
        ASRProvider(name: "Local Whisper (No API needed)", configKey: "whisper"),
    ]

    static let llmProviders = [
        LLMProvider(name: "Kimi (Recommended)", configKey: "kimi",
                    baseURL: "https://api.kimi.com/coding/v1/messages", model: "kimi-k2.5",
                    format: "anthropic"),
        LLMProvider(name: "MiniMax (CN)", configKey: "minimax",
                    baseURL: "https://api.minimaxi.com/anthropic/v1/messages", model: "MiniMax-M2.5",
                    format: "anthropic"),
        LLMProvider(name: "MiniMax (Global)", configKey: "minimax-global",
                    baseURL: "https://api.minimax.io/anthropic/v1/messages", model: "MiniMax-M2.5",
                    format: "anthropic"),
        LLMProvider(name: "Moonshot", configKey: "moonshot",
                    baseURL: "https://api.moonshot.cn/anthropic/v1/messages", model: "moonshot-v1-auto",
                    format: "anthropic"),
        LLMProvider(name: "GLM 智谱 (CN)", configKey: "glm",
                    baseURL: "https://open.bigmodel.cn/api/anthropic/v1/messages", model: "glm-4-plus",
                    format: "anthropic"),
        LLMProvider(name: "GLM 智谱 (Global)", configKey: "glm-global",
                    baseURL: "https://api.z.ai/api/anthropic/v1/messages", model: "glm-4-plus",
                    format: "anthropic"),
        LLMProvider(name: "DeepSeek", configKey: "deepseek",
                    baseURL: "https://api.deepseek.com/chat/completions", model: "deepseek-chat",
                    format: "openai"),
        LLMProvider(name: "OpenRouter", configKey: "openrouter",
                    baseURL: "https://openrouter.ai/api/v1/chat/completions", model: "anthropic/claude-haiku",
                    format: "openai"),
        LLMProvider(name: "None (Skip post-processing)", configKey: "none",
                    baseURL: "", model: "",
                    format: ""),
    ]

    private var onComplete: (() -> Void)?

    func show(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "VoiceInput Setup"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        var y: CGFloat = 440

        // Title
        let title = makeLabel("Welcome to VoiceInput", bold: true, size: 18)
        title.frame = NSRect(x: 30, y: y, width: 460, height: 30)
        content.addSubview(title)
        y -= 25

        let subtitle = makeLabel("AI-powered voice input for macOS. Press Ctrl+` to speak, text appears at your cursor.")
        subtitle.frame = NSRect(x: 30, y: y, width: 460, height: 20)
        content.addSubview(subtitle)
        y -= 45

        // Section 1: ASR (Speech-to-Text)
        let asrTitle = makeLabel("Step 1: Speech Recognition", bold: true, size: 14)
        asrTitle.frame = NSRect(x: 30, y: y, width: 460, height: 22)
        content.addSubview(asrTitle)
        y -= 30

        let asrDesc = makeLabel("Choose your speech-to-text provider:")
        asrDesc.frame = NSRect(x: 30, y: y, width: 460, height: 18)
        content.addSubview(asrDesc)
        y -= 30

        asrPopup = NSPopUpButton(frame: NSRect(x: 30, y: y, width: 460, height: 26))
        for p in SetupWindow.asrProviders { asrPopup.addItem(withTitle: p.name) }
        asrPopup.target = self
        asrPopup.action = #selector(asrProviderChanged)
        content.addSubview(asrPopup)
        y -= 30

        let asrKeyLabel = makeLabel("API Key (get it from bailian.console.aliyun.com):")
        asrKeyLabel.frame = NSRect(x: 30, y: y, width: 460, height: 18)
        asrKeyLabel.tag = 100
        content.addSubview(asrKeyLabel)
        y -= 26

        asrKeyField = NSSecureTextField(frame: NSRect(x: 30, y: y, width: 460, height: 24))
        asrKeyField.placeholderString = "sk-..."
        content.addSubview(asrKeyField)
        y -= 40

        // Section 2: LLM (Post-processing)
        let llmTitle = makeLabel("Step 2: Text Post-Processing (Optional)", bold: true, size: 14)
        llmTitle.frame = NSRect(x: 30, y: y, width: 460, height: 22)
        content.addSubview(llmTitle)
        y -= 25

        let llmDesc = makeLabel("LLM cleans up ASR output: removes filler words, fixes typos, adds punctuation.")
        llmDesc.frame = NSRect(x: 30, y: y, width: 460, height: 18)
        content.addSubview(llmDesc)
        y -= 30

        llmPopup = NSPopUpButton(frame: NSRect(x: 30, y: y, width: 460, height: 26))
        for p in SetupWindow.llmProviders { llmPopup.addItem(withTitle: p.name) }
        llmPopup.target = self
        llmPopup.action = #selector(llmProviderChanged)
        content.addSubview(llmPopup)
        y -= 30

        let llmKeyLabel = makeLabel("API Key:")
        llmKeyLabel.frame = NSRect(x: 30, y: y, width: 460, height: 18)
        llmKeyLabel.tag = 200
        content.addSubview(llmKeyLabel)
        y -= 26

        llmKeyField = NSSecureTextField(frame: NSRect(x: 30, y: y, width: 460, height: 24))
        llmKeyField.placeholderString = "sk-..."
        content.addSubview(llmKeyField)
        y -= 45

        // Section 3: Permissions reminder
        let permTitle = makeLabel("Step 3: Grant Permissions", bold: true, size: 14)
        permTitle.frame = NSRect(x: 30, y: y, width: 460, height: 22)
        content.addSubview(permTitle)
        y -= 25

        let permDesc = makeLabel("macOS will ask for Microphone and Accessibility permissions.\nGrant both in System Settings > Privacy & Security.")
        permDesc.frame = NSRect(x: 30, y: y, width: 460, height: 36)
        content.addSubview(permDesc)
        y -= 50

        // Status label
        statusLabel = makeLabel("")
        statusLabel.textColor = .systemRed
        statusLabel.frame = NSRect(x: 30, y: y + 10, width: 300, height: 18)
        content.addSubview(statusLabel)

        // Save button
        let saveBtn = NSButton(frame: NSRect(x: 380, y: y + 5, width: 110, height: 32))
        saveBtn.title = "Save & Start"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveConfig)
        content.addSubview(saveBtn)

        // Load existing config if present
        loadExistingConfig()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func asrProviderChanged() {
        let isQwen = asrPopup.indexOfSelectedItem == 0
        asrKeyField.isEnabled = isQwen
        if !isQwen {
            asrKeyField.stringValue = ""
        }
    }

    @objc private func llmProviderChanged() {
        let isNone = llmPopup.indexOfSelectedItem == SetupWindow.llmProviders.count - 1
        llmKeyField.isEnabled = !isNone
        if isNone {
            llmKeyField.stringValue = ""
        }
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

        if llmProvider.configKey != "none" {
            config["provider"] = llmProvider.configKey
            config[llmProvider.configKey] = [
                "baseURL": llmProvider.baseURL,
                "apiKey": llmKeyField.stringValue,
                "model": llmProvider.model,
                "format": llmProvider.format
            ]
        }

        // Ensure directory exists
        let configDir = NSHomeDirectory() + "/.voiceinput"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        // Write config
        let configPath = configDir + "/config.json"
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
                asrKeyField.isEnabled = false
            } else if asr == "qwen" {
                asrPopup.selectItem(at: 0)
                if let qwenConfig = json["qwen-asr"] as? [String: Any],
                   let key = qwenConfig["apiKey"] as? String {
                    asrKeyField.stringValue = key
                }
            }
        }

        // LLM provider
        if let provider = json["provider"] as? String {
            for (i, p) in SetupWindow.llmProviders.enumerated() {
                if p.configKey == provider {
                    llmPopup.selectItem(at: i)
                    if let providerConfig = json[provider] as? [String: Any],
                       let key = providerConfig["apiKey"] as? String {
                        llmKeyField.stringValue = key
                    }
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.maximumNumberOfLines = 3
        return label
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        // If user closes without saving, still proceed (they can open settings later)
        onComplete?()
        onComplete = nil
    }
}
