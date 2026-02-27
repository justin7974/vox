import Cocoa

enum PasteHelper {
    private static func debugLog(_ msg: String) {
        let logPath = NSHomeDirectory() + "/.voiceinput/debug.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[PH \(ts)] \(msg)\n"
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

    static func paste(text: String) {
        debugLog("paste called, length=\(text.count)")

        // Always use clipboard + Cmd+V — most universal method
        // AXValue looks good on paper but Electron apps (Claude, VS Code, Slack etc.)
        // report success while silently dropping the text
        pasteViaClipboard(text: text)
    }

    // MARK: - Method 1: Direct AXValue injection

    private static func insertViaAccessibility(text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("AX: no frontmost app")
            return false
        }
        debugLog("AX: frontmost app = \(app.localizedName ?? "?") pid=\(app.processIdentifier)")

        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else {
            debugLog("AX: getFocusedElement failed: \(focusResult.rawValue)")
            return false
        }

        let axElement = element as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "unknown"
        debugLog("AX: element role = \(role)")

        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)
        guard settableResult == .success, isSettable.boolValue else {
            debugLog("AX: not settable (result=\(settableResult.rawValue), settable=\(isSettable.boolValue))")
            return false
        }

        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)

        if rangeResult == .success {
            let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            debugLog("AX: setSelectedText result = \(setResult.rawValue)")
            return setResult == .success
        }

        debugLog("AX: no selectedRange, appending to value")
        var currentValueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValueRef)
        let currentValue = currentValueRef as? String ?? ""
        let newValue = currentValue + text
        let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
        debugLog("AX: setValue result = \(setResult.rawValue)")
        return setResult == .success
    }

    // MARK: - Clipboard + Cmd+V via CGEvent

    private static func pasteViaClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // CGEvent Cmd+V (needs Accessibility permission)
        usleep(50_000)
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            usleep(20_000)
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }
            debugLog("CGEvent Cmd+V sent")
        } else {
            debugLog("CGEvent failed, trying osascript fallback...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                debugLog("osascript exit=\(process.terminationStatus)")
            } catch {
                debugLog("osascript failed: \(error)")
            }
        }
    }
}
