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
        var appKey = "app-a"
        let failed = DictationCoordinator(captureInsertion: { _, fail in fail(.valueUnavailable); return nil }, applicationKey: { appKey })
        await pastePending(failed)
        check(StatusOverlay.windows == 0 && StatusOverlay.successes.isEmpty, "no edit window before paste dispatch")
        check(HistoryService.records == 0, "dispatch not prematurely counted as pasted")
        PasteService.complete(true)
        check(StatusOverlay.successes == ["此应用暂不支持修改"], "unsupported capture gives visible exact message")
        check(StatusOverlay.windows == 0, "failed capture never starts edit window")
        check(LogService.messages.contains("Edit capture failed: reason=ax_value_unavailable"), "failure reason logged without input")
        check(!LogService.messages.contains(where: { $0.contains("fixture output") }), "failure log omits dictated content")
        check(HistoryService.records == 1, "successful normal paste still records history")
        await pastePending(failed)
        PasteService.complete(true)
        check(StatusOverlay.successes.count == 1, "same app is notified only once per run")
        appKey = "app-b"
        await pastePending(failed)
        PasteService.complete(true)
        check(StatusOverlay.successes.count == 2, "different app gets its own first notice")
        appKey = "app-a"
        await pastePending(failed)
        PasteService.complete(true)
        check(StatusOverlay.successes.count == 2, "returning to first app stays suppressed")

        reset()
        let element = AXUIElementCreateApplication(999999)
        let access = InsertedTextAnchor.CaptureAccess(frontmostPID: { 42 }, focused: { _ in .success(element) },
                                                     value: { _ in .success("") }, selection: { _ in .success(NSRange(location: 0, length: 0)) }, trusted: { true })
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
        check(HistoryService.records == 1 && StatusOverlay.windows == 0, "failed dispatch retains history without starting edit")
        check(StatusOverlay.successes.isEmpty, "failed paste does not claim unsupported capture success")
        reset()
        var reason = InsertedTextAnchor.CaptureFailure.permissionDenied
        let permissions = DictationCoordinator(captureInsertion: { _, fail in fail(reason); return nil }, applicationKey: { "app-a" })
        await pastePending(permissions)
        PasteService.complete(false)
        check(HistoryService.records == 1, "failed dispatch with missing permission still keeps history")
        check(StatusOverlay.successes.count == 1 && StatusOverlay.successes[0].contains("辅助功能中授权 Vox"), "permission failure gives authorization guidance even if dispatch fails")
        check(!StatusOverlay.successes.contains("此应用暂不支持修改"), "missing permission never claims unsupported app")
        await pastePending(permissions)
        PasteService.complete(true)
        check(StatusOverlay.successes.count == 1, "permission guidance is shown once per run")
        reason = .valueUnavailable
        await pastePending(permissions)
        PasteService.complete(true)
        check(StatusOverlay.successes.last == "此应用暂不支持修改", "permission recovery leaves app notice independently available")
        print("PASS: \(checks) real coordinator checks with isolated service/UI/event doubles")
    }
}
