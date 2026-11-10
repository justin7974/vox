import Cocoa

@main struct EditCoordinatorTests {
    static var checks = 0
    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { print("FAIL: \(label)"); exit(1) }
    }
    @MainActor static func pastePending(_ coordinator: DictationCoordinator) async {
        coordinator.hotkeyPressed(mode: "toggle")
        coordinator.hotkeyPressed(mode: "toggle")
        for _ in 0..<200 {
            if PasteService.pending != nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, "pipeline reaches deferred paste")
    }
    @MainActor static func reset() {
        PasteService.pending = nil; PasteService.texts = []
        StatusOverlay.windows = 0; StatusOverlay.successes = []; StatusOverlay.hidden = 0
        HistoryService.records = 0; LogService.messages = []
        NSEvent.global = nil; NSEvent.local = nil
    }
    @MainActor static func main() async {
        reset()
        let failed = DictationCoordinator(captureInsertion: { _, fail in fail(.valueUnavailable); return nil })
        await pastePending(failed)
        check(StatusOverlay.windows == 0 && StatusOverlay.successes.isEmpty, "no edit window before paste dispatch")
        check(HistoryService.records == 0, "dispatch not prematurely counted as pasted")
        PasteService.complete(true)
        check(StatusOverlay.successes == ["此应用暂不支持修改"], "unsupported capture gives visible exact message")
        check(StatusOverlay.windows == 0, "failed capture never starts edit window")
        check(LogService.messages.contains("Edit capture failed: reason=ax_value_unavailable"), "failure reason logged without input")
        check(!LogService.messages.contains(where: { $0.contains("fixture output") }), "failure log omits dictated content")
        check(HistoryService.records == 1, "successful normal paste still records history")

        reset()
        let element = AXUIElementCreateApplication(999999)
        let access = InsertedTextAnchor.CaptureAccess(frontmostPID: { 42 }, focused: { _ in .success(element) },
                                                     value: { _ in .success("") }, selection: { _ in .success(NSRange(location: 0, length: 0)) })
        let success = DictationCoordinator(captureInsertion: { text, fail in InsertedTextAnchor.capture(text: text, access: access, onFailure: fail) })
        await pastePending(success)
        check(StatusOverlay.windows == 0 && NSEvent.global == nil, "keyboard monitor not armed before paste dispatch")
        NSEvent.key(own: true)
        PasteService.complete(true)
        check(StatusOverlay.windows == 1, "edit window starts after completed paste dispatch")
        check(NSEvent.global != nil && NSEvent.local != nil, "edit monitors arm after dispatch")
        let hidden = StatusOverlay.hidden
        NSEvent.key(own: true)
        check(StatusOverlay.hidden == hidden && NSEvent.global != nil, "delayed own Cmd+V cannot cancel edit window")
        NSEvent.key(own: false)
        check(StatusOverlay.hidden == hidden + 1 && NSEvent.global == nil, "physical key still cancels edit window")

        reset()
        let undispatched = DictationCoordinator(captureInsertion: { _, _ in nil })
        await pastePending(undispatched)
        PasteService.complete(false)
        check(HistoryService.records == 0 && StatusOverlay.windows == 0, "failed dispatch does not start edit or write history")
        check(StatusOverlay.successes.isEmpty, "failed paste does not claim unsupported capture success")
        print("PASS: \(checks) real coordinator checks with isolated service/UI/event doubles")
    }
}
