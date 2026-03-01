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
    private let recorder = AudioService.shared
    private let overlay = StatusOverlay()
    private var hotKeyRef: EventHotKeyRef?
    private var setupWindow: SetupWindow?
    private var historyWindowController: HistoryWindowController?
    private var blackBoxWindowController: BlackBoxWindowController?
    private var hotkeyMenuItem: NSMenuItem?
    private var translateMenuItem: NSMenuItem?
    private(set) var translateMode: Bool = false
    private(set) var hotkeyMode: String = "toggle" // "toggle" or "hold"
    private(set) var hotkeyKeyCode: UInt32 = UInt32(kVK_ANSI_Grave)
    private(set) var hotkeyModifiers: UInt32 = UInt32(controlKey)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        _ = ConfigService.shared  // trigger migration + initial load
        setupEditMenu()
        setupStatusBar()
        loadHotkeyMode()
        registerHotKey()

        // Check accessibility for auto-paste (Cmd+V simulation)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            NSLog("Vox: Accessibility permission needed for auto-paste. Granted via System Settings.")
        }

        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // First-run check: show setup if no config exists
        if !config.configExists {
            showSetup()
        }
    }

    // MARK: - Config

    private let config = ConfigService.shared

    func loadHotkeyMode() {
        config.reload()
        hotkeyMode = config.hotkeyMode
        hotkeyKeyCode = config.hotkeyKeyCode
        hotkeyModifiers = config.hotkeyModifiers
        NSLog("Vox: Hotkey mode = \(hotkeyMode), key = \(HotkeyRecorderView.hotkeyString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers))")
    }

    func reloadHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        loadHotkeyMode()
        registerHotKey()
        hotkeyMenuItem?.title = "Hotkey: \(HotkeyRecorderView.hotkeyString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers))"
    }

    // MARK: - Setup

    func showSetup() {
        guard setupWindow == nil else { return }
        setupWindow = SetupWindow()
        setupWindow?.show { [weak self] in
            self?.setupWindow = nil
            self?.reloadHotkey()
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makeMenuBarIcon()
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Vox v2.1", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let hkItem = NSMenuItem(title: "Hotkey: \(HotkeyRecorderView.hotkeyString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers))", action: nil, keyEquivalent: "")
        hotkeyMenuItem = hkItem
        menu.addItem(hkItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))

        let transItem = NSMenuItem(title: "Translate Mode (中→EN)", action: #selector(toggleTranslateMode), keyEquivalent: "t")
        transItem.keyEquivalentModifierMask = []  // just "t" as shortcut when menu is open
        translateMenuItem = transItem
        menu.addItem(transItem)

        menu.addItem(NSMenuItem(title: "View History", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Black Box", action: #selector(openBlackBox), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Edit Prompt", action: #selector(openPromptFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Config File", action: #selector(openConfigFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "View Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        overlay.show(state: state)
    }

    /// Monochrome template microphone icon for the menubar
    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 16, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let cx = rect.width / 2

            // Mic capsule
            let micW: CGFloat = 5.5
            let micH: CGFloat = 8.0
            let micBottom: CGFloat = 8.5
            let micRect = NSRect(x: cx - micW / 2, y: micBottom, width: micW, height: micH)
            NSBezierPath(roundedRect: micRect, xRadius: micW / 2, yRadius: micW / 2).fill()

            // Cradle U-arc
            let cradle = NSBezierPath()
            cradle.lineWidth = 1.3
            cradle.lineCapStyle = .round
            let cradleR: CGFloat = 5.0
            let cradleCenterY: CGFloat = 10.5
            cradle.appendArc(
                withCenter: NSPoint(x: cx, y: cradleCenterY),
                radius: cradleR, startAngle: 150, endAngle: 30, clockwise: false
            )
            cradle.stroke()

            // Stand
            let standTop = cradleCenterY - cradleR
            let standBottom: CGFloat = 2.5
            let stand = NSBezierPath()
            stand.lineWidth = 1.3; stand.lineCapStyle = .round
            stand.move(to: NSPoint(x: cx, y: standTop))
            stand.line(to: NSPoint(x: cx, y: standBottom))
            stand.stroke()

            // Base
            let base = NSBezierPath()
            base.lineWidth = 1.3; base.lineCapStyle = .round
            base.move(to: NSPoint(x: cx - 3, y: standBottom))
            base.line(to: NSPoint(x: cx + 3, y: standBottom))
            base.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        showSetup()
    }

    @objc private func toggleTranslateMode() {
        translateMode.toggle()
        translateMenuItem?.state = translateMode ? .on : .off
        NSLog("Vox: Translate mode = \(translateMode)")
    }

    @objc private func openHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        historyWindowController?.show()
    }

    @objc private func openBlackBox() {
        if blackBoxWindowController == nil {
            blackBoxWindowController = BlackBoxWindowController()
        }
        blackBoxWindowController?.show()
    }

    @objc private func openPromptFile() {
        let promptPath = NSHomeDirectory() + "/.vox/prompt.txt"
        if !FileManager.default.fileExists(atPath: promptPath) {
            // Trigger prompt file creation with comments + default prompt
            _ = LLMService.shared.process(rawText: "")
        }
        // Still might not exist if PostProcessor skipped (no LLM config) — create manually
        if !FileManager.default.fileExists(atPath: promptPath) {
            let dir = NSHomeDirectory() + "/.vox"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? LLMService.defaultPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: promptPath))
    }

    @objc private func openConfigFile() {
        let configPath = NSHomeDirectory() + "/.vox/config.json"
        if FileManager.default.fileExists(atPath: configPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
        } else {
            showSetup()
        }
    }

    @objc private func openLog() {
        let logPath = NSHomeDirectory() + "/.vox/debug.log"
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

        // Register for both press and release events
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            2,
            &eventTypes,
            nil,
            nil
        )

        let status = RegisterEventHotKey(
            hotkeyKeyCode,
            hotkeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        let hotkeyStr = HotkeyRecorderView.hotkeyString(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        if status != noErr {
            NSLog("Vox: Failed to register hotkey \(hotkeyStr) (status: \(status))")
        } else {
            NSLog("Vox: Hotkey \(hotkeyStr) registered")
        }
    }

    // MARK: - Hotkey Handlers

    func hotKeyPressed() {
        switch hotkeyMode {
        case "hold":
            if state == .idle {
                if !config.configExists {
                    AppDelegate.showNotification(title: "Vox", message: "Please configure your API keys first.")
                    showSetup()
                    return
                }
                startRecording()
            }
        default: // toggle
            toggleRecording()
        }
    }

    func hotKeyReleased() {
        if hotkeyMode == "hold" && state == .recording {
            stopAndProcess()
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        switch state {
        case .idle:
            if !config.configExists {
                AppDelegate.showNotification(title: "Vox", message: "Please configure your API keys first.")
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
        recorder.onAudioLevel = { [weak self] level in
            self?.overlay.updateAudioLevel(level)
        }
        recorder.startRecording()
        NSSound(named: "Tink")?.play()
        NSLog("Vox: Recording started")
    }

    private func stopAndProcess() {
        recorder.onAudioLevel = nil

        // Capture app context and translate mode NOW on the main thread,
        // before dispatching to background.
        let appContext = ContextDetector.detect()
        let contextHint = ContextDetector.contextHint(for: appContext)
        let isTranslate = translateMode

        guard let audioURL = recorder.stopRecording() else {
            state = .idle
            updateStatusIcon()
            return
        }

        // Check minimum recording length (~0.5s of 16kHz mono 16-bit = ~16KB)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if fileSize < 16000 {
            NSLog("Vox: Recording too short (\(fileSize) bytes), ignoring")
            state = .idle
            updateStatusIcon()
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        // Check if any meaningful audio was captured (not just silence)
        if !recorder.hasAudio {
            NSLog("Vox: No audio detected (peak: \(recorder.peakPower) dB), skipping")
            state = .idle
            updateStatusIcon()
            NSSound(named: "Basso")?.play()
            AppDelegate.showNotification(title: "Vox", message: "No audio detected. Check your microphone.")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        // Audio backup is now handled automatically by AudioService.stopRecording()

        state = .processing
        updateStatusIcon()
        NSSound(named: "Pop")?.play()
        NSLog("Vox: Recording stopped (\(fileSize) bytes, peak: \(recorder.peakPower) dB), processing...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let log = LogService.shared

            log.debug("Step 1: Transcribe start (file: \(audioURL.lastPathComponent))")
            let rawText = STTService.shared.transcribe(audioFile: audioURL)
            log.debug("Step 1: Transcribe result: [\(rawText)]")

            guard !rawText.isEmpty else {
                log.debug("Step 1: Empty result, aborting")
                DispatchQueue.main.async {
                    self?.state = .idle
                    self?.updateStatusIcon()
                    AppDelegate.showNotification(title: "Vox", message: "Could not recognize speech. Try again.")
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            log.debug("Step 2: PostProcessor start (context: \(contextHint ?? "none"), translate: \(isTranslate))")
            let cleanText = LLMService.shared.process(rawText: rawText, contextHint: contextHint, translateMode: isTranslate)
            let postProcessed = cleanText.isEmpty ? rawText : cleanText
            log.debug("Step 2: PostProcessor result: [\(postProcessed)]")

            let finalText: String
            if LLMService.shared.isConfigured {
                finalText = postProcessed
                log.debug("Step 3: Skipped TextFormatter (LLM active)")
            } else {
                finalText = TextFormatter.format(postProcessed)
                log.debug("Step 3: TextFormatter applied: [\(finalText)]")
            }

            log.debug("Step 4: Pasting...")
            DispatchQueue.main.async {
                PasteService.shared.paste(text: finalText)
                log.debug("Step 4: Paste done")

                // Save to history (translation mode: store both languages)
                if isTranslate {
                    HistoryManager.shared.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                } else {
                    HistoryManager.shared.addRecord(text: finalText)
                }

                self?.state = .idle
                self?.updateStatusIcon()
                NSSound(named: "Glass")?.play()
            }

            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    @objc private func quit() {
        if state == .recording {
            _ = recorder.stopRecording()
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
    guard let event = event else { return noErr }
    let kind = GetEventKind(event)
    if kind == UInt32(kEventHotKeyPressed) {
        AppDelegate.shared?.hotKeyPressed()
    } else if kind == UInt32(kEventHotKeyReleased) {
        AppDelegate.shared?.hotKeyReleased()
    }
    return noErr
}
