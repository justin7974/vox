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

    /// Called when setup wizard needs to be shown (no config)
    var onNeedsSetup: (() -> Void)?

    // MARK: - Public API (called by AppDelegate via HotkeyDelegate)

    func hotkeyPressed(mode: String) {
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
            stopAndProcess()
        }
    }

    func cancelIfRecording() {
        if case .recording = sm.phase {
            _ = audio.stopRecording()
        }
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
            stopAndProcess()
        default:
            break
        }
    }

    private func startRecording() {
        guard sm.transition(to: .recording) else { return }
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

        // Translate mode must be captured on main thread before we leave it.
        let isTranslate = AppDelegate.shared.translateMode
        let llmConfigured = llm.isConfigured

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

        // Translate mode requires LLM; abort immediately if not configured rather than pasting raw text as "translation".
        if isTranslate && !llmConfigured {
            NSLog("Vox: Translate mode requires LLM but none configured — aborting")
            sm.transition(to: .idle)
            overlay.show(phase: sm.phase)
            NSSound(named: "Basso")?.play()
            AppDelegate.showNotification(title: "Vox", message: "Translate mode requires an LLM. Configure one in Settings.")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        guard sm.transition(to: .transcribing) else {
            try? FileManager.default.removeItem(at: audioURL)
            return
        }
        overlay.show(phase: sm.phase)
        NSSound(named: "Pop")?.play()
        NSLog("Vox: Recording stopped (\(fileSize) bytes, peak: \(audio.peakPower) dB), processing...")

        // AppleScript-based context detection can block the main thread for seconds if the browser
        // is unresponsive. Run it concurrently with transcription off the main thread.
        let contextTask = Task.detached(priority: .userInitiated) { [context] in
            let ctx = context.detect()
            return context.contextHint(for: ctx)
        }

        Task { [weak self] in
            guard let self = self else { return }

            self.log.debug("Step 1: Transcribe start (file: \(audioURL.lastPathComponent))")
            let rawText = await self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Step 1: Transcribe result: characters=\(rawText.count)")

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

            let contextHint = await contextTask.value
            self.log.debug("Step 2: LLM start (context present: \(contextHint != nil), translate: \(isTranslate))")
            // Translate mode must not fall back to raw text — we already aborted above if LLM missing.
            let cleanText = await self.llm.process(rawText: rawText, contextHint: contextHint, translateMode: isTranslate, requireLLM: isTranslate, applyAliases: !isTranslate)

            if isTranslate && cleanText.isEmpty {
                self.log.debug("Translate: LLM returned empty, aborting")
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.show(phase: self.sm.phase)
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            let postProcessed = cleanText.isEmpty ? rawText : cleanText
            self.log.debug("Step 2: LLM result: characters=\(postProcessed.count)")

            let finalText: String
            if self.llm.isConfigured {
                finalText = postProcessed
                self.log.debug("Step 3: Skipped TextFormatter (LLM active)")
            } else {
                finalText = TextFormatter.format(postProcessed)
                self.log.debug("Step 3: TextFormatter applied: characters=\(finalText.count)")
            }

            self.log.debug("Step 4: Pasting...")
            await MainActor.run {
                self.sm.transition(to: .pasting)
                self.paste.paste(text: finalText, completion: { dispatched in
                    self.log.debug("Step 4: Paste dispatched=\(dispatched)")
                    // Keep the recoverable dictation even when dispatch failed.
                    if isTranslate {
                        self.history.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                    } else {
                        self.history.addRecord(text: finalText)
                    }
                    guard dispatched else {
                        self.sm.transition(to: .idle)
                        self.overlay.hide()
                        return
                    }

                    self.sm.transition(to: .idle)
                    self.overlay.show(phase: self.sm.phase)
                    NSSound(named: "Glass")?.play()
                })
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

}
