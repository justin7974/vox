import Cocoa

class DictationCoordinator {
    private let log = LogService.shared
    private let config = ConfigService.shared
    private let audio = AudioService.shared
    private let stt = STTService.shared
    private let llm = LLMService.shared
    private let paste = PasteService.shared
    private let context = ContextService.shared
    private let history = HistoryService.shared
    private let overlay = StatusOverlay()

    private let sm = VoxStateMachine()

    // Edit window state
    private var lastInsertedText: String?
    private var lastInsertedLength: Int = 0
    private var editWindowTimer: Timer?
    private var keyEventMonitor: Any?
    private var isInEditMode: Bool = false

    /// Called when setup wizard needs to be shown (no config)
    var onNeedsSetup: (() -> Void)?

    // MARK: - Public API (called by AppDelegate via HotkeyDelegate)

    func hotkeyPressed(mode: String) {
        // Edit window intercept: re-pressing hotkey enters edit recording
        if sm.phase == .editWindow {
            startEditRecording()
            return
        }

        switch mode {
        case "hold":
            if sm.phase == .idle {
                guard config.configExists else {
                    AppDelegate.showNotification(title: "Vox", message: "Please configure your API keys first.")
                    onNeedsSetup?()
                    return
                }
                startRecording()
            }
        default: // toggle
            toggleRecording()
        }
    }

    func hotkeyReleased(mode: String) {
        if mode == "hold", case .recording = sm.phase {
            if isInEditMode {
                stopAndProcessEdit()
            } else {
                stopAndProcess()
            }
        }
    }

    func cancelIfRecording() {
        if case .recording = sm.phase {
            _ = audio.stopRecording()
        }
        cancelEditWindowCleanup()
        isInEditMode = false
    }

    // MARK: - Recording

    private func toggleRecording() {
        switch sm.phase {
        case .idle:
            guard config.configExists else {
                AppDelegate.showNotification(title: "Vox", message: "Please configure your API keys first.")
                onNeedsSetup?()
                return
            }
            startRecording()
        case .recording:
            if isInEditMode {
                stopAndProcessEdit()
            } else {
                stopAndProcess()
            }
        default:
            break
        }
    }

    private func startRecording() {
        sm.transition(to: .recording)
        overlay.show(phase: sm.phase)
        audio.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        audio.startRecording()
        NSSound(named: "Tink")?.play()
        NSLog("Vox: Recording started")
    }

    // MARK: - Normal Dictation Pipeline

    private func stopAndProcess() {
        audio.onAudioLevel = nil

        // Capture app context and translate mode NOW on the main thread
        let appContext = context.detect()
        let contextHint = context.contextHint(for: appContext)
        let isTranslate = AppDelegate.shared.translateMode

        guard let audioURL = audio.stopRecording() else {
            sm.transition(to: .idle)
            overlay.show(phase: sm.phase)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Recording too short (\(fileSize) bytes), ignoring")
            sm.transition(to: .idle)
            overlay.show(phase: sm.phase)
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        if !audio.hasAudio {
            NSLog("Vox: No audio detected (peak: \(audio.peakPower) dB), skipping")
            sm.transition(to: .idle)
            overlay.show(phase: sm.phase)
            NSSound(named: "Basso")?.play()
            AppDelegate.showNotification(title: "Vox", message: "No audio detected. Check your microphone.")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        sm.transition(to: .transcribing)
        overlay.show(phase: sm.phase)
        NSSound(named: "Pop")?.play()
        NSLog("Vox: Recording stopped (\(fileSize) bytes, peak: \(audio.peakPower) dB), processing...")

        Task { [weak self] in
            guard let self = self else { return }

            self.log.debug("Step 1: Transcribe start (file: \(audioURL.lastPathComponent))")
            let rawText = await self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Step 1: Transcribe result: [\(rawText)]")

            guard !rawText.isEmpty else {
                self.log.debug("Step 1: Empty result, aborting")
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.show(phase: self.sm.phase)
                    AppDelegate.showNotification(title: "Vox", message: "Could not recognize speech. Try again.")
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            await MainActor.run {
                self.sm.transition(to: .postProcessing)
            }

            self.log.debug("Step 2: LLM start (context: \(contextHint ?? "none"), translate: \(isTranslate))")
            let cleanText = await self.llm.process(rawText: rawText, contextHint: contextHint, translateMode: isTranslate)
            let postProcessed = cleanText.isEmpty ? rawText : cleanText
            self.log.debug("Step 2: LLM result: [\(postProcessed)]")

            let finalText: String
            if self.llm.isConfigured {
                finalText = postProcessed
                self.log.debug("Step 3: Skipped TextFormatter (LLM active)")
            } else {
                finalText = TextFormatter.format(postProcessed)
                self.log.debug("Step 3: TextFormatter applied: [\(finalText)]")
            }

            self.log.debug("Step 4: Pasting...")
            await MainActor.run {
                self.sm.transition(to: .pasting)
                self.paste.paste(text: finalText)
                self.log.debug("Step 4: Paste done")

                if isTranslate {
                    self.history.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                } else {
                    self.history.addRecord(text: finalText)
                }

                // Enter edit window if enabled (not for translate mode)
                if !isTranslate && self.config.editWindowEnabled && self.config.editWindowDuration > 0 {
                    self.lastInsertedText = finalText
                    self.lastInsertedLength = finalText.count
                    self.enterEditWindow()
                } else {
                    self.sm.transition(to: .idle)
                    self.overlay.show(phase: self.sm.phase)
                }

                NSSound(named: "Glass")?.play()
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    // MARK: - Edit Window

    private func enterEditWindow() {
        let duration = config.editWindowDuration
        sm.transition(to: .editWindow)
        overlay.showEditWindow(duration: duration)

        editWindowTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.expireEditWindow()
        }

        // Any other keyboard input cancels the edit window
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self = self, self.sm.phase == .editWindow else { return }
            self.expireEditWindow()
        }
    }

    private func expireEditWindow() {
        cancelEditWindowCleanup()
        if sm.phase == .editWindow {
            sm.transition(to: .idle)
            overlay.hide()
        }
        lastInsertedText = nil
        lastInsertedLength = 0
    }

    private func cancelEditWindowCleanup() {
        editWindowTimer?.invalidate()
        editWindowTimer = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    // MARK: - Edit Mode Recording

    private func startEditRecording() {
        cancelEditWindowCleanup()

        // Select last inserted text via Accessibility API
        selectLastInsertedText()

        isInEditMode = true
        sm.transition(to: .recording)
        overlay.showEditRecording()
        audio.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        audio.startRecording()
        NSSound(named: "Tink")?.play()
        NSLog("Vox: Edit recording started")
    }

    private func stopAndProcessEdit() {
        audio.onAudioLevel = nil

        guard let audioURL = audio.stopRecording() else {
            sm.transition(to: .idle)
            overlay.hide()
            isInEditMode = false
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Edit recording too short, ignoring")
            sm.transition(to: .idle)
            overlay.hide()
            isInEditMode = false
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        sm.transition(to: .transcribing)
        overlay.showEditProcessing()
        NSSound(named: "Pop")?.play()

        let originalText = lastInsertedText ?? ""

        Task { [weak self] in
            guard let self = self else { return }

            // Step 1: Transcribe the edit instruction
            let editInstruction = await self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Edit instruction: [\(editInstruction)]")

            guard !editInstruction.isEmpty else {
                self.log.debug("Edit: empty instruction, aborting")
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.hide()
                    self.isInEditMode = false
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 2: Apply edit via LLM
            await MainActor.run {
                self.sm.transition(to: .postProcessing)
            }

            let userMessage = "原文：\(originalText)\n\n修改指令：\(editInstruction)"
            let editedText = await self.llm.process(rawText: userMessage, customSystemPrompt: LLMService.editPrompt)
            self.log.debug("Edit result: [\(editedText)]")

            guard !editedText.isEmpty else {
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.hide()
                    self.isInEditMode = false
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 3: Paste edited text (replaces AX selection)
            await MainActor.run {
                self.sm.transition(to: .pasting)
                self.paste.paste(text: editedText)

                self.history.addRecord(text: editedText, originalText: originalText)

                self.sm.transition(to: .idle)
                self.overlay.showSuccess("✓ 已修改")
                NSSound(named: "Glass")?.play()

                self.isInEditMode = false
                self.lastInsertedText = nil
                self.lastInsertedLength = 0
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    // MARK: - Accessibility Helpers

    private func selectLastInsertedText() {
        guard lastInsertedLength > 0 else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log.debug("Edit: no frontmost app")
            return
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            log.debug("Edit: cannot get focused element")
            return
        }

        let element = focusedRef as! AXUIElement

        // Get total character count
        var totalChars: Int = 0
        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &numRef) == .success,
           let n = numRef as? Int {
            totalChars = n
        } else {
            // Fallback: read full text value
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let text = valueRef as? String else {
                log.debug("Edit: cannot determine text length")
                return
            }
            totalChars = text.count
        }

        let start = max(0, totalChars - lastInsertedLength)
        let length = min(lastInsertedLength, totalChars)
        var range = CFRange(location: start, length: length)

        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            log.debug("Edit: cannot create AXValue for range")
            return
        }

        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        if result == .success {
            log.debug("Edit: selected \(length) chars at offset \(start)")
        } else {
            log.debug("Edit: selection failed (status: \(result.rawValue))")
        }
    }
}
