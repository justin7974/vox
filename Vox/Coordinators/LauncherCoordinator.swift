import Cocoa

/// Coordinates the Launcher mode: push-to-talk -> transcribe -> intent match -> execute.
class LauncherCoordinator: ClipboardPanelDelegate {
    private let log = LogService.shared
    private let audio = AudioService.shared
    private let stt = STTService.shared
    private let intentService = IntentService.shared
    private let actionService = ActionService.shared
    private let context = ContextService.shared

    private let sm = VoxStateMachine()
    private let panel = LauncherPanel()
    private let clipboardPanel = ClipboardPanel()

    init() {
        clipboardPanel.delegate = self
    }

    // MARK: - Public API (called by AppDelegate via HotkeyDelegate)

    /// Push-to-talk: press to start recording + show panel
    func hotkeyPressed() {
        guard sm.phase == .idle else { return }

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

        guard let audioURL = audio.stopRecording() else {
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
                // No match
                await MainActor.run {
                    self.panel.showNoMatch(originalText: rawText)
                }
                try? await Task.sleep(for: .seconds(2.0))
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
            sm.transition(to: .idle)
        }
        if clipboardPanel.isVisible {
            clipboardPanel.hide()
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
