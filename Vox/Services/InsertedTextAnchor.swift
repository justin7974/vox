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
    private let element: AXUIElement
    private let pid: pid_t
    private let insertion: InsertedTextRange

    private init(element: AXUIElement, pid: pid_t, insertion: InsertedTextRange) {
        self.element = element
        self.pid = pid
        self.insertion = insertion
    }

    static func capture(text: String) -> InsertedTextAnchor? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = focusedElement(pid: app.processIdentifier),
              let value = string(element, attribute: kAXValueAttribute),
              let range = selectedRange(element),
              let insertion = InsertedTextRange(value: value, selection: range, insertedText: text) else { return nil }
        return InsertedTextAnchor(element: element, pid: app.processIdentifier, insertion: insertion)
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

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        var result: CFTypeRef?
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.25)
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &result) == .success,
              let result = result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        let element = result as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &result) == .success,
              let result = result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(result as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
