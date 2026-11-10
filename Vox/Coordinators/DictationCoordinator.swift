import Cocoa

// Public entry points are invoked by AppKit callbacks on the main thread.
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

    var isIdle: Bool { sm.phase == .idle }

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
            AppDelegate.showNotification(title: "Vox", message: "翻译需要先配置 LLM")
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

        process(audioURL: audioURL, backupURL: audio.lastBackupURL,
                isTranslate: isTranslate, removeTemporary: true)
    }

    /// All recovery surfaces use the same state machine, alias gating and pipeline.
    @discardableResult
    func retryRecording(at url: URL? = nil, translateMode: Bool? = nil,
                        completion: ((Bool) -> Void)? = nil) -> Bool {
        guard isIdle else {
            AppDelegate.showNotification(title: "Vox", message: "Vox 正在处理，请稍后重试。")
            completion?(false)
            return false
        }
        let backups = audio.getBackups()
        guard let backup = url.flatMap({ wanted in backups.first { $0.url.standardizedFileURL == wanted.standardizedFileURL } }) ?? (url == nil ? backups.first : nil),
              FileManager.default.fileExists(atPath: backup.url.path) else {
            AppDelegate.showNotification(title: "Vox", message: "录音备份已不存在，请重新录音。")
            completion?(false)
            return false
        }
        let translate = translateMode ?? AppDelegate.shared.translateMode
        guard !translate || llm.isConfigured else {
            AppDelegate.showNotification(title: "Vox", message: "翻译需要先配置 LLM")
            completion?(false)
            return false
        }
        guard sm.transition(to: .transcribing) else { completion?(false); return false }
        overlay.show(phase: sm.phase)
        process(audioURL: backup.url, backupURL: backup.url, isTranslate: translate,
                removeTemporary: false, completion: completion)
        return true
    }

    func repasteLastText() {
        guard isIdle else { return }
        guard let text = paste.lastPastedText ?? history.getRecords().first?.text, !text.isEmpty else {
            AppDelegate.showNotification(title: "Vox", message: "还没有可重贴的文本。")
            return
        }
        guard sm.transition(to: .pasting) else { return }
        paste.paste(text: text) { [weak self] _ in
            self?.sm.transition(to: .idle)
            self?.overlay.show(phase: .idle)
        }
    }

    private func process(audioURL: URL, backupURL: URL?, isTranslate: Bool,
                         removeTemporary: Bool, completion: ((Bool) -> Void)? = nil) {
        // Context detection is slow AppleScript; never block recording/UI on it.
        let contextTask = Task.detached(priority: .userInitiated) { [context] in
            let ctx = context.detect()
            return context.contextHint(for: ctx)
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { if removeTemporary { try? FileManager.default.removeItem(at: audioURL) } }
            let rawText = await self.stt.transcribe(audioFile: audioURL)
            guard !rawText.isEmpty else {
                contextTask.cancel()
                self.processingFailed(backupURL: backupURL, isTranslate: isTranslate)
                completion?(false)
                return
            }
            self.sm.transition(to: .postProcessing)
            self.overlay.show(phase: self.sm.phase)
            let contextHint = await contextTask.value
            var polishFailed = false
            let cleanText = await self.llm.process(rawText: rawText, contextHint: contextHint,
                translateMode: isTranslate, requireLLM: isTranslate, applyAliases: !isTranslate,
                onFailure: { polishFailed = true })
            if isTranslate && cleanText.isEmpty {
                self.processingFailed(backupURL: backupURL, isTranslate: isTranslate)
                completion?(false)
                return
            }
            let postProcessed = cleanText.isEmpty ? rawText : cleanText
            let finalText = self.llm.isConfigured ? postProcessed : TextFormatter.format(postProcessed)
            self.sm.transition(to: .pasting)
            self.paste.paste(text: finalText) { dispatched in
                self.history.addRecord(text: finalText, originalText: isTranslate ? rawText : nil, isTranslation: isTranslate)
                if polishFailed {
                    AppDelegate.showRetryNotification(audioURL: backupURL, translateMode: isTranslate,
                        fallbackAlreadyPasted: dispatched)
                }
                self.sm.transition(to: .idle)
                if dispatched { self.overlay.show(phase: self.sm.phase); NSSound(named: "Glass")?.play() }
                else { self.overlay.hide() }
                completion?(dispatched && !polishFailed)
            }
        }
    }

    private func processingFailed(backupURL: URL?, isTranslate: Bool) {
        sm.transition(to: .idle)
        overlay.show(phase: sm.phase)
        AppDelegate.showRetryNotification(audioURL: backupURL, translateMode: isTranslate)
    }
}
