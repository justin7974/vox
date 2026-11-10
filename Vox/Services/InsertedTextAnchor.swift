import Cocoa

/// Coordinates are UTF-16, as required by Accessibility. Capture the insertion point,
/// never infer it from the end of a field (the user may dictate in the middle).
struct InsertedTextRange {
    let range: NSRange
    let expectedValue: String
    let insertedText: String

    init?(value: String, selection: NSRange, insertedText: String) {
        let original = value as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= original.length, selection.length <= original.length - selection.location else { return nil }
        self.range = NSRange(location: selection.location, length: insertedText.utf16.count)
        self.expectedValue = original.replacingCharacters(in: selection, with: insertedText)
        self.insertedText = insertedText
    }

    func matches(value: String) -> Bool {
        // Strict equality also rejects edits elsewhere while the instruction was processing.
        value.utf16.elementsEqual(expectedValue.utf16) &&
            (value as NSString).substring(with: range).utf16.elementsEqual(insertedText.utf16)
    }
}

final class InsertedTextAnchor {
    enum CaptureFailure: String, Error {
        case valueUnavailable = "ax_value_unavailable"
        case selectionUnavailable = "ax_selection_unavailable"
        case timeout = "ax_timeout"
        case focusChanged = "ax_focus_changed"
        case invalidRange = "ax_invalid_range"
    }

    /// Injectable reads let tests cover failures without inspecting a real input field.
    struct CaptureAccess {
        var frontmostPID: () -> pid_t?
        var focused: (pid_t) -> Result<AXUIElement, CaptureFailure>
        var value: (AXUIElement) -> Result<String, CaptureFailure>
        var selection: (AXUIElement) -> Result<NSRange, CaptureFailure>

        static var live: CaptureAccess {
            CaptureAccess(frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                          focused: readFocusedElement,
                          value: { readString($0, attribute: kAXValueAttribute) },
                          selection: readSelectedRange)
        }
    }

    private let element: AXUIElement
    private let pid: pid_t
    private let insertion: InsertedTextRange

    private init(element: AXUIElement, pid: pid_t, insertion: InsertedTextRange) {
        self.element = element
        self.pid = pid
        self.insertion = insertion
    }

    static func capture(text: String, access: CaptureAccess = .live,
                        onFailure: (CaptureFailure) -> Void = { _ in }) -> InsertedTextAnchor? {
        do {
            guard let pid = access.frontmostPID() else { throw CaptureFailure.focusChanged }
            let element = try access.focused(pid).get()
            let value = try access.value(element).get()
            let range = try access.selection(element).get()
            // Reading a large AX value can take time. Do not bind the old field after focus moved.
            guard access.frontmostPID() == pid,
                  CFEqual(element, try access.focused(pid).get()) else { throw CaptureFailure.focusChanged }
            guard let insertion = InsertedTextRange(value: value, selection: range, insertedText: text) else {
                throw CaptureFailure.invalidRange
            }
            return InsertedTextAnchor(element: element, pid: pid, insertion: insertion)
        } catch let reason as CaptureFailure {
            onFailure(reason)
            return nil
        } catch {
            return nil
        }
    }

    func select() -> Bool {
        guard validTarget() else { return false }
        var range = CFRange(location: insertion.range.location, length: insertion.range.length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        return selectionIsValid()
    }

    func selectionIsValid() -> Bool {
        validTarget() && Self.selectedRange(element) == insertion.range &&
            Self.string(element, attribute: kAXSelectedTextAttribute)?.utf16.elementsEqual(insertion.insertedText.utf16) == true
    }

    private func validTarget() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focusedElement(pid: pid), CFEqual(element, focused),
              let value = Self.string(element, attribute: kAXValueAttribute) else { return false }
        return insertion.matches(value: value)
    }

    static func readTimeout(attribute: String) -> Float {
        attribute == kAXValueAttribute ? 1.0 : 0.25
    }

    private static func readFocusedElement(pid: pid_t) -> Result<AXUIElement, CaptureFailure> {
        var result: CFTypeRef?
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        let started = ProcessInfo.processInfo.systemUptime
        let status = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &result)
        guard status == .success, let result = result, CFGetTypeID(result) == AXUIElementGetTypeID() else {
            return .failure(readFailure(status, elapsed: ProcessInfo.processInfo.systemUptime - started,
                                        timeout: 0.25, fallback: .focusChanged))
        }
        let element = result as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return .success(element)
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        try? readFocusedElement(pid: pid).get()
    }

    private static func readString(_ element: AXUIElement, attribute: String) -> Result<String, CaptureFailure> {
        let timeout = readTimeout(attribute: attribute)
        AXUIElementSetMessagingTimeout(element, timeout)
        defer { AXUIElementSetMessagingTimeout(element, 0.25) }
        var result: CFTypeRef?
        let started = ProcessInfo.processInfo.systemUptime
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        guard status == .success, let text = result as? String else {
            return .failure(readFailure(status, elapsed: ProcessInfo.processInfo.systemUptime - started,
                                        timeout: timeout, fallback: .valueUnavailable))
        }
        return .success(text)
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        try? readString(element, attribute: attribute).get()
    }

    private static func readSelectedRange(_ element: AXUIElement) -> Result<NSRange, CaptureFailure> {
        var result: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.25)
        let started = ProcessInfo.processInfo.systemUptime
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &result)
        guard status == .success, let result = result, CFGetTypeID(result) == AXValueGetTypeID() else {
            return .failure(readFailure(status, elapsed: ProcessInfo.processInfo.systemUptime - started,
                                        timeout: 0.25, fallback: .selectionUnavailable))
        }
        var range = CFRange()
        guard AXValueGetValue(result as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return .failure(.invalidRange)
        }
        return .success(NSRange(location: range.location, length: range.length))
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        try? readSelectedRange(element).get()
    }

    static func readFailure(_ status: AXError, elapsed: TimeInterval, timeout: Float,
                            fallback: CaptureFailure) -> CaptureFailure {
        // cannotComplete also means an unresponsive/dead app; do not label an immediate error as timeout.
        status == .cannotComplete && elapsed >= Double(timeout) * 0.95 ? .timeout : fallback
    }
}
