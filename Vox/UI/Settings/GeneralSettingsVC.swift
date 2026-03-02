import Cocoa
import Carbon.HIToolbox
import AVFoundation

class GeneralSettingsVC: NSObject {

    private let config = ConfigService.shared
    lazy var view: NSView = buildView()

    // Controls
    private var dictationRecorder: HotkeyRecorderView!
    private var launcherRecorder: HotkeyRecorderView!
    private var modeSegment: NSSegmentedControl!
    private var editWindowSwitch: NSSwitch!
    private var editDurationPopup: NSPopUpButton!
    private var accessibilityDot: NSView!
    private var micDot: NSView!

    // Test recording
    private var testButton: NSButton!
    private var testStatusLabel: NSTextField!
    private var audioLevelView: AudioLevelView!
    private var testRecorder: AudioService?
    private var testIsRecording = false

    private func buildView() -> NSView {
        let (scroll, stack) = SettingsUI.makeScrollableContent()

        // ── HOTKEYS ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Hotkeys"))

        let dictKeyCode = config.hotkeyKeyCode
        let dictModifiers = config.hotkeyModifiers
        dictationRecorder = HotkeyRecorderView(keyCode: dictKeyCode, modifiers: dictModifiers)
        dictationRecorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        dictationRecorder.heightAnchor.constraint(equalToConstant: 28).isActive = true
        dictationRecorder.onHotkeyChanged = { [weak self] code, mods in
            self?.config.write(key: "hotkeyKeyCode", value: Int(code))
            self?.config.write(key: "hotkeyModifiers", value: Int(mods))
            AppDelegate.shared?.reloadHotkey()
        }
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Dictation Hotkey",
            sublabel: "Press to record, release to stop (or toggle)",
            control: dictationRecorder
        ))

        let launchCode = config.launcherHotkeyKeyCode ?? UInt32(kVK_ANSI_Grave)
        let launchMods = config.launcherHotkeyModifiers ?? UInt32(optionKey)
        launcherRecorder = HotkeyRecorderView(keyCode: launchCode, modifiers: launchMods)
        launcherRecorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        launcherRecorder.heightAnchor.constraint(equalToConstant: 28).isActive = true
        launcherRecorder.onHotkeyChanged = { [weak self] code, mods in
            self?.config.write(key: "launcherHotkeyKeyCode", value: Int(code))
            self?.config.write(key: "launcherHotkeyModifiers", value: Int(mods))
            AppDelegate.shared?.reloadHotkey()
        }
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Launcher Hotkey",
            sublabel: "Opens the voice command launcher",
            control: launcherRecorder
        ))

        modeSegment = NSSegmentedControl(labels: ["Toggle", "Hold"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeSegment.selectedSegment = config.hotkeyMode == "hold" ? 1 : 0
        modeSegment.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Recording Mode",
            sublabel: "Toggle: press once to start/stop. Hold: hold key to record",
            control: modeSegment
        ))

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── QUICK EDIT ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Quick Edit Window"))

        editWindowSwitch = NSSwitch()
        editWindowSwitch.state = config.editWindowEnabled ? .on : .off
        editWindowSwitch.target = self
        editWindowSwitch.action = #selector(editWindowToggled)
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Show Edit Window",
            sublabel: "Brief window to review/edit text before pasting",
            control: editWindowSwitch
        ))

        editDurationPopup = NSPopUpButton()
        editDurationPopup.addItems(withTitles: ["2 seconds", "3 seconds", "5 seconds", "10 seconds"])
        let durations = [2.0, 3.0, 5.0, 10.0]
        let currentDuration = config.editWindowDuration
        if let idx = durations.firstIndex(of: currentDuration) {
            editDurationPopup.selectItem(at: idx)
        } else {
            editDurationPopup.selectItem(at: 1) // default 3s
        }
        editDurationPopup.target = self
        editDurationPopup.action = #selector(durationChanged)
        editDurationPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(SettingsUI.makeFormRow(
            label: "Duration",
            control: editDurationPopup
        ))

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── PERMISSIONS ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Permissions"))

        let (accRow, accDot) = SettingsUI.makePermissionRow(label: "Accessibility (auto-paste)")
        accessibilityDot = accDot
        stack.addArrangedSubview(accRow)

        let (micRow, mDot) = SettingsUI.makePermissionRow(label: "Microphone (recording)")
        micDot = mDot
        stack.addArrangedSubview(micRow)

        updatePermissionDots()

        let requestBtn = SettingsUI.makeButton("Open System Settings")
        requestBtn.target = self
        requestBtn.action = #selector(openSystemSettings)
        stack.addArrangedSubview(requestBtn)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── TEST RECORDING ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Test"))

        testButton = SettingsUI.makeButton("Test Recording")
        testButton.target = self
        testButton.action = #selector(testRecordingTapped)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .systemFont(ofSize: 11)
        testStatusLabel.textColor = .secondaryLabelColor

        let testRow = NSStackView(views: [testButton, testStatusLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 12
        testRow.alignment = .centerY
        stack.addArrangedSubview(testRow)

        audioLevelView = AudioLevelView(frame: .zero)
        audioLevelView.translatesAutoresizingMaskIntoConstraints = false
        audioLevelView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stack.addArrangedSubview(audioLevelView)

        stack.addArrangedSubview(SettingsUI.makeSeparator())

        // ── DEVELOPER ──
        stack.addArrangedSubview(SettingsUI.makeSectionTitle("Developer"))

        let viewLogBtn = SettingsUI.makeButton("View Log")
        viewLogBtn.target = self
        viewLogBtn.action = #selector(viewLog)

        let openConfigBtn = SettingsUI.makeButton("Open Config File")
        openConfigBtn.target = self
        openConfigBtn.action = #selector(openConfigFile)

        let devRow = NSStackView(views: [viewLogBtn, openConfigBtn])
        devRow.orientation = .horizontal
        devRow.spacing = 12
        stack.addArrangedSubview(devRow)

        return scroll
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        let mode = modeSegment.selectedSegment == 1 ? "hold" : "toggle"
        config.write(key: "hotkeyMode", value: mode)
        AppDelegate.shared?.reloadHotkey()
    }

    @objc private func editWindowToggled() {
        config.write(key: "editWindowEnabled", value: editWindowSwitch.state == .on)
    }

    @objc private func durationChanged() {
        let durations = [2.0, 3.0, 5.0, 10.0]
        let idx = editDurationPopup.indexOfSelectedItem
        if idx >= 0 && idx < durations.count {
            config.write(key: "editWindowDuration", value: durations[idx])
        }
    }

    @objc private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func testRecordingTapped() {
        if testIsRecording {
            stopTestRecording()
        } else {
            startTestRecording()
        }
    }

    private func startTestRecording() {
        testIsRecording = true
        testButton.title = "Stop"
        testStatusLabel.stringValue = "Recording..."
        testStatusLabel.textColor = .systemRed
        audioLevelView.reset()

        let recorder = AudioService()
        recorder.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.audioLevelView.updateLevel(level)
            }
        }
        testRecorder = recorder
        recorder.startRecording()
    }

    private func stopTestRecording() {
        testIsRecording = false
        testButton.title = "Test Recording"
        testStatusLabel.stringValue = "Processing..."
        testStatusLabel.textColor = .secondaryLabelColor

        guard let audioFile = testRecorder?.stopRecording() else {
            testStatusLabel.stringValue = "No audio captured"
            return
        }
        testRecorder = nil

        Task {
            let text = await STTService.shared.transcribe(audioFile: audioFile)
            await MainActor.run {
                testStatusLabel.stringValue = text.isEmpty ? "No speech detected" : "✓ \(text)"
                testStatusLabel.textColor = text.isEmpty ? .secondaryLabelColor : .systemGreen
            }
        }
    }

    private func updatePermissionDots() {
        let trusted = AXIsProcessTrusted()
        accessibilityDot.layer?.backgroundColor = trusted
            ? NSColor.systemGreen.cgColor
            : NSColor.systemOrange.cgColor

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .notDetermined:
            micDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        default:
            micDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }

    @objc private func viewLog() {
        let logPath = NSHomeDirectory() + "/.vox/debug.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    @objc private func openConfigFile() {
        let path = NSHomeDirectory() + "/.vox/config.json"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
