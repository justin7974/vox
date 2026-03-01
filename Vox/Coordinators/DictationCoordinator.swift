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
        sm.transition(to: .recording(.dictation))
        overlay.show(phase: sm.phase)
        audio.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        audio.startRecording()
        NSSound(named: "Tink")?.play()
        NSLog("Vox: Recording started")
    }

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

                self.sm.transition(to: .idle)
                self.overlay.show(phase: self.sm.phase)
                NSSound(named: "Glass")?.play()
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }
}
