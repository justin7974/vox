import Carbon.HIToolbox

protocol HotkeyDelegate: AnyObject {
    func hotkeyPressed()
    func hotkeyReleased()
}

class HotkeyService {
    static let shared = HotkeyService()

    weak var delegate: HotkeyDelegate?

    private let config = ConfigService.shared
    private var hotKeyRef: EventHotKeyRef?
    private var isKeyDown = false

    // MARK: - Public API

    /// Current hotkey display string
    var hotkeyDisplayString: String {
        HotkeyRecorderView.hotkeyString(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
    }

    var hotkeyMode: String { config.hotkeyMode }

    func register() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x56495054) // "VIPT"
        hotKeyID.id = 1

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        let status = RegisterEventHotKey(
            config.hotkeyKeyCode,
            config.hotkeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        let hkStr = hotkeyDisplayString
        if status != noErr {
            NSLog("Vox: Failed to register hotkey \(hkStr) (status: \(status))")
        } else {
            NSLog("Vox: Hotkey \(hkStr) registered")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        isKeyDown = false
    }

    func reload() {
        unregister()
        config.reload()
        register()
    }

    // MARK: - Carbon callback handling

    fileprivate func handlePressed() {
        guard !isKeyDown else { return } // Carbon auto-repeat guard
        isKeyDown = true
        delegate?.hotkeyPressed()
    }

    fileprivate func handleReleased() {
        isKeyDown = false
        delegate?.hotkeyReleased()
    }
}

// MARK: - Carbon Hotkey Callback (C function)

private func hotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else { return noErr }
    let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    if kind == UInt32(kEventHotKeyPressed) {
        service.handlePressed()
    } else if kind == UInt32(kEventHotKeyReleased) {
        service.handleReleased()
    }
    return noErr
}
