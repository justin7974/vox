import Cocoa
import Carbon.HIToolbox
import AVFoundation
import UserNotifications

enum AppState {
    case idle
    case recording
    case processing
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var state: AppState = .idle
    private let recorder = AudioRecorder()
    private let overlay = StatusOverlay()
    private var hotKeyRef: EventHotKeyRef?
    private var setupWindow: SetupWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupEditMenu()
        setupStatusBar()
        registerHotKey()

        // Check accessibility for auto-paste (Cmd+V simulation)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            NSLog("VoiceInput: Accessibility permission needed for auto-paste. Granted via System Settings.")
        }

        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // First-run check: show setup if no config exists
        if !configExists() {
            showSetup()
        }
    }

    // MARK: - Config check

    private func configExists() -> Bool {
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        return FileManager.default.fileExists(atPath: configPath)
    }

    // MARK: - Setup

    func showSetup() {
        setupWindow = SetupWindow()
        setupWindow?.show { [weak self] in
            self?.setupWindow = nil
        }
    }

    // MARK: - Edit Menu (enables Cmd+C/V/X/A in text fields for LSUIElement apps)

    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceInput v1.3", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Hotkey: Ctrl+`", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Config File", action: #selector(openConfigFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "View Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        switch state {
        case .idle:       statusItem.button?.title = "🎙️"
        case .recording:  statusItem.button?.title = "🔴"
        case .processing: statusItem.button?.title = "⏳"
        }
        overlay.show(state: state)
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        showSetup()
    }

    @objc private func openConfigFile() {
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        if FileManager.default.fileExists(atPath: configPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
        } else {
            showSetup()
        }
    }

    @objc private func openLog() {
        let logPath = NSHomeDirectory() + "/.voiceinput/debug.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    // MARK: - Notifications

    static func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Global Hotkey (Carbon)

    private func registerHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x56495054) // "VIPT"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            nil
        )

        // Ctrl + ` (grave accent, keycode 0x32)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("VoiceInput: Failed to register hotkey Ctrl+` (status: \(status))")
        } else {
            NSLog("VoiceInput: Hotkey Ctrl+` registered")
        }
    }

    // MARK: - Recording Toggle

    func toggleRecording() {
        switch state {
        case .idle:
            if !configExists() {
                AppDelegate.showNotification(title: "VoiceInput", message: "Please configure your API keys first.")
                showSetup()
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
        updateStatusIcon()
        recorder.start()
        NSSound(named: "Tink")?.play()
        NSLog("VoiceInput: Recording started")
    }

    private func stopAndProcess() {
        guard let audioURL = recorder.stop() else {
            state = .idle
            updateStatusIcon()
            return
        }

        // Check minimum recording length (~0.5s of 16kHz mono 16-bit = ~16KB)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("VoiceInput: Recording too short (\(fileSize) bytes), ignoring")
            state = .idle
            updateStatusIcon()
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        // Check if any meaningful audio was captured (not just silence)
        if !recorder.hasAudio {
            NSLog("VoiceInput: No audio detected (peak: \(recorder.peakPower) dB), skipping")
            state = .idle
            updateStatusIcon()
            NSSound(named: "Basso")?.play()
            AppDelegate.showNotification(title: "VoiceInput", message: "No audio detected. Check your microphone.")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        state = .processing
        updateStatusIcon()
        NSSound(named: "Pop")?.play()
        NSLog("VoiceInput: Recording stopped (\(fileSize) bytes, peak: \(recorder.peakPower) dB), processing...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let logPath = NSHomeDirectory() + "/.voiceinput/debug.log"
            func debugLog(_ msg: String) {
                let ts = ISO8601DateFormatter().string(from: Date())
                let line = "[\(ts)] \(msg)\n"
                NSLog("VoiceInput: \(msg)")
                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: logPath) {
                        if let fh = FileHandle(forWritingAtPath: logPath) {
                            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                        }
                    } else {
                        FileManager.default.createFile(atPath: logPath, contents: data)
                    }
                }
            }

            // Step 1: Transcription (Qwen ASR or local Whisper)
            debugLog("Step 1: Transcribe start (file: \(audioURL.lastPathComponent))")
            let rawText = Transcriber.transcribe(audioFile: audioURL)
            debugLog("Step 1: Transcribe result: [\(rawText)]")

            guard !rawText.isEmpty else {
                debugLog("Step 1: Empty result, aborting")
                DispatchQueue.main.async {
                    self?.state = .idle
                    self?.updateStatusIcon()
                    AppDelegate.showNotification(title: "VoiceInput", message: "Could not recognize speech. Try again.")
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            // Step 2: LLM post-processing (if configured)
            debugLog("Step 2: PostProcessor start")
            let cleanText = PostProcessor.process(rawText: rawText)
            let postProcessed = cleanText.isEmpty ? rawText : cleanText
            debugLog("Step 2: PostProcessor result: [\(postProcessed)]")

            // Step 3: Deterministic formatting (only when LLM is not active)
            // LLM already handles spacing, punctuation, and formatting
            let finalText: String
            if PostProcessor.isConfigured {
                finalText = postProcessed
                debugLog("Step 3: Skipped TextFormatter (LLM active)")
            } else {
                finalText = TextFormatter.format(postProcessed)
                debugLog("Step 3: TextFormatter applied: [\(finalText)]")
            }

            // Step 4: Paste
            debugLog("Step 4: Pasting...")
            DispatchQueue.main.async {
                PasteHelper.paste(text: finalText)
                debugLog("Step 4: Paste done")
                self?.state = .idle
                self?.updateStatusIcon()
                NSSound(named: "Glass")?.play()
            }

            // Cleanup
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    @objc private func quit() {
        if state == .recording {
            _ = recorder.stop()
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Carbon Hotkey Callback (C function)

private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    AppDelegate.shared?.toggleRecording()
    return noErr
}
