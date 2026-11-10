import Cocoa

@main struct BaselineBehaviorTests {
    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(label)") }
    }
    @MainActor static func start(_ c: DictationCoordinator) async {
        c.hotkeyPressed(mode: "toggle"); c.hotkeyPressed(mode: "toggle")
        for _ in 0..<200 {
            if !PasteService.texts.isEmpty { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("fixture pipeline stalled")
    }
    @MainActor static func main() async {
        InsertedTextAnchor.supported = false
        let failure = DictationCoordinator()
        await start(failure)
        PasteService.complete(true)
        check(StatusOverlay.successes == ["此应用暂不支持修改"], "capture failure is visible")
        PasteService.texts = []; StatusOverlay.windows = 0; StatusOverlay.successes = []
        HistoryService.records = 0
        InsertedTextAnchor.supported = true
        let success = DictationCoordinator()
        await start(success)
        check(StatusOverlay.windows == 0 && NSEvent.global == nil, "edit countdown and monitor wait for dispatch")
        check(HistoryService.records == 0, "history waits for dispatch")
        PasteService.complete(true)
        let hidden = StatusOverlay.hidden
        NSEvent.key(own: true)
        check(StatusOverlay.windows == 1 && StatusOverlay.hidden == hidden, "own paste key does not cancel window")
        print("Baseline-compatible behavior: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
