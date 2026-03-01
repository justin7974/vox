import Cocoa

/// Coordinates the Launcher mode: push-to-talk -> transcribe -> intent match -> execute.
/// Also handles selection-based text modification when text is selected before pressing the hotkey.
class LauncherCoordinator: ClipboardPanelDelegate {
    private let log = LogService.shared
    private let llm = LLMService.shared
    private let audio = AudioService.shared
    private let stt = STTService.shared
    private let intentService = IntentService.shared
    private let actionService = ActionService.shared
    private let context = ContextService.shared
    private let paste = PasteService.shared
    private let overlay = StatusOverlay()

    private let sm = VoxStateMachine()
    private let panel = LauncherPanel()
    private let clipboardPanel = ClipboardPanel()

    /// When true, the current recording is a selection-edit, not a launcher command
    private var isSelectionEditMode = false
    private var selectedText: String?

    /// Tracks the last unmatched text for Spotlight fallback
    private var noMatchText: String?
    private var noMatchKeyMonitor: Any?

    init() {
        clipboardPanel.delegate = self
    }

    // MARK: - Public API (called by AppDelegate via HotkeyDelegate)

    /// Push-to-talk: press to start recording + show panel
    func hotkeyPressed() {
        guard sm.phase == .idle else { return }

        // Check if there's selected text — if so, enter selection edit mode
        if let text = getSelectedText(), !text.isEmpty {
            startSelectionEditRecording(selectedText: text)
            return
        }

        // Normal launcher flow
        sm.transition(to: .recording(.launcher))
        panel.show()
        panel.showRecording()
        audio.startRecording()
        NSLog("Vox: Launcher recording started")
    }

    /// Push-to-talk: release to stop recording + process
    func hotkeyReleased() {
        guard case .recording(.launcher) = sm.phase else { return }

        audio.onAudioLevel = nil

        if isSelectionEditMode {
            stopAndProcessSelectionEdit()
            return
        }

        guard let audioURL = audio.stopRecording(backup: false) else {
            sm.transition(to: .idle)
            panel.hide()
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Launcher recording too short (\(fileSize) bytes), ignoring")
            sm.transition(to: .idle)
            panel.hide()
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        sm.transition(to: .transcribing)
        panel.showProcessing()
        NSLog("Vox: Launcher recording stopped, processing...")

        Task { [weak self] in
            guard let self = self else { return }

            // Step 1: Transcribe
            let rawText = await self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Launcher STT result: [\(rawText)]")

            guard !rawText.isEmpty else {
                self.log.debug("Launcher: empty transcription, aborting")
                await MainActor.run {
                    self.panel.showError(VoxError.emptyTranscription)
                }
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run {
                    self.panel.hide()
                    self.sm.transition(to: .idle)
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 2: Show transcription + match intent
            await MainActor.run {
                self.panel.showTranscription(rawText)
                self.sm.transition(to: .matchingIntent)
            }

            let appContext = await MainActor.run { self.context.detect() }
            let match = await self.intentService.match(text: rawText, context: appContext)

            if let match = match {
                // Step 3: Execute matched action
                await MainActor.run {
                    self.sm.transition(to: .executingAction)
                    self.panel.showExecuting(action: match.action)
                }

                do {
                    let result = try await self.actionService.execute(match: match)

                    // Special: clipboard_show triggers the clipboard panel
                    if result.message == "clipboard_show" {
                        await MainActor.run {
                            self.panel.hide()
                            let history = ClipboardService.shared.history
                            if history.isEmpty {
                                self.panel.showResult(ActionResult(success: false, message: "剪贴板为空"))
                                self.panel.show()
                            } else {
                                self.clipboardPanel.show(items: history)
                            }
                            self.sm.transition(to: .idle)
                        }
                        if ClipboardService.shared.history.isEmpty {
                            try? await Task.sleep(for: .seconds(1.5))
                            await MainActor.run { self.panel.hide() }
                        }
                        try? FileManager.default.removeItem(at: audioURL)
                        return
                    }

                    // Special: quick_answer shows the answer in the panel
                    if result.message.hasPrefix("quick_answer:") {
                        let answer = String(result.message.dropFirst("quick_answer:".count))
                        await MainActor.run {
                            self.sm.transition(to: .showingResult)
                            self.panel.showQuickAnswer(answer: answer)
                        }
                        try? await Task.sleep(for: .seconds(4.0))
                        await MainActor.run {
                            self.panel.hide()
                            self.sm.transition(to: .idle)
                        }
                        try? FileManager.default.removeItem(at: audioURL)
                        return
                    }

                    await MainActor.run {
                        self.sm.transition(to: .showingResult)
                        self.panel.showResult(result)
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                } catch {
                    self.log.error("Launcher action failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.panel.showResult(ActionResult(success: false, message: error.localizedDescription))
                    }
                    try? await Task.sleep(for: .seconds(2.0))
                }
            } else {
                // No match — show with Spotlight fallback option
                await MainActor.run {
                    self.panel.showNoMatch(originalText: rawText)
                    self.installSpotlightFallback(query: rawText)
                }
                try? await Task.sleep(for: .seconds(3.0))
                await MainActor.run {
                    self.removeSpotlightFallback()
                }
            }

            // Cleanup
            await MainActor.run {
                self.panel.hide()
                self.sm.transition(to: .idle)
            }
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    func cancelIfRecording() {
        if case .recording(.launcher) = sm.phase {
            _ = audio.stopRecording()
            panel.hide()
            overlay.hide()
            sm.transition(to: .idle)
            isSelectionEditMode = false
            selectedText = nil
        }
        if clipboardPanel.isVisible {
            clipboardPanel.hide()
        }
    }

    // MARK: - Selection Edit Mode

    private func startSelectionEditRecording(selectedText: String) {
        self.isSelectionEditMode = true
        self.selectedText = selectedText
        log.debug("Selection edit: captured \(selectedText.count) chars")

        sm.transition(to: .recording(.launcher))
        overlay.showEditRecording()
        audio.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        audio.startRecording()
        NSSound(named: "Tink")?.play()
        NSLog("Vox: Selection edit recording started")
    }

    private func stopAndProcessSelectionEdit() {
        guard let audioURL = audio.stopRecording() else {
            sm.transition(to: .idle)
            overlay.hide()
            isSelectionEditMode = false
            selectedText = nil
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Selection edit recording too short, ignoring")
            sm.transition(to: .idle)
            overlay.hide()
            isSelectionEditMode = false
            selectedText = nil
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        sm.transition(to: .transcribing)
        overlay.showEditProcessing()
        NSSound(named: "Pop")?.play()

        let originalText = selectedText ?? ""

        Task { [weak self] in
            guard let self = self else { return }

            // Step 1: Transcribe the edit instruction
            let editInstruction = await self.stt.transcribe(audioFile: audioURL)
            self.log.debug("Selection edit instruction: [\(editInstruction)]")

            guard !editInstruction.isEmpty else {
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.hide()
                    self.isSelectionEditMode = false
                    self.selectedText = nil
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 2: Apply edit via LLM
            let userMessage = "原文：\(originalText)\n\n修改指令：\(editInstruction)"
            let editedText = await self.llm.process(rawText: userMessage, customSystemPrompt: LLMService.editPrompt)
            self.log.debug("Selection edit result: [\(editedText)]")

            guard !editedText.isEmpty else {
                await MainActor.run {
                    self.sm.transition(to: .idle)
                    self.overlay.hide()
                    self.isSelectionEditMode = false
                    self.selectedText = nil
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 3: Paste edited text (replaces the current selection)
            await MainActor.run {
                self.paste.paste(text: editedText)

                self.sm.transition(to: .idle)
                self.overlay.showSuccess("✓ 已修改")
                NSSound(named: "Glass")?.play()

                self.isSelectionEditMode = false
                self.selectedText = nil
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    // MARK: - Accessibility Helpers

    private func getSelectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return nil
        }

        let element = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String else {
            return nil
        }

        return text.isEmpty ? nil : text
    }

    // MARK: - Spotlight Fallback

    private func installSpotlightFallback(query: String) {
        noMatchText = query
        noMatchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.noMatchText != nil else { return event }
            if event.keyCode == 36 { // Enter key
                self.panel.hide()
                self.sm.transition(to: .idle)
                self.removeSpotlightFallback()
                self.actionService.openSpotlight()
                return nil
            }
            if event.keyCode == 53 { // Esc key
                self.panel.hide()
                self.sm.transition(to: .idle)
                self.removeSpotlightFallback()
                return nil
            }
            return event
        }
    }

    private func removeSpotlightFallback() {
        noMatchText = nil
        if let monitor = noMatchKeyMonitor {
            NSEvent.removeMonitor(monitor)
            noMatchKeyMonitor = nil
        }
    }

    // MARK: - ClipboardPanelDelegate

    func clipboardPanelDidSelectItem(_ item: ClipboardItem) {
        PasteService.shared.paste(text: item.text)
    }

    func clipboardPanelDidDismiss() {
        // Clipboard panel manages its own lifecycle
    }
}
