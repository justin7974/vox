import Cocoa

@main struct IncrementBehaviorTests {
    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(label)") }
    }
    @MainActor static func run(_ c: DictationCoordinator, dispatched: Bool = true) async {
        PasteService.texts = []
        c.hotkeyPressed(mode: "toggle"); c.hotkeyPressed(mode: "toggle")
        for _ in 0..<200 {
            if PasteService.pending != nil { PasteService.complete(dispatched); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("fixture pipeline stalled")
    }
    @MainActor static func main() async {
        InsertedTextAnchor.supported = false
        let history = DictationCoordinator()
        await run(history, dispatched: false)
        check(HistoryService.records == 1, "dispatch failure retains history")
        let notices = DictationCoordinator()
        StatusOverlay.successes = []
        await run(notices); await run(notices)
        check(StatusOverlay.successes == ["此应用暂不支持修改"], "same app notice only once")
        NSWorkspace.shared.frontmostApplication = FixtureApplication(bundleIdentifier: "fixture-app-b", processIdentifier: 43)
        await run(notices)
        NSWorkspace.shared.frontmostApplication = FixtureApplication(bundleIdentifier: "fixture-app-a", processIdentifier: 42)
        await run(notices)
        check(StatusOverlay.successes.count == 2, "one notice each for two applications including revisit")
        let permission = DictationCoordinator()
        InsertedTextAnchor.failureReason = .permissionDenied
        StatusOverlay.successes = []
        await run(permission)
        check(StatusOverlay.successes.count == 1 && StatusOverlay.successes[0].contains("辅助功能中授权 Vox"),
              "missing permission guides authorization instead of blaming app")
        print("Increment behavior: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
