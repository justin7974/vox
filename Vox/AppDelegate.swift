import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyService.shared
    private let dictation = DictationCoordinator()
    private var setupWindow: SetupWindow?
    private var historyWindowController: HistoryWindowController?
    private var blackBoxWindowController: BlackBoxWindowController?
    private var hotkeyMenuItem: NSMenuItem?
    private var translateMenuItem: NSMenuItem?
    private(set) var translateMode: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        _ = ConfigService.shared  // trigger migration + initial load
        setupEditMenu()
        setupStatusBar()
        dictation.onNeedsSetup = { [weak self] in self?.showSetup() }
        hotkey.delegate = self
        hotkey.register()

        // Always persist the current version for Repair Permissions to compare against.
        persistCurrentVersion()

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

    // MARK: - TCC Permission Repair

    /// Persist the current bundle version so Repair Permissions can detect version changes.
    private func persistCurrentVersion() {
        let voxDir = NSHomeDirectory() + "/.vox"
        let versionFile = voxDir + "/.last-authorized-version"
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        try? FileManager.default.createDirectory(atPath: voxDir, withIntermediateDirectories: true)
        try? currentVersion.write(toFile: versionFile, atomically: true, encoding: .utf8)
    }

    /// User-triggered repair: reset the stale TCC entry so macOS re-prompts.
    /// Previously this ran automatically on every version change, which surprised users and
    /// required them to re-grant a permission they had already granted. Now it's opt-in via the menu.
    @objc private func repairAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Reset Accessibility Permission?"
        alert.informativeText = "This clears Vox's Accessibility permission so macOS will prompt you to re-grant it. Use this only if paste/Cmd+V has stopped working after an update."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", "com.justin.vox"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        NSLog("Vox: TCC reset done (exit=\(proc.terminationStatus))")

        let done = NSAlert()
        done.messageText = "Accessibility permission reset"
        done.informativeText = "Quit and relaunch Vox to be re-prompted."
        done.runModal()
    }

    // MARK: - Config

    private let config = ConfigService.shared

    func reloadHotkey() {
        hotkey.reload()
        hotkeyMenuItem?.title = "Hotkey: \(hotkey.hotkeyDisplayString)"
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(NSMenuItem(title: "Vox v\(version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let hkItem = NSMenuItem(title: "Hotkey: \(hotkey.hotkeyDisplayString)", action: nil, keyEquivalent: "")
        hotkeyMenuItem = hkItem
        menu.addItem(hkItem)
        menu.addItem(NSMenuItem.separator())

        let transItem = NSMenuItem(title: "Translate Mode (中→EN)", action: #selector(toggleTranslateMode), keyEquivalent: "t")
        transItem.keyEquivalentModifierMask = []  // just "t" as shortcut when menu is open
        translateMenuItem = transItem
        menu.addItem(transItem)

        menu.addItem(NSMenuItem(title: "Black Box", action: #selector(openBlackBox), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscription), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Edit Dictionary...", action: #selector(openDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Repair Permissions...", action: #selector(repairAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Monochrome template microphone icon for the menubar — uses SF Symbols for system-native alignment.
    private func makeMenuBarIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Vox")?
            .withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Vox")
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    func openHistoryWindow() {
        openHistory()
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
            // Create prompt file with default prompt so user can edit
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

    @objc private func copyLastTranscription() {
        guard let text = PasteService.shared.lastPastedText, !text.isEmpty else {
            AppDelegate.showNotification(title: "Vox", message: "No transcription yet.")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        AppDelegate.showNotification(title: "Vox", message: "Last transcription copied to clipboard.")
    }

    @objc private func openDictionary() {
        let path = DictionaryService.shared.dictPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

    @objc private func quit() {
        dictation.cancelIfRecording()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - HotkeyDelegate

extension AppDelegate: HotkeyDelegate {
    func hotkeyPressed(mode: VoxMode) {
        dictation.hotkeyPressed(mode: hotkey.hotkeyMode)
    }

    func hotkeyReleased(mode: VoxMode) {
        dictation.hotkeyReleased(mode: hotkey.hotkeyMode)
    }
}
