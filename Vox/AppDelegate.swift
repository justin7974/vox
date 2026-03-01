import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyService.shared
    private let dictation = DictationCoordinator()
    private let launcher = LauncherCoordinator()
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
        ActionService.shared.loadActions()
        ClipboardService.shared.startMonitoring()
        hotkey.delegate = self
        hotkey.register()

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
        menu.addItem(NSMenuItem(title: "Vox v2.1", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let hkItem = NSMenuItem(title: "Hotkey: \(hotkey.hotkeyDisplayString)", action: nil, keyEquivalent: "")
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
        launcher.cancelIfRecording()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - HotkeyDelegate

extension AppDelegate: HotkeyDelegate {
    func hotkeyPressed(mode: VoxMode) {
        switch mode {
        case .dictation:
            dictation.hotkeyPressed(mode: hotkey.hotkeyMode)
        case .launcher:
            launcher.hotkeyPressed()
        }
    }

    func hotkeyReleased(mode: VoxMode) {
        switch mode {
        case .dictation:
            dictation.hotkeyReleased(mode: hotkey.hotkeyMode)
        case .launcher:
            launcher.hotkeyReleased()
        }
    }
}
