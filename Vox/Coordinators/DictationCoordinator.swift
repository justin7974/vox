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
    private var insertionAnchor: InsertedTextAnchor?
    private var editWindowTimer: Timer?
    private var keyEventMonitor: Any?
    private var localKeyEventMonitor: Any?
    private var isInEditMode: Bool = false

    private var unsupportedEditNoticeApps: Set<String> = []
    private var permissionNoticeShown = false
    private let applicationKey: () -> String
    private let captureInsertion: (String, (InsertedTextAnchor.CaptureFailure) -> Void) -> InsertedTextAnchor?

    init(captureInsertion: @escaping (String, (InsertedTextAnchor.CaptureFailure) -> Void) -> InsertedTextAnchor? = {
        InsertedTextAnchor.capture(text: $0, onFailure: $1)
    }, applicationKey: @escaping () -> String = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        return app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }) {
        self.captureInsertion = captureInsertion
        self.applicationKey = applicationKey
    }

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
                let wantsEdit = !isTranslate && self.config.editWindowEnabled && self.config.editWindowDuration > 0
                let editApplication = wantsEdit ? self.applicationKey() : nil
                var captureFailure: InsertedTextAnchor.CaptureFailure?
                self.insertionAnchor = wantsEdit ? self.captureInsertion(finalText, { reason in
                    captureFailure = reason
                    self.log.debug("Edit capture failed: reason=\(reason.rawValue)")
                }) : nil
                self.paste.paste(text: finalText, completion: { dispatched in
                    self.log.debug("Step 4: Paste dispatched=\(dispatched)")
                    // Keep the recoverable dictation even when dispatch failed.
                    if isTranslate {
                        self.history.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                    } else {
                        self.history.addRecord(text: finalText)
                    }
                    guard dispatched else {
                        self.insertionAnchor = nil
                        self.sm.transition(to: .idle)
                        if captureFailure == .permissionDenied {
                            self.showEditCaptureFailure(captureFailure, application: editApplication)
                        } else { self.overlay.hide() }
                        return
                    }

                    // Start the full countdown only after Cmd+V was dispatched and released.
                    if wantsEdit && self.insertionAnchor != nil {
                        self.lastInsertedText = finalText
                        self.enterEditWindow()
                    } else {
                        self.sm.transition(to: .idle)
                        if wantsEdit { self.showEditCaptureFailure(captureFailure, application: editApplication) }
                        else { self.overlay.show(phase: self.sm.phase) }
                    }
                    NSSound(named: "Glass")?.play()
                })
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    // MARK: - Edit Window

    private func showEditCaptureFailure(_ reason: InsertedTextAnchor.CaptureFailure?, application: String?) {
        if reason == .permissionDenied {
            if !permissionNoticeShown {
                permissionNoticeShown = true
                overlay.showSuccess("请在系统设置 → 隐私与安全性 → 辅助功能中授权 Vox", autoDismissAfter: 6)
            } else { overlay.hide() }
        } else if let app = application, unsupportedEditNoticeApps.insert(app).inserted {
            overlay.showSuccess("此应用暂不支持修改", autoDismissAfter: 3)
        } else { overlay.hide() }
    }

    private func enterEditWindow() {
        let duration = config.editWindowDuration
        sm.transition(to: .editWindow)
        overlay.showEditWindow(duration: duration)

        editWindowTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.expireEditWindow()
        }

        // Any other keyboard input cancels the edit window.
        // Global monitor fires when other apps are frontmost; local monitor fires when Vox itself is frontmost.
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !PasteService.isOwnPasteEvent(event), let self = self, self.sm.phase == .editWindow else { return }
            self.expireEditWindow()
        }
        localKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !PasteService.isOwnPasteEvent(event), let self = self, self.sm.phase == .editWindow else { return event }
            self.expireEditWindow()
            return event
        }
    }

    private func expireEditWindow() {
        cancelEditWindowCleanup()
        if sm.phase == .editWindow {
            sm.transition(to: .idle)
            overlay.hide()
        }
        lastInsertedText = nil
        insertionAnchor = nil
    }

    private func cancelEditWindowCleanup() {
        editWindowTimer?.invalidate()
        editWindowTimer = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = localKeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyEventMonitor = nil
        }
    }

    // MARK: - Edit Mode Recording

    private func startEditRecording() {
        cancelEditWindowCleanup()

        // Select last inserted text via Accessibility API
        guard insertionAnchor?.select() == true else {
            expireEditWindow()
            AppDelegate.showNotification(title: "Vox", message: "The insertion or focus changed. Edit was cancelled without replacing text.")
            return
        }

        guard sm.transition(to: .recording) else { return }
        isInEditMode = true
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
        if fileSize < 16000 || !audio.hasAudio {
            NSLog("Vox: Edit recording too short or silent (size: \(fileSize), peak: \(audio.peakPower) dB), ignoring")
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
            self.log.debug("Edit instruction: characters=\(editInstruction.count)")

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
            let editedText = await self.llm.process(rawText: userMessage, customSystemPrompt: LLMService.editPrompt, requireLLM: true)
            self.log.debug("Edit result: characters=\(editedText.count)")

            guard !editedText.isEmpty else {
                // LLM failed/unavailable — must abort rather than paste the "原文+指令" prompt back into the input.
                self.log.debug("Edit: LLM returned empty, aborting (original text left untouched)")
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.hide()
                    self.isInEditMode = false
                    NSSound(named: "Basso")?.play()
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 3: Paste edited text (replaces AX selection)
            await MainActor.run {
                self.sm.transition(to: .pasting)
                self.paste.paste(text: editedText, beforePaste: { self.insertionAnchor?.selectionIsValid() == true }) { dispatched in
                    if dispatched { self.history.addRecord(text: editedText, originalText: originalText) }
                    else { AppDelegate.showNotification(title: "Vox", message: "Edit cancelled: focus, selection or original text changed.") }
                    self.sm.transition(to: .idle)
                    if dispatched { self.overlay.showSuccess("✓ 已修改") } else { self.overlay.hide() }
                    self.isInEditMode = false
                    self.lastInsertedText = nil
                    self.insertionAnchor = nil
                }
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

}
