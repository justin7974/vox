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

    private(set) var state: AppState = .idle

    /// Called when setup wizard needs to be shown (no config)
    var onNeedsSetup: (() -> Void)?

    // MARK: - Public API (called by AppDelegate via HotkeyDelegate)

    func hotkeyPressed(mode: String) {
        switch mode {
        case "hold":
            if state == .idle {
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
        if mode == "hold" && state == .recording {
            stopAndProcess()
        }
    }

    func cancelIfRecording() {
        if state == .recording {
            _ = audio.stopRecording()
        }
    }

    // MARK: - Recording

    private func toggleRecording() {
        switch state {
        case .idle:
            guard config.configExists else {
                AppDelegate.showNotification(title: "Vox", message: "Please configure your API keys first.")
                onNeedsSetup?()
                return
            }
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            break
        }
    }

    private func startRecording() {
        state = .recording
        overlay.show(state: state)
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
            state = .idle
            overlay.show(state: state)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Recording too short (\(fileSize) bytes), ignoring")
            state = .idle
            overlay.show(state: state)
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        if !audio.hasAudio {
            NSLog("Vox: No audio detected (peak: \(audio.peakPower) dB), skipping")
            state = .idle
            overlay.show(state: state)
            NSSound(named: "Basso")?.play()
            AppDelegate.showNotification(title: "Vox", message: "No audio detected. Check your microphone.")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        state = .processing
        overlay.show(state: state)
        NSSound(named: "Pop")?.play()
        NSLog("Vox: Recording stopped (\(fileSize) bytes, peak: \(audio.peakPower) dB), processing...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.log.debug("Step 1: Transcribe start (file: \(audioURL.lastPathComponent))")
            let rawText = self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Step 1: Transcribe result: [\(rawText)]")

            guard !rawText.isEmpty else {
                self.log.debug("Step 1: Empty result, aborting")
                DispatchQueue.main.async {
                    self.state = .idle
                    self.overlay.show(state: self.state)
                    AppDelegate.showNotification(title: "Vox", message: "Could not recognize speech. Try again.")
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            self.log.debug("Step 2: LLM start (context: \(contextHint ?? "none"), translate: \(isTranslate))")
            let cleanText = self.llm.process(rawText: rawText, contextHint: contextHint, translateMode: isTranslate)
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
            DispatchQueue.main.async {
                self.paste.paste(text: finalText)
                self.log.debug("Step 4: Paste done")

                if isTranslate {
                    self.history.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                } else {
                    self.history.addRecord(text: finalText)
                }

                self.state = .idle
                self.overlay.show(state: self.state)
                NSSound(named: "Glass")?.play()
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }
}
