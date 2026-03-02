import Cocoa
import Carbon.HIToolbox

class HotkeyRecorderView: NSView {
    var keyCode: UInt32
    var modifiers: UInt32
    private var isRecording = false
    var onHotkeyChanged: ((UInt32, UInt32) -> Void)?

    private let label: NSTextField
    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.isBordered = false
        label.isEditable = false
        label.backgroundColor = .clear
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        currentModifiers = []
        window?.makeFirstResponder(self)
        updateDisplay()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            currentModifiers = []
            updateDisplay()
        }
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording {
            currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            updateDisplay()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.intersection([.control, .option, .shift, .command]).isEmpty else {
                NSSound.beep()
                return
            }

            keyCode = UInt32(event.keyCode)
            modifiers = carbonModifiers(from: mods)
            isRecording = false
            currentModifiers = []
            updateDisplay()
            onHotkeyChanged?(keyCode, modifiers)
        }
    }

    private func updateDisplay() {
        if isRecording {
            if currentModifiers.intersection([.control, .option, .shift, .command]).isEmpty {
                label.stringValue = "Type shortcut..."
                label.textColor = .secondaryLabelColor
            } else {
                label.stringValue = modifierString(from: currentModifiers) + "..."
                label.textColor = .labelColor
            }
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        } else {
            label.stringValue = HotkeyRecorderView.hotkeyString(keyCode: keyCode, modifiers: modifiers)
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private func modifierString(from flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        return parts.joined()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    static func hotkeyString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
            0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
            0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
            0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N",
            0x2E: "M", 0x2F: ".",
            0x32: "`",
            0x24: "\u{21A9}", 0x30: "\u{21E5}", 0x31: "Space", 0x33: "\u{232B}", 0x35: "Esc",
            0x75: "\u{2326}",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
            0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x7B: "\u{2190}", 0x7C: "\u{2192}", 0x7D: "\u{2193}", 0x7E: "\u{2191}",
        ]
        return names[keyCode] ?? "Key(\(keyCode))"
    }
}
