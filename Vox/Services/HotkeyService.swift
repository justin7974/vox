import Carbon.HIToolbox

protocol HotkeyDelegate: AnyObject {
    func hotkeyPressed(mode: VoxMode)
    func hotkeyReleased(mode: VoxMode)
}

enum VoxMode {
    case dictation
}

class HotkeyService {
    static let shared = HotkeyService()

    weak var delegate: HotkeyDelegate?

    private let config = ConfigService.shared
    private var dictationHotKeyRef: EventHotKeyRef?
    private var isDictationKeyDown = false
    private var eventHandlerInstalled = false

    private static let dictationHotKeyID: UInt32 = 1
    private static let signature = OSType(0x56495054) // "VIPT"

    // MARK: - Public API

    var hotkeyDisplayString: String {
        HotkeyRecorderView.hotkeyString(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
    }

    var hotkeyMode: String { config.hotkeyMode }

    func register() {
        installEventHandlerIfNeeded()
        registerDictationHotkey()
    }

    func unregister() {
        if let ref = dictationHotKeyRef {
            UnregisterEventHotKey(ref)
            dictationHotKeyRef = nil
        }
        isDictationKeyDown = false
    }

    func reload() {
        unregister()
        config.reload()
        register()
    }

    // MARK: - Registration

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

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
        eventHandlerInstalled = true
    }

    private func registerDictationHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HotkeyService.signature
        hotKeyID.id = HotkeyService.dictationHotKeyID

        let status = RegisterEventHotKey(
            config.hotkeyKeyCode,
            config.hotkeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &dictationHotKeyRef
        )

        let hkStr = hotkeyDisplayString
        if status != noErr {
            NSLog("Vox: Failed to register hotkey \(hkStr) (status: \(status))")
        } else {
            NSLog("Vox: Hotkey \(hkStr) registered")
        }
    }

    // MARK: - Carbon callback handling

    fileprivate func handlePressed(hotKeyID: UInt32) {
        guard hotKeyID == HotkeyService.dictationHotKeyID, !isDictationKeyDown else { return }
        isDictationKeyDown = true
        delegate?.hotkeyPressed(mode: .dictation)
    }

    fileprivate func handleReleased(hotKeyID: UInt32) {
        guard hotKeyID == HotkeyService.dictationHotKeyID else { return }
        isDictationKeyDown = false
        delegate?.hotkeyReleased(mode: .dictation)
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

    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    let kind = GetEventKind(event)
    if kind == UInt32(kEventHotKeyPressed) {
        service.handlePressed(hotKeyID: hotKeyID.id)
    } else if kind == UInt32(kEventHotKeyReleased) {
        service.handleReleased(hotKeyID: hotKeyID.id)
    }
    return noErr
}
