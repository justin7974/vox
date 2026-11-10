import Cocoa

@main struct DictationFlowTests {
    static var checks = 0
    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { print("FAIL: \(label)"); exit(1) }
    }
    @MainActor static func reset() {
        PasteService.texts = []; PasteService.pending = nil
        HistoryService.records = []; LLMService.calls = []; LLMService.output = "fixture polished"
        LLMService.shared.isConfigured = true; AppDelegate.shared.translateMode = false
        AppDelegate.notifications = []; StatusOverlay.phases = []; AudioService.starts = 0
    }
    @MainActor static func finish(_ c: DictationCoordinator, mode: String = "toggle") async {
        if mode == "hold" { c.hotkeyReleased(mode: mode) } else { c.hotkeyPressed(mode: mode) }
        for _ in 0..<200 {
            if PasteService.pending != nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, "normal pipeline reaches paste")
    }
    @MainActor static func main() async {
        reset()
        let c = DictationCoordinator()
        c.hotkeyPressed(mode: "hold")
        await finish(c, mode: "hold")
        check(PasteService.texts == ["fixture polished"], "ordinary hold dictation pastes polished result")
        check(HistoryService.records.isEmpty, "history still waits for paste dispatch callback")
        PasteService.complete(true)
        check(StatusOverlay.phases.last == .idle, "paste returns directly to idle")
        check(HistoryService.records.count == 1 && !HistoryService.records[0].translation, "ordinary history preserved")
        c.hotkeyPressed(mode: "hold")
        check(AudioService.starts == 2, "immediate next hotkey starts ordinary recording")
        await finish(c, mode: "hold")
        PasteService.complete(true)
        check(LLMService.calls.count == 2 && LLMService.calls.allSatisfy { $0.aliases && !$0.translate && !$0.required && $0.custom == nil }, "rapid second dictation uses ordinary prompt and alias gating")

        reset()
        let toggle = DictationCoordinator()
        toggle.hotkeyPressed(mode: "toggle"); await finish(toggle)
        PasteService.complete(false)
        check(HistoryService.records.count == 1 && HistoryService.records[0].text == "fixture polished", "failed paste retains polished history")
        check(StatusOverlay.phases.last == .idle, "failed paste returns to idle")

        reset()
        AppDelegate.shared.translateMode = true
        let translated = DictationCoordinator()
        translated.hotkeyPressed(mode: "toggle"); await finish(translated)
        PasteService.complete(true)
        check(LLMService.calls.count == 1 && LLMService.calls[0].translate && LLMService.calls[0].required && !LLMService.calls[0].aliases, "translation remains LLM-required without aliases")
        check(HistoryService.records[0].translation && HistoryService.records[0].original == "fixture raw", "translation history keeps original source")

        reset()
        AppDelegate.shared.translateMode = true; LLMService.output = ""
        let failedTranslation = DictationCoordinator()
        failedTranslation.hotkeyPressed(mode: "toggle"); failedTranslation.hotkeyPressed(mode: "toggle")
        for _ in 0..<200 {
            if !LLMService.calls.isEmpty && StatusOverlay.phases.last == .idle { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(LLMService.calls.count == 1, "failed translation reached LLM")
        check(PasteService.texts.isEmpty && HistoryService.records.isEmpty, "translation failure never pastes raw text or prompt")

        reset()
        LLMService.output = ""
        let ordinaryFallback = DictationCoordinator()
        ordinaryFallback.hotkeyPressed(mode: "toggle"); await finish(ordinaryFallback)
        PasteService.complete(true)
        check(PasteService.texts == ["fixture raw"], "ordinary LLM failure retains raw fallback")
        print("PASS: \(checks) ordinary/translation coordinator checks; isolated doubles only")
    }
}
