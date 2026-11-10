import Cocoa

@main struct EditCaptureTests {
    static var checks = 0
    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { print("FAIL: \(label)"); exit(1) }
    }
    static func main() {
        let element = AXUIElementCreateApplication(999999)
        func reads() -> InsertedTextAnchor.CaptureAccess {
            .init(frontmostPID: { 42 }, focused: { _ in .success(element) },
                  value: { _ in .success("start end") }, selection: { _ in .success(NSRange(location: 6, length: 0)) })
        }
        var failures: [InsertedTextAnchor.CaptureFailure] = []
        check(InsertedTextAnchor.capture(text: "🙂", access: reads(), onFailure: { failures.append($0) }) != nil,
              "capture safely binds insertion with injected AX reads")
        check(failures.isEmpty, "successful capture has no failure code")
        for reason in [InsertedTextAnchor.CaptureFailure.valueUnavailable, .selectionUnavailable, .timeout] {
            var access = reads()
            if reason == .selectionUnavailable { access.selection = { _ in .failure(reason) } }
            else { access.value = { _ in .failure(reason) } }
            failures = []
            check(InsertedTextAnchor.capture(text: "private-not-logged", access: access, onFailure: { failures.append($0) }) == nil,
                  "failed AX read cannot bind insertion")
            check(failures == [reason], "failure preserves exact fixed reason code")
        }
        var access = reads()
        var pidReads = 0
        access.frontmostPID = { pidReads += 1; return pidReads == 1 ? 42 : 43 }
        failures = []
        check(InsertedTextAnchor.capture(text: "text", access: access, onFailure: { failures.append($0) }) == nil,
              "focus move during slow value read rejects capture")
        check(failures == [.focusChanged], "focus move has explicit reason")
        access = reads()
        access.selection = { _ in .success(NSRange(location: 999, length: 0)) }
        failures = []
        check(InsertedTextAnchor.capture(text: "text", access: access, onFailure: { failures.append($0) }) == nil,
              "invalid selection rejected")
        check(failures == [.invalidRange], "invalid range has fixed reason")
        check(InsertedTextAnchor.readTimeout(attribute: kAXValueAttribute) == 1, "full value read gets one second")
        check(InsertedTextAnchor.readTimeout(attribute: kAXSelectedTextAttribute) == 0.25, "selected text read keeps short timeout")
        check(InsertedTextAnchor.readFailure(.cannotComplete, elapsed: 1, timeout: 1, fallback: .valueUnavailable) == .timeout,
              "elapsed AX deadline reported as timeout")
        check(InsertedTextAnchor.readFailure(.cannotComplete, elapsed: 0.01, timeout: 1, fallback: .valueUnavailable) == .valueUnavailable,
              "immediate cannotComplete is not mislabeled timeout")
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        event.flags = .maskCommand
        check(!PasteService.isOwnPasteEvent(NSEvent(cgEvent: event)!), "physical Cmd+V is not ignored")
        event.setIntegerValueField(.eventSourceUserData, value: PasteService.pasteEventMarker)
        check(PasteService.isOwnPasteEvent(NSEvent(cgEvent: event)!), "tagged delayed own Cmd+V is recognized")
        print("PASS: \(checks) edit capture/event checks; no AX queries or events posted")
    }
}
