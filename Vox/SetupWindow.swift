import Cocoa
import Carbon.HIToolbox

class SetupWindow: NSObject, NSWindowDelegate {

    // MARK: - Types

    enum Step: Int {
        case welcome = 0
        case hotkeyMode = 1
        case apiConfig = 2
        case historySettings = 3
        case test = 4
        case complete = 5
    }

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

    // MARK: - Provider Data

    static let asrProviders = [
        ASRProvider(name: "Alibaba Qwen ASR", configKey: "qwen"),
        ASRProvider(name: "Local Whisper", configKey: "whisper"),
        ASRProvider(name: "Custom", configKey: "custom"),
    ]

    static let llmProviders = [
        LLMProvider(name: "Kimi", configKey: "kimi",
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
        LLMProvider(name: "Custom", configKey: "custom-llm",
                    baseURL: "", model: "", format: "openai"),
        LLMProvider(name: "None (Skip post-processing)", configKey: "none",
                    baseURL: "", model: "", format: ""),
    ]

    // MARK: - Properties

    private var window: NSWindow!
    private var contentContainer: NSView!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var stepDots: [NSView] = []
    private var currentStep: Step = .welcome
    private var isOnboarding = true

    // API config controls
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
    private var asrHintLabel: NSTextField!
    private var llmPopup: NSPopUpButton!
    private var llmKeyField: NSTextField!
    private var llmKeyRow: NSView!
    private var llmBaseURLField: NSTextField!
    private var llmBaseURLRow: NSView!
    private var llmModelField: NSTextField!
    private var llmModelRow: NSView!
    private var llmFormatPopup: NSPopUpButton!
    private var llmFormatRow: NSView!
    private var configStatusLabel: NSTextField!

    // Per-provider key storage
    private var llmKeys: [String: String] = [:]
    private var lastLLMIndex: Int = 0
    private var savedASRKey: String = ""
    private var selectedASRIndex: Int = 0

    // Custom provider saved values
    private var savedCustomASR: (baseURL: String, apiKey: String, model: String) = ("", "", "")
    private var savedWhisperPaths: (exec: String, model: String) = (
        "/opt/homebrew/bin/whisper-cli",
        NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
    )
    private var savedCustomLLM: (baseURL: String, model: String, format: String) = ("", "", "openai")

    // Hotkey mode
    private var selectedHotkeyMode: String = "toggle"
    private var toggleCard: NSView?
    private var holdCard: NSView?

    // Test recording
    private var testRecorder: AudioService?
    private var testResultField: NSTextField!
    private var testResultCard: NSView?
    private var testButton: NSButton!
    private var testStatusLabel: NSTextField!
    private var testIsRecording = false

    // Custom hotkey
    private var selectedKeyCode: UInt32 = UInt32(kVK_ANSI_Grave)
    private var selectedModifiers: UInt32 = UInt32(controlKey)
    private var hotkeyRecorder: HotkeyRecorderView?

    // Audio visualization
    private var audioLevelView: AudioLevelView?

    // History settings
    private var historyEnabledCheckbox: NSButton?
    private var historyRetentionPopup: NSPopUpButton?

    private var onComplete: (() -> Void)?

    // MARK: - Step sequence

    private var steps: [Step] {
        if isOnboarding {
            return [.welcome, .hotkeyMode, .apiConfig, .historySettings, .test, .complete]
        } else {
            return [.hotkeyMode, .apiConfig, .historySettings]
        }
    }

    private var currentStepIndex: Int {
        return steps.firstIndex(of: currentStep) ?? 0
    }

    // MARK: - Show

    func show(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        let configPath = NSHomeDirectory() + "/.vox/config.json"
        isOnboarding = !FileManager.default.fileExists(atPath: configPath)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Vox"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        let root = window.contentView!

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)

        let nav = buildNavBar()
        nav.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nav)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: nav.topAnchor),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            nav.heightAnchor.constraint(equalToConstant: 60),
        ])

        loadExistingConfig()
        navigateTo(steps[0])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Nav Bar

    private func buildNavBar() -> NSView {
        let bar = NSView()

        backButton = NSButton(title: "Back", target: self, action: #selector(prevStep))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(backButton)

        let dotsStack = NSStackView()
        dotsStack.orientation = .horizontal
        dotsStack.spacing = 8
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        stepDots = []
        for _ in steps {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            dotsStack.addArrangedSubview(dot)
            stepDots.append(dot)
        }
        bar.addSubview(dotsStack)

        nextButton = NSButton(title: "Continue", target: self, action: #selector(nextStep))
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(nextButton)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 28),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dotsStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            dotsStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -28),
            nextButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return bar
    }

    // MARK: - Navigation

    private func navigateTo(_ step: Step) {
        // Save state before leaving current step
        if currentStep == .hotkeyMode, let recorder = hotkeyRecorder {
            selectedKeyCode = recorder.keyCode
            selectedModifiers = recorder.modifiers
        }
        if currentStep == .apiConfig && asrPopup != nil {
            captureAPIConfigState()
        }

        currentStep = step
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let view: NSView
        switch step {
        case .welcome:
            view = buildWelcome()
        case .hotkeyMode:
            view = buildHotkeyMode()
        case .apiConfig:
            view = buildAPIConfig()
            applyConfigState()
        case .historySettings:
            view = buildHistorySettings()
        case .test:
            view = buildTest()
        case .complete:
            view = buildComplete()
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        updateNavBar()

        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            view.animator().alphaValue = 1.0
        }
    }

    private func updateNavBar() {
        let idx = currentStepIndex
        backButton.isHidden = (idx == 0)

        switch currentStep {
        case .welcome:
            nextButton.title = "Get Started"
        case .historySettings where !isOnboarding:
            nextButton.title = "Save"
        case .test:
            nextButton.title = "Finish Setup"
        case .complete:
            nextButton.title = "Start Using Vox"
        default:
            nextButton.title = "Continue"
        }

        for (i, dot) in stepDots.enumerated() {
            if i == idx {
                dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else if i < idx {
                dot.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
            } else {
                dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            }
        }
    }

    // MARK: - Next / Prev

    @objc private func nextStep() {
        // Complete step always closes
        if currentStep == .complete {
            window.close()
            return
        }

        // Capture hotkey state before leaving hotkeyMode
        if currentStep == .hotkeyMode, let recorder = hotkeyRecorder {
            selectedKeyCode = recorder.keyCode
            selectedModifiers = recorder.modifiers
        }

        if currentStep == .apiConfig {
            if !validateAndSaveConfig() { return }
        }

        if currentStep == .historySettings {
            saveHistorySettings()
        }

        let idx = currentStepIndex
        if idx + 1 < steps.count {
            navigateTo(steps[idx + 1])
        } else {
            window.close()
        }
    }

    @objc private func prevStep() {
        let idx = currentStepIndex
        if idx > 0 {
            navigateTo(steps[idx - 1])
        }
    }

    // MARK: - Step 1: Welcome

    private func buildWelcome() -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
        ])

        // App icon (larger, no text title since icon already says VOX)
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
        ])
        stack.addArrangedSubview(iconView)

        let tagline = NSTextField(labelWithString: "You speak, Vox types.")
        tagline.font = .systemFont(ofSize: 20, weight: .medium)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        stack.addArrangedSubview(tagline)

        return container
    }

    // MARK: - Step 2: Hotkey Mode

    private func buildHotkeyMode() -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
        ])

        let title = NSTextField(labelWithString: "How do you want to record?")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        stack.addArrangedSubview(title)

        // Mode cards
        let cardsRow = NSStackView()
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 20
        cardsRow.distribution = .fillEqually

        let tCard = buildModeCard(
            title: "Toggle",
            icon: "⏯",
            description: "Press hotkey to start.\nPress again to stop.",
            tag: 0
        )
        toggleCard = tCard
        cardsRow.addArrangedSubview(tCard)

        let hCard = buildModeCard(
            title: "Hold to Talk",
            icon: "🎤",
            description: "Hold hotkey while speaking.\nRelease to stop.",
            tag: 1
        )
        holdCard = hCard
        cardsRow.addArrangedSubview(hCard)

        stack.addArrangedSubview(cardsRow)
        cardsRow.widthAnchor.constraint(equalToConstant: 500).isActive = true

        // Hotkey picker
        let hotkeySection = NSStackView()
        hotkeySection.orientation = .horizontal
        hotkeySection.alignment = .centerY
        hotkeySection.spacing = 12

        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        hotkeyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hotkeyLabel.textColor = .labelColor
        hotkeySection.addArrangedSubview(hotkeyLabel)

        let recorder = HotkeyRecorderView(keyCode: selectedKeyCode, modifiers: selectedModifiers)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 36).isActive = true
        recorder.onHotkeyChanged = { [weak self] code, mods in
            self?.selectedKeyCode = code
            self?.selectedModifiers = mods
        }
        hotkeyRecorder = recorder
        hotkeySection.addArrangedSubview(recorder)

        let hotkeyHint = NSTextField(labelWithString: "Click to change")
        hotkeyHint.font = .systemFont(ofSize: 12)
        hotkeyHint.textColor = .tertiaryLabelColor
        hotkeySection.addArrangedSubview(hotkeyHint)

        stack.addArrangedSubview(hotkeySection)

        updateModeCards()

        return container
    }

    private func buildModeCard(title: String, icon: String, description: String, tag: Int) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 2
        card.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),
        ])

        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = .systemFont(ofSize: 36)
        iconLabel.alignment = .center
        stack.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        descLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(descLabel)

        let tap = NSClickGestureRecognizer(target: self, action: #selector(modeCardTapped(_:)))
        card.addGestureRecognizer(tap)

        return card
    }

    @objc private func modeCardTapped(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view else { return }
        selectedHotkeyMode = (view === toggleCard) ? "toggle" : "hold"
        updateModeCards()
    }

    private func updateModeCards() {
        let accent = NSColor.controlAccentColor
        let normal = NSColor.separatorColor.withAlphaComponent(0.3)

        toggleCard?.layer?.borderColor = selectedHotkeyMode == "toggle" ? accent.cgColor : normal.cgColor
        toggleCard?.layer?.borderWidth = selectedHotkeyMode == "toggle" ? 2.5 : 1.0
        toggleCard?.layer?.backgroundColor = selectedHotkeyMode == "toggle"
            ? accent.withAlphaComponent(0.06).cgColor
            : NSColor.controlBackgroundColor.cgColor

        holdCard?.layer?.borderColor = selectedHotkeyMode == "hold" ? accent.cgColor : normal.cgColor
        holdCard?.layer?.borderWidth = selectedHotkeyMode == "hold" ? 2.5 : 1.0
        holdCard?.layer?.backgroundColor = selectedHotkeyMode == "hold"
            ? accent.withAlphaComponent(0.06).cgColor
            : NSColor.controlBackgroundColor.cgColor
    }

    // MARK: - Step 3: API Config

    private func buildAPIConfig() -> NSView {
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 48, bottom: 24, right: 48)

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = stack
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        let title = NSTextField(labelWithString: "Configure Services")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        stack.addArrangedSubview(title)

        // ASR section
        let (asrCard, asrKeyRowRef) = buildASRSection()
        asrKeyRow = asrKeyRowRef
        stack.addArrangedSubview(asrCard)
        asrCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96).isActive = true

        // LLM section
        let (llmCard, llmKeyRowRef) = buildLLMSection()
        llmKeyRow = llmKeyRowRef
        stack.addArrangedSubview(llmCard)
        llmCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96).isActive = true

        // Permissions note
        let permNote = NSTextField(wrappingLabelWithString: "Vox needs Microphone and Accessibility permissions. macOS will prompt when needed.")
        permNote.font = .systemFont(ofSize: 12)
        permNote.textColor = .tertiaryLabelColor
        permNote.alignment = .center
        stack.addArrangedSubview(permNote)

        // Status
        configStatusLabel = NSTextField(labelWithString: "")
        configStatusLabel.font = .systemFont(ofSize: 13)
        configStatusLabel.textColor = .systemRed
        configStatusLabel.alignment = .center
        configStatusLabel.isBordered = false
        configStatusLabel.isEditable = false
        configStatusLabel.backgroundColor = .clear
        stack.addArrangedSubview(configStatusLabel)

        return container
    }

    private func buildASRSection() -> (NSView, NSView) {
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 20)

        let header = makeSectionHeader("Speech Recognition")
        cardStack.addArrangedSubview(header)

        let providerRow = makeFormRow(label: "Provider")
        asrPopup = NSPopUpButton()
        asrPopup.translatesAutoresizingMaskIntoConstraints = false
        asrPopup.font = .systemFont(ofSize: 13)
        for p in SetupWindow.asrProviders { asrPopup.addItem(withTitle: p.name) }
        asrPopup.target = self
        asrPopup.action = #selector(asrProviderChanged)
        providerRow.addArrangedSubview(asrPopup)
        asrPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(providerRow)
        providerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Qwen API Key row
        let keyRow = makeFormRow(label: "API Key")
        asrKeyField = NSTextField()
        asrKeyField.translatesAutoresizingMaskIntoConstraints = false
        asrKeyField.placeholderString = "sk-..."
        asrKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        asrKeyField.lineBreakMode = .byTruncatingMiddle
        keyRow.addArrangedSubview(asrKeyField)
        asrKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(keyRow)
        keyRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Custom ASR: Base URL
        let baseURLRow = makeFormRow(label: "Base URL")
        asrBaseURLField = NSTextField()
        asrBaseURLField.translatesAutoresizingMaskIntoConstraints = false
        asrBaseURLField.placeholderString = "https://api.groq.com/openai/v1/audio/transcriptions"
        asrBaseURLField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        asrBaseURLField.lineBreakMode = .byTruncatingMiddle
        baseURLRow.addArrangedSubview(asrBaseURLField)
        asrBaseURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(baseURLRow)
        baseURLRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        asrBaseURLRow = baseURLRow

        // Custom ASR: Model
        let modelRow = makeFormRow(label: "Model")
        asrModelField = NSTextField()
        asrModelField.translatesAutoresizingMaskIntoConstraints = false
        asrModelField.placeholderString = "whisper-large-v3-turbo"
        asrModelField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        modelRow.addArrangedSubview(asrModelField)
        asrModelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(modelRow)
        modelRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        asrModelRow = modelRow

        // Local Whisper: Executable Path
        let execRow = makeFormRow(label: "Executable")
        whisperExecField = NSTextField()
        whisperExecField.translatesAutoresizingMaskIntoConstraints = false
        whisperExecField.placeholderString = "/opt/homebrew/bin/whisper-cli"
        whisperExecField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        whisperExecField.lineBreakMode = .byTruncatingMiddle
        execRow.addArrangedSubview(whisperExecField)
        whisperExecField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(execRow)
        execRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        whisperExecRow = execRow

        // Local Whisper: Model Path
        let whisperModelRow = makeFormRow(label: "Model File")
        whisperModelField = NSTextField()
        whisperModelField.translatesAutoresizingMaskIntoConstraints = false
        whisperModelField.placeholderString = "~/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
        whisperModelField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        whisperModelField.lineBreakMode = .byTruncatingMiddle
        whisperModelRow.addArrangedSubview(whisperModelField)
        whisperModelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(whisperModelRow)
        whisperModelRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        self.whisperModelRow = whisperModelRow

        // Hint text (changes based on provider)
        asrHintLabel = NSTextField(labelWithString: "Get your key from bailian.console.aliyun.com")
        asrHintLabel.font = .systemFont(ofSize: 11)
        asrHintLabel.textColor = .tertiaryLabelColor
        asrHintLabel.isBordered = false
        asrHintLabel.isEditable = false
        asrHintLabel.backgroundColor = .clear
        cardStack.addArrangedSubview(asrHintLabel)

        return (card, keyRow)
    }

    private func buildLLMSection() -> (NSView, NSView) {
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 20)

        let header = makeSectionHeader("Text Post-Processing (Optional)")
        cardStack.addArrangedSubview(header)

        let desc = NSTextField(wrappingLabelWithString: "An LLM cleans up your speech: removes filler words, fixes typos, adds punctuation.")
        desc.font = .systemFont(ofSize: 13)
        desc.textColor = .secondaryLabelColor
        cardStack.addArrangedSubview(desc)

        let providerRow = makeFormRow(label: "Provider")
        llmPopup = NSPopUpButton()
        llmPopup.translatesAutoresizingMaskIntoConstraints = false
        llmPopup.font = .systemFont(ofSize: 13)
        for p in SetupWindow.llmProviders { llmPopup.addItem(withTitle: p.name) }
        llmPopup.target = self
        llmPopup.action = #selector(llmProviderChanged)
        providerRow.addArrangedSubview(llmPopup)
        llmPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(providerRow)
        providerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Custom LLM: Base URL
        let baseURLRow = makeFormRow(label: "Base URL")
        llmBaseURLField = NSTextField()
        llmBaseURLField.translatesAutoresizingMaskIntoConstraints = false
        llmBaseURLField.placeholderString = "http://localhost:11434/v1/chat/completions"
        llmBaseURLField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        llmBaseURLField.lineBreakMode = .byTruncatingMiddle
        baseURLRow.addArrangedSubview(llmBaseURLField)
        llmBaseURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(baseURLRow)
        baseURLRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        llmBaseURLRow = baseURLRow

        // Custom LLM: Model
        let modelRow = makeFormRow(label: "Model")
        llmModelField = NSTextField()
        llmModelField.translatesAutoresizingMaskIntoConstraints = false
        llmModelField.placeholderString = "qwen2.5:7b"
        llmModelField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        modelRow.addArrangedSubview(llmModelField)
        llmModelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(modelRow)
        modelRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        llmModelRow = modelRow

        // API Key
        let keyRow = makeFormRow(label: "API Key")
        llmKeyField = NSTextField()
        llmKeyField.translatesAutoresizingMaskIntoConstraints = false
        llmKeyField.placeholderString = "sk-..."
        llmKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        llmKeyField.lineBreakMode = .byTruncatingMiddle
        keyRow.addArrangedSubview(llmKeyField)
        llmKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(keyRow)
        keyRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

        // Custom LLM: Format
        let formatRow = makeFormRow(label: "Format")
        llmFormatPopup = NSPopUpButton()
        llmFormatPopup.translatesAutoresizingMaskIntoConstraints = false
        llmFormatPopup.font = .systemFont(ofSize: 13)
        llmFormatPopup.addItems(withTitles: ["OpenAI Compatible", "Anthropic Compatible"])
        formatRow.addArrangedSubview(llmFormatPopup)
        llmFormatPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardStack.addArrangedSubview(formatRow)
        formatRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        llmFormatRow = formatRow

        return (card, keyRow)
    }

    // MARK: - Step 4: Test

    private func buildTest() -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
        ])

        let title = NSTextField(labelWithString: "Let's try it out")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Press the button below and say something.\nWe'll transcribe it to make sure everything works.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        stack.addArrangedSubview(subtitle)

        let spacer1 = NSView()
        spacer1.translatesAutoresizingMaskIntoConstraints = false
        spacer1.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer1)

        // Record button
        testButton = NSButton(title: "   Start Recording   ", target: self, action: #selector(testRecordToggle))
        testButton.bezelStyle = .rounded
        testButton.font = .systemFont(ofSize: 16, weight: .medium)
        testButton.controlSize = .large
        stack.addArrangedSubview(testButton)

        // Audio level visualization
        let levelView = AudioLevelView()
        levelView.translatesAutoresizingMaskIntoConstraints = false
        levelView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        levelView.widthAnchor.constraint(equalToConstant: 360).isActive = true
        levelView.isHidden = true
        stack.addArrangedSubview(levelView)
        audioLevelView = levelView

        // Status
        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .systemFont(ofSize: 14)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.alignment = .center
        testStatusLabel.isBordered = false
        testStatusLabel.isEditable = false
        testStatusLabel.backgroundColor = .clear
        stack.addArrangedSubview(testStatusLabel)

        // Result card
        let resultCard = makeCard()
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        resultCard.isHidden = true

        testResultField = NSTextField(wrappingLabelWithString: "")
        testResultField.font = .systemFont(ofSize: 16)
        testResultField.textColor = .labelColor
        testResultField.alignment = .center
        testResultField.isBordered = false
        testResultField.isEditable = false
        testResultField.backgroundColor = .clear
        testResultField.translatesAutoresizingMaskIntoConstraints = false
        resultCard.addSubview(testResultField)
        pinInside(testResultField, to: resultCard, inset: 20)

        stack.addArrangedSubview(resultCard)
        resultCard.widthAnchor.constraint(equalToConstant: 480).isActive = true
        resultCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        testResultCard = resultCard

        return container
    }

    @objc private func testRecordToggle() {
        if testIsRecording {
            // Stop recording
            testIsRecording = false
            testButton.isEnabled = false
            testButton.title = "   Processing...   "
            testStatusLabel.stringValue = "Transcribing your speech..."
            audioLevelView?.isHidden = true

            guard let url = testRecorder?.stopRecording() else {
                testStatusLabel.stringValue = "Recording failed. Try again."
                testButton.title = "   Start Recording   "
                testButton.isEnabled = true
                return
            }

            testRecorder = nil

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let rawText = STTService.shared.transcribe(audioFile: url)
                let cleanText = LLMService.shared.process(rawText: rawText)
                let finalText = cleanText.isEmpty ? rawText : cleanText

                DispatchQueue.main.async {
                    if finalText.isEmpty {
                        self?.testResultCard?.isHidden = true
                        self?.testStatusLabel.stringValue = "Could not recognize speech. Try again."
                    } else {
                        self?.testResultCard?.isHidden = false
                        self?.testResultField.stringValue = finalText
                        self?.testStatusLabel.stringValue = "Here's what we heard:"
                    }
                    self?.testButton.title = "   Try Again   "
                    self?.testButton.isEnabled = true
                }
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            // Start recording
            testIsRecording = true
            testRecorder = AudioService.shared
            testRecorder?.onAudioLevel = { [weak self] level in
                DispatchQueue.main.async {
                    self?.audioLevelView?.updateLevel(level)
                }
            }
            testRecorder?.startRecording()
            testButton.title = "   Stop Recording   "
            testStatusLabel.stringValue = "Listening..."
            NSSound(named: "Tink")?.play()

            // Show audio visualization, hide previous result
            audioLevelView?.reset()
            audioLevelView?.isHidden = false
            testResultCard?.isHidden = true
        }
    }

    // MARK: - Step 5: Complete

    // MARK: - Step: History Settings

    private func buildHistorySettings() -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
        ])

        // Title
        let title = NSTextField(labelWithString: "History Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Save your voice input results so you can find and copy them later.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        stack.addArrangedSubview(subtitle)

        // Card
        let card = makeCard()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 20
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        pinInside(cardStack, to: card, inset: 28)

        // Retention period (includes Never = disabled)
        let retentionRow = NSStackView()
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 12
        retentionRow.alignment = .centerY

        let retentionLabel = NSTextField(labelWithString: "Keep records for:")
        retentionLabel.font = .systemFont(ofSize: 15)
        retentionLabel.textColor = .labelColor
        retentionRow.addArrangedSubview(retentionLabel)

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Never", "1 day", "7 days", "30 days", "Forever"])
        let currentDays = HistoryService.shared.retentionDays
        let enabled = HistoryService.shared.isEnabled
        if !enabled {
            popup.selectItem(at: 0) // Never
        } else {
            switch currentDays {
            case 1: popup.selectItem(at: 1)
            case 30: popup.selectItem(at: 3)
            case 0: popup.selectItem(at: 4) // Forever
            default: popup.selectItem(at: 2) // 7 days
            }
        }
        popup.font = .systemFont(ofSize: 13)
        historyRetentionPopup = popup
        retentionRow.addArrangedSubview(popup)

        cardStack.addArrangedSubview(retentionRow)

        // Info text
        let info = NSTextField(wrappingLabelWithString: "Only polished results are saved (not raw transcriptions).\nYou can view and manage history from the menu bar.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .tertiaryLabelColor
        cardStack.addArrangedSubview(info)

        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalToConstant: 440).isActive = true

        return container
    }

    private func saveHistorySettings() {
        let popupIndex = historyRetentionPopup?.indexOfSelectedItem ?? 2

        if popupIndex == 0 {
            // "Never" — disable history
            HistoryService.shared.isEnabled = false
            NSLog("Vox: History settings saved — disabled (Never)")
        } else {
            HistoryService.shared.isEnabled = true
            let daysMap = [1: 1, 2: 7, 3: 30, 4: 0] // 0 = forever
            let days = daysMap[popupIndex] ?? 7
            HistoryService.shared.retentionDays = days
            NSLog("Vox: History settings saved — enabled, retention: \(days == 0 ? "forever" : "\(days) days")")
        }
    }

    // MARK: - Step: Complete

    private func buildComplete() -> NSView {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
        ])

        // Checkmark
        let check = NSTextField(labelWithString: "✓")
        check.font = .systemFont(ofSize: 56, weight: .ultraLight)
        check.textColor = .systemGreen
        check.alignment = .center
        stack.addArrangedSubview(check)

        let title = NSTextField(labelWithString: "You're all set!")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        stack.addArrangedSubview(title)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer)

        // Tip card
        let tipCard = makeCard()
        let tipStack = NSStackView()
        tipStack.orientation = .vertical
        tipStack.alignment = .centerX
        tipStack.spacing = 12
        tipStack.translatesAutoresizingMaskIntoConstraints = false
        tipCard.addSubview(tipStack)
        pinInside(tipStack, to: tipCard, inset: 24)

        let tipTitle = NSTextField(labelWithString: "Find Vox in your menu bar")
        tipTitle.font = .systemFont(ofSize: 17, weight: .medium)
        tipTitle.textColor = .labelColor
        tipTitle.alignment = .center
        tipStack.addArrangedSubview(tipTitle)

        let hotkeyStr = HotkeyRecorderView.hotkeyString(keyCode: selectedKeyCode, modifiers: selectedModifiers)
        let modeHint: String
        if selectedHotkeyMode == "hold" {
            modeHint = "Hold  \(hotkeyStr)  while speaking, release to get text."
        } else {
            modeHint = "Press  \(hotkeyStr)  to start speaking, press again to stop."
        }

        let tipDesc = NSTextField(wrappingLabelWithString: "Look for the microphone icon at the top-right of your screen.\nClick it anytime for settings.\n\n\(modeHint)")
        tipDesc.font = .systemFont(ofSize: 14)
        tipDesc.textColor = .secondaryLabelColor
        tipDesc.alignment = .center
        tipStack.addArrangedSubview(tipDesc)

        stack.addArrangedSubview(tipCard)
        tipCard.widthAnchor.constraint(equalToConstant: 440).isActive = true

        return container
    }

    // MARK: - Config: Validate & Save

    private func validateAndSaveConfig() -> Bool {
        let asrIndex = asrPopup.indexOfSelectedItem
        let llmIndex = llmPopup.indexOfSelectedItem
        let asrProvider = SetupWindow.asrProviders[asrIndex]
        let llmProvider = SetupWindow.llmProviders[llmIndex]

        if asrProvider.configKey == "qwen" && asrKeyField.stringValue.isEmpty {
            configStatusLabel.stringValue = "Please enter your Qwen ASR API key."
            return false
        }
        if asrProvider.configKey == "custom" {
            if asrBaseURLField.stringValue.isEmpty {
                configStatusLabel.stringValue = "Please enter your custom ASR endpoint URL."
                return false
            }
            if asrKeyField.stringValue.isEmpty {
                configStatusLabel.stringValue = "Please enter your custom ASR API key."
                return false
            }
        }
        if llmProvider.configKey == "custom-llm" {
            if llmBaseURLField.stringValue.isEmpty {
                configStatusLabel.stringValue = "Please enter your custom LLM endpoint URL."
                return false
            }
        } else if llmProvider.configKey != "none" && llmProvider.configKey != "qwen-llm" && llmKeyField.stringValue.isEmpty {
            configStatusLabel.stringValue = "Please enter your LLM API key, or select None."
            return false
        }

        configStatusLabel.stringValue = ""
        saveConfig()
        return true
    }

    private func saveConfig() {
        // Safety net: always read latest values from recorder
        if let recorder = hotkeyRecorder {
            selectedKeyCode = recorder.keyCode
            selectedModifiers = recorder.modifiers
        }

        let asrIndex = asrPopup.indexOfSelectedItem
        let llmIndex = llmPopup.indexOfSelectedItem
        let asrProvider = SetupWindow.asrProviders[asrIndex]
        let llmProvider = SetupWindow.llmProviders[llmIndex]

        var config: [String: Any] = [
            "asr": asrProvider.configKey,
            "hotkeyMode": selectedHotkeyMode,
            "hotkeyKeyCode": Int(selectedKeyCode),
            "hotkeyModifiers": Int(selectedModifiers),
            "userContext": ""
        ]

        // Always save qwen-asr key
        let qwenKey: String
        if asrProvider.configKey == "qwen" {
            qwenKey = asrKeyField.stringValue
        } else if !savedASRKey.isEmpty {
            qwenKey = savedASRKey
        } else {
            let configPath = NSHomeDirectory() + "/.vox/config.json"
            if let data = FileManager.default.contents(atPath: configPath),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let qwenConfig = existing["qwen-asr"] as? [String: Any],
               let key = qwenConfig["apiKey"] as? String {
                qwenKey = key
            } else {
                qwenKey = ""
            }
        }
        if !qwenKey.isEmpty {
            config["qwen-asr"] = ["apiKey": qwenKey]
        }

        // Save custom ASR config
        if asrProvider.configKey == "custom" {
            config["custom-asr"] = [
                "baseURL": asrBaseURLField.stringValue,
                "apiKey": asrKeyField.stringValue,
                "model": asrModelField.stringValue
            ]
        } else if !savedCustomASR.baseURL.isEmpty {
            config["custom-asr"] = [
                "baseURL": savedCustomASR.baseURL,
                "apiKey": savedCustomASR.apiKey,
                "model": savedCustomASR.model
            ]
        }

        // Save local whisper paths
        let whisperExec = asrProvider.configKey == "whisper" ? whisperExecField.stringValue : savedWhisperPaths.exec
        let whisperModel = asrProvider.configKey == "whisper" ? whisperModelField.stringValue : savedWhisperPaths.model
        config["whisper"] = [
            "executablePath": whisperExec,
            "modelPath": whisperModel
        ]

        // Save current LLM key
        if llmProvider.configKey != "none" {
            if llmProvider.configKey == "qwen-llm" {
                llmKeys["qwen-llm"] = asrKeyField.stringValue
            } else {
                llmKeys[llmProvider.configKey] = llmKeyField.stringValue
            }
            config["provider"] = llmProvider.configKey
        }

        // Write all built-in provider keys
        for p in SetupWindow.llmProviders where p.configKey != "none" && p.configKey != "custom-llm" {
            if let key = llmKeys[p.configKey], !key.isEmpty {
                config[p.configKey] = [
                    "baseURL": p.baseURL,
                    "apiKey": key,
                    "model": p.model,
                    "format": p.format
                ]
            }
        }

        // Save custom LLM config
        if llmProvider.configKey == "custom-llm" {
            let format = llmFormatPopup.indexOfSelectedItem == 0 ? "openai" : "anthropic"
            config["custom-llm"] = [
                "baseURL": llmBaseURLField.stringValue,
                "apiKey": llmKeyField.stringValue,
                "model": llmModelField.stringValue,
                "format": format
            ]
        } else if !savedCustomLLM.baseURL.isEmpty {
            config["custom-llm"] = [
                "baseURL": savedCustomLLM.baseURL,
                "apiKey": llmKeys["custom-llm"] ?? "",
                "model": savedCustomLLM.model,
                "format": savedCustomLLM.format
            ]
        }

        // Preserve userContext
        let configPath = NSHomeDirectory() + "/.vox/config.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ctx = existing["userContext"] as? String, !ctx.isEmpty {
            config["userContext"] = ctx
        }

        let configDir = NSHomeDirectory() + "/.vox"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        if let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: configPath))
            NSLog("Vox: Config saved")
        }
    }

    // MARK: - Config: Load & Apply

    private func loadExistingConfig() {
        let configPath = NSHomeDirectory() + "/.vox/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let mode = json["hotkeyMode"] as? String {
            selectedHotkeyMode = mode
        }

        if let keyCode = json["hotkeyKeyCode"] as? Int {
            selectedKeyCode = UInt32(keyCode)
        }
        if let modifiers = json["hotkeyModifiers"] as? Int {
            selectedModifiers = UInt32(modifiers)
        }

        if let qwenConfig = json["qwen-asr"] as? [String: Any],
           let key = qwenConfig["apiKey"] as? String {
            savedASRKey = key
        }

        if let asr = json["asr"] as? String {
            for (i, p) in SetupWindow.asrProviders.enumerated() {
                if p.configKey == asr {
                    selectedASRIndex = i
                    break
                }
            }
        }

        // Load custom ASR config
        if let customASR = json["custom-asr"] as? [String: Any] {
            savedCustomASR = (
                customASR["baseURL"] as? String ?? "",
                customASR["apiKey"] as? String ?? "",
                customASR["model"] as? String ?? ""
            )
        }

        // Load local whisper paths
        if let whisperConfig = json["whisper"] as? [String: Any] {
            savedWhisperPaths = (
                whisperConfig["executablePath"] as? String ?? "/opt/homebrew/bin/whisper-cli",
                whisperConfig["modelPath"] as? String ?? NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
            )
        }

        // Load custom LLM config
        if let customLLM = json["custom-llm"] as? [String: Any] {
            savedCustomLLM = (
                customLLM["baseURL"] as? String ?? "",
                customLLM["model"] as? String ?? "",
                customLLM["format"] as? String ?? "openai"
            )
            if let key = customLLM["apiKey"] as? String {
                llmKeys["custom-llm"] = key
            }
        }

        for p in SetupWindow.llmProviders where p.configKey != "none" {
            if let providerConfig = json[p.configKey] as? [String: Any],
               let key = providerConfig["apiKey"] as? String {
                llmKeys[p.configKey] = key
            }
        }

        if let provider = json["provider"] as? String {
            for (i, p) in SetupWindow.llmProviders.enumerated() {
                if p.configKey == provider {
                    lastLLMIndex = i
                    break
                }
            }
        }
    }

    /// Apply saved config state to freshly-built API config controls
    private func applyConfigState() {
        guard asrPopup != nil else { return }

        asrPopup.selectItem(at: selectedASRIndex)
        let asrProvider = SetupWindow.asrProviders[selectedASRIndex]

        // ASR field visibility
        asrKeyRow.isHidden = asrProvider.configKey == "whisper"
        asrBaseURLRow.isHidden = asrProvider.configKey != "custom"
        asrModelRow.isHidden = asrProvider.configKey != "custom"
        whisperExecRow.isHidden = asrProvider.configKey != "whisper"
        whisperModelRow.isHidden = asrProvider.configKey != "whisper"

        switch asrProvider.configKey {
        case "qwen":
            asrKeyField.stringValue = savedASRKey
            asrHintLabel.stringValue = "Get your key from bailian.console.aliyun.com"
        case "whisper":
            whisperExecField.stringValue = savedWhisperPaths.exec
            whisperModelField.stringValue = savedWhisperPaths.model
            asrHintLabel.stringValue = "Install: brew install whisper-cpp && whisper-cpp-download-ggml-model large-v3-turbo"
        case "custom":
            asrBaseURLField.stringValue = savedCustomASR.baseURL
            asrKeyField.stringValue = savedCustomASR.apiKey
            asrModelField.stringValue = savedCustomASR.model
            asrHintLabel.stringValue = "OpenAI Whisper API compatible endpoint (Groq, Azure, etc.)"
        default:
            break
        }

        // LLM field visibility
        llmPopup.selectItem(at: lastLLMIndex)
        let llmProvider = SetupWindow.llmProviders[lastLLMIndex]
        let isNone = llmProvider.configKey == "none"
        let isQwenLLM = llmProvider.configKey == "qwen-llm"
        let isCustomLLM = llmProvider.configKey == "custom-llm"

        llmKeyRow.isHidden = isNone || isQwenLLM
        llmBaseURLRow.isHidden = !isCustomLLM
        llmModelRow.isHidden = !isCustomLLM
        llmFormatRow.isHidden = !isCustomLLM

        if isCustomLLM {
            llmBaseURLField.stringValue = savedCustomLLM.baseURL
            llmModelField.stringValue = savedCustomLLM.model
            llmFormatPopup.selectItem(at: savedCustomLLM.format == "anthropic" ? 1 : 0)
            llmKeyField.stringValue = llmKeys["custom-llm"] ?? ""
        } else if isQwenLLM {
            llmKeyField.stringValue = asrKeyField.stringValue
        } else {
            llmKeyField.stringValue = llmKeys[llmProvider.configKey] ?? ""
        }
    }

    /// Capture current API config UI state back to properties
    private func captureAPIConfigState() {
        selectedASRIndex = asrPopup.indexOfSelectedItem
        let asrProvider = SetupWindow.asrProviders[selectedASRIndex]

        switch asrProvider.configKey {
        case "qwen":
            if !asrKeyField.stringValue.isEmpty { savedASRKey = asrKeyField.stringValue }
        case "custom":
            savedCustomASR = (asrBaseURLField.stringValue, asrKeyField.stringValue, asrModelField.stringValue)
        case "whisper":
            savedWhisperPaths = (whisperExecField.stringValue, whisperModelField.stringValue)
        default:
            break
        }

        let llmIndex = llmPopup.indexOfSelectedItem
        let llmProvider = SetupWindow.llmProviders[llmIndex]
        if llmProvider.configKey == "custom-llm" {
            savedCustomLLM = (llmBaseURLField.stringValue, llmModelField.stringValue,
                              llmFormatPopup.indexOfSelectedItem == 0 ? "openai" : "anthropic")
            llmKeys["custom-llm"] = llmKeyField.stringValue
        } else if llmProvider.configKey != "none" && llmProvider.configKey != "qwen-llm" {
            llmKeys[llmProvider.configKey] = llmKeyField.stringValue
        }
        lastLLMIndex = llmIndex
    }

    // MARK: - Provider Change Actions

    @objc private func asrProviderChanged() {
        let index = asrPopup.indexOfSelectedItem
        let provider = SetupWindow.asrProviders[index]

        // Save current values before switching
        let oldIndex = selectedASRIndex
        let oldProvider = SetupWindow.asrProviders[oldIndex]
        if oldProvider.configKey == "qwen" && !asrKeyField.stringValue.isEmpty {
            savedASRKey = asrKeyField.stringValue
        } else if oldProvider.configKey == "custom" {
            savedCustomASR = (asrBaseURLField.stringValue, asrKeyField.stringValue, asrModelField.stringValue)
        } else if oldProvider.configKey == "whisper" {
            savedWhisperPaths = (whisperExecField.stringValue, whisperModelField.stringValue)
        }

        // Show/hide rows based on new selection
        switch provider.configKey {
        case "qwen":
            asrKeyRow.isHidden = false
            asrBaseURLRow.isHidden = true
            asrModelRow.isHidden = true
            whisperExecRow.isHidden = true
            whisperModelRow.isHidden = true
            asrKeyField.stringValue = savedASRKey
            asrHintLabel.stringValue = "Get your key from bailian.console.aliyun.com"
            asrHintLabel.isHidden = false
        case "whisper":
            asrKeyRow.isHidden = true
            asrBaseURLRow.isHidden = true
            asrModelRow.isHidden = true
            whisperExecRow.isHidden = false
            whisperModelRow.isHidden = false
            whisperExecField.stringValue = savedWhisperPaths.exec
            whisperModelField.stringValue = savedWhisperPaths.model
            asrHintLabel.stringValue = "Install: brew install whisper-cpp && whisper-cpp-download-ggml-model large-v3-turbo"
            asrHintLabel.isHidden = false
        case "custom":
            asrKeyRow.isHidden = false
            asrBaseURLRow.isHidden = false
            asrModelRow.isHidden = false
            whisperExecRow.isHidden = true
            whisperModelRow.isHidden = true
            asrBaseURLField.stringValue = savedCustomASR.baseURL
            asrKeyField.stringValue = savedCustomASR.apiKey
            asrModelField.stringValue = savedCustomASR.model
            asrHintLabel.stringValue = "OpenAI Whisper API compatible endpoint (Groq, Azure, etc.)"
            asrHintLabel.isHidden = false
        default:
            break
        }
        selectedASRIndex = index
    }

    @objc private func llmProviderChanged() {
        let oldProvider = SetupWindow.llmProviders[lastLLMIndex]
        if oldProvider.configKey != "none" {
            llmKeys[oldProvider.configKey] = llmKeyField.stringValue
        }
        if oldProvider.configKey == "custom-llm" {
            savedCustomLLM = (llmBaseURLField.stringValue, llmModelField.stringValue,
                              llmFormatPopup.indexOfSelectedItem == 0 ? "openai" : "anthropic")
        }

        let newIndex = llmPopup.indexOfSelectedItem
        let newProvider = SetupWindow.llmProviders[newIndex]
        let isNone = newProvider.configKey == "none"
        let isQwenLLM = newProvider.configKey == "qwen-llm"
        let isCustom = newProvider.configKey == "custom-llm"

        llmKeyRow.isHidden = isNone || isQwenLLM
        llmBaseURLRow.isHidden = !isCustom
        llmModelRow.isHidden = !isCustom
        llmFormatRow.isHidden = !isCustom

        if isQwenLLM {
            llmKeyField.stringValue = asrKeyField.stringValue
        } else if isCustom {
            llmBaseURLField.stringValue = savedCustomLLM.baseURL
            llmModelField.stringValue = savedCustomLLM.model
            llmFormatPopup.selectItem(at: savedCustomLLM.format == "anthropic" ? 1 : 0)
            llmKeyField.stringValue = llmKeys["custom-llm"] ?? ""
        } else {
            llmKeyField.stringValue = llmKeys[newProvider.configKey] ?? ""
        }
        lastLLMIndex = newIndex
    }

    // MARK: - UI Helpers

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        card.layer?.borderWidth = 0.5
        return card
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
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
        row.spacing = 10

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.isBordered = false
        labelField.isEditable = false
        labelField.backgroundColor = .clear
        labelField.widthAnchor.constraint(equalToConstant: 75).isActive = true
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

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        if testIsRecording {
            testRecorder?.stopRecording()
            testRecorder = nil
            testIsRecording = false
        }
        onComplete?()
        onComplete = nil
    }
}

// MARK: - Hotkey Recorder View

class HotkeyRecorderView: NSView {
    var keyCode: UInt32
    var modifiers: UInt32
    private var isRecording = false
    var onHotkeyChanged: ((UInt32, UInt32) -> Void)?

    private let label: NSTextField
    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.isBordered = false
        label.isEditable = false
        label.backgroundColor = .clear
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        currentModifiers = []
        window?.makeFirstResponder(self)
        updateDisplay()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            currentModifiers = []
            updateDisplay()
        }
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording {
            currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            updateDisplay()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.intersection([.control, .option, .shift, .command]).isEmpty else {
                NSSound.beep()
                return
            }

            keyCode = UInt32(event.keyCode)
            modifiers = carbonModifiers(from: mods)
            isRecording = false
            currentModifiers = []
            updateDisplay()
            onHotkeyChanged?(keyCode, modifiers)
        }
    }

    private func updateDisplay() {
        if isRecording {
            if currentModifiers.intersection([.control, .option, .shift, .command]).isEmpty {
                label.stringValue = "Type shortcut..."
                label.textColor = .secondaryLabelColor
            } else {
                label.stringValue = modifierString(from: currentModifiers) + "..."
                label.textColor = .labelColor
            }
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        } else {
            label.stringValue = HotkeyRecorderView.hotkeyString(keyCode: keyCode, modifiers: modifiers)
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func modifierString(from flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    static func hotkeyString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
            0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
            0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
            0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N",
            0x2E: "M", 0x2F: ".",
            0x32: "`",
            0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "Esc",
            0x75: "⌦",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
            0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        ]
        return names[keyCode] ?? "Key(\(keyCode))"
    }
}

// MARK: - Audio Level Visualization

class AudioLevelView: NSView {
    private var barLayers: [CALayer] = []
    private var levels: [CGFloat] = []
    private let barCount = 30
    private let barSpacing: CGFloat = 2.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        levels = Array(repeating: 0, count: barCount)
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.controlAccentColor.cgColor
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        redrawBars()
    }

    func updateLevel(_ level: Float) {
        levels.removeFirst()
        let normalized = CGFloat(max(0, min(1, (level + 50) / 40)))
        levels.append(normalized)
        redrawBars()
    }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        redrawBars()
    }

    private func redrawBars() {
        guard bounds.width > 0 else { return }
        let totalSpacing = barSpacing * CGFloat(barCount - 1)
        let barWidth = max(2, (bounds.width - totalSpacing) / CGFloat(barCount))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let level = levels[i]
            let minH: CGFloat = 3
            let h = max(minH, level * bounds.height)
            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - h) / 2

            bar.frame = CGRect(x: x, y: y, width: barWidth, height: h)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(max(0.3, level)).cgColor
        }
        CATransaction.commit()
    }
}
