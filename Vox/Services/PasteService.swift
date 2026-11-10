import Cocoa

class PasteService {
    static let shared = PasteService()

    private let log = LogService.shared

    /// Last text Vox pasted — kept in memory independent of History toggle so "Copy Last
    /// Transcription" works even for users with history disabled.
    private(set) var lastPastedText: String?

    func paste(text: String, beforePaste: (() -> Bool)? = nil, completion: ((Bool) -> Void)? = nil) {
        log.debug("paste called, length=\(text.count)")

        // Always use clipboard + Cmd+V — most universal method
        // AXValue looks good on paper but Electron apps (Claude, VS Code, Slack etc.)
        // report success while silently dropping the text
        pasteViaClipboard(text: text, beforePaste: beforePaste, completion: completion)
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

    private func pasteViaClipboard(text: String, beforePaste: (() -> Bool)?, completion: ((Bool) -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            // Revalidate on the main thread at dispatch time, after any focus/selection change.
            guard beforePaste?() ?? true else { completion?(false); return }
            lastPastedText = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let source = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    up.post(tap: .cghidEventTap)
                    completion?(true)
                } // dispatched, not proof that the target application consumed it
            } else if beforePaste != nil {
                // Do not spawn a delayed fallback for a replacement whose selection can go stale.
                completion?(false)
            } else {
                Task {
                    let result = await ProcessRunner.run(executable: "/usr/bin/osascript",
                        arguments: ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"], timeout: 5)
                    await MainActor.run { completion?(result.status == 0 && !result.stopped) }
                }
            }
        }
    }
}
