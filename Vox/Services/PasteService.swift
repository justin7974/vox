import Cocoa

class PasteService {
    static let shared = PasteService()

    private let log = LogService.shared

    func paste(text: String) {
        log.debug("paste called, length=\(text.count)")

        // Always use clipboard + Cmd+V — most universal method
        // AXValue looks good on paper but Electron apps (Claude, VS Code, Slack etc.)
        // report success while silently dropping the text
        pasteViaClipboard(text: text)
    }

    // MARK: - Direct AXValue injection (unused, kept for reference)

    private func insertViaAccessibility(text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log.debug("AX: no frontmost app")
            return false
        }
        log.debug("AX: frontmost app = \(app.localizedName ?? "?") pid=\(app.processIdentifier)")

        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else {
            log.debug("AX: getFocusedElement failed: \(focusResult.rawValue)")
            return false
        }

        let axElement = element as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "unknown"
        log.debug("AX: element role = \(role)")

        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)
        guard settableResult == .success, isSettable.boolValue else {
            log.debug("AX: not settable (result=\(settableResult.rawValue), settable=\(isSettable.boolValue))")
            return false
        }

        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)

        if rangeResult == .success {
            let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            log.debug("AX: setSelectedText result = \(setResult.rawValue)")
            return setResult == .success
        }

        log.debug("AX: no selectedRange, appending to value")
        var currentValueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValueRef)
        let currentValue = currentValueRef as? String ?? ""
        let newValue = currentValue + text
        let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
        log.debug("AX: setValue result = \(setResult.rawValue)")
        return setResult == .success
    }

    // MARK: - Clipboard + Cmd+V via CGEvent

    private func pasteViaClipboard(text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot the previous clipboard so we can restore it after paste.
        let saved: [(type: NSPasteboard.PasteboardType, data: Data)] = pasteboard.pasteboardItems?.flatMap { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Use dispatch_after instead of usleep so we don't block the main thread waiting for the
        // pasteboard to settle and for the host app to consume Cmd+V.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) { [log] in
            let source = CGEventSource(stateID: .hidSystemState)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
                // Small gap between down and up so target app registers the chord.
                Thread.sleep(forTimeInterval: 0.02)
                keyUp.post(tap: .cghidEventTap)
                log.debug("CGEvent Cmd+V sent")
            } else {
                log.debug("CGEvent failed, trying osascript fallback...")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    log.debug("osascript exit=\(process.terminationStatus)")
                } catch {
                    log.debug("osascript failed: \(error)")
                }
            }

            // Restore previous clipboard after target app has had a chance to consume our paste.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                DispatchQueue.main.async {
                    guard !saved.isEmpty else { return }
                    pasteboard.clearContents()
                    let restore = NSPasteboardItem()
                    for (type, data) in saved {
                        restore.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([restore])
                    log.debug("Clipboard restored (\(saved.count) items)")
                }
            }
        }
    }
}
