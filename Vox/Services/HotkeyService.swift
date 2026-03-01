import Carbon.HIToolbox

protocol HotkeyDelegate: AnyObject {
    func hotkeyPressed(mode: VoxMode)
    func hotkeyReleased(mode: VoxMode)
}

class HotkeyService {
    static let shared = HotkeyService()

    weak var delegate: HotkeyDelegate?

    private let config = ConfigService.shared
    private var dictationHotKeyRef: EventHotKeyRef?
    private var launcherHotKeyRef: EventHotKeyRef?
    private var isDictationKeyDown = false
    private var isLauncherKeyDown = false
    private var eventHandlerInstalled = false

    // Hotkey IDs
    private static let dictationHotKeyID: UInt32 = 1
    private static let launcherHotKeyID: UInt32 = 2
    private static let signature = OSType(0x56495054) // "VIPT"

    // MARK: - Public API

    var hotkeyDisplayString: String {
        HotkeyRecorderView.hotkeyString(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
    }

    var launcherHotkeyDisplayString: String {
        guard let kc = config.launcherHotkeyKeyCode else { return "Not set" }
        return HotkeyRecorderView.hotkeyString(keyCode: kc, modifiers: config.launcherHotkeyModifiers ?? 0)
    }

    var hotkeyMode: String { config.hotkeyMode }

    func register() {
        installEventHandlerIfNeeded()
        registerDictationHotkey()
        registerLauncherHotkey()
    }

    func unregister() {
        if let ref = dictationHotKeyRef {
            UnregisterEventHotKey(ref)
            dictationHotKeyRef = nil
        }
        if let ref = launcherHotKeyRef {
            UnregisterEventHotKey(ref)
            launcherHotKeyRef = nil
        }
        isDictationKeyDown = false
        isLauncherKeyDown = false
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
            NSLog("Vox: Failed to register dictation hotkey \(hkStr) (status: \(status))")
        } else {
            NSLog("Vox: Dictation hotkey \(hkStr) registered")
        }
    }

    private func registerLauncherHotkey() {
        guard let keyCode = config.launcherHotkeyKeyCode else {
            NSLog("Vox: Launcher hotkey not configured, skipping")
            return
        }
        let modifiers = config.launcherHotkeyModifiers ?? 0

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HotkeyService.signature
        hotKeyID.id = HotkeyService.launcherHotKeyID

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &launcherHotKeyRef
        )

        let hkStr = launcherHotkeyDisplayString
        if status != noErr {
            NSLog("Vox: Failed to register launcher hotkey \(hkStr) (status: \(status))")
        } else {
            NSLog("Vox: Launcher hotkey \(hkStr) registered")
        }
    }

    // MARK: - Carbon callback handling

    fileprivate func handlePressed(hotKeyID: UInt32) {
        switch hotKeyID {
        case HotkeyService.dictationHotKeyID:
            guard !isDictationKeyDown else { return }
            isDictationKeyDown = true
            delegate?.hotkeyPressed(mode: .dictation)
        case HotkeyService.launcherHotKeyID:
            guard !isLauncherKeyDown else { return }
            isLauncherKeyDown = true
            delegate?.hotkeyPressed(mode: .launcher)
        default:
            break
        }
    }

    fileprivate func handleReleased(hotKeyID: UInt32) {
        switch hotKeyID {
        case HotkeyService.dictationHotKeyID:
            isDictationKeyDown = false
            delegate?.hotkeyReleased(mode: .dictation)
        case HotkeyService.launcherHotKeyID:
            isLauncherKeyDown = false
            delegate?.hotkeyReleased(mode: .launcher)
        default:
            break
        }
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

    // Extract which hotkey was triggered
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
