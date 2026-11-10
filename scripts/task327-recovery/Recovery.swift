import Cocoa
@main struct RecoveryTests {
    static var checks = 0
    static func check(_ ok: Bool, _ name: String) {
        checks += 1; if !ok { print("FAIL: \(name)"); exit(1) }
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, "async completion")
    }
    @MainActor static func reset() {
        for b in AudioService.backups { try? FileManager.default.removeItem(at: b.url) }
        AudioService.backups = []; AudioService.starts = 0
        STTService.calls = 0; STTService.urls = []; STTService.output = "raw fixture"
        LLMService.calls = []; LLMService.output = "polished fixture"; LLMService.shared.isConfigured = true
        PasteService.texts = []; PasteService.pending = nil; HistoryService.records = []
        AppDelegate.retries = []; AppDelegate.notifications = []; AppDelegate.shared.translateMode = false
    }
    @MainActor static func main() async {
        reset()
        defer { for b in AudioService.backups { try? FileManager.default.removeItem(at: b.url) } }
        let c = DictationCoordinator()
        c.retryRecording()
        check(STTService.calls == 0 && !AppDelegate.notifications.isEmpty, "missing backup makes no request")
        STTService.output = ""
        c.hotkeyPressed(mode: "toggle"); c.hotkeyPressed(mode: "toggle")
        await waitFor { !AppDelegate.retries.isEmpty }
        check(c.isIdle && PasteService.texts.isEmpty, "ASR failure releases busy state and never pastes")
        let failed = AppDelegate.retries[0].0!
        // Normal processing removed its temporary original; point the fake backup at a durable fixture.
        try! Data(repeating: 0, count: 20000).write(to: failed)
        let newer = FileManager.default.temporaryDirectory.appendingPathComponent("vox-newer-\(UUID().uuidString).wav")
        try! Data(repeating: 0, count: 20000).write(to: newer)
        AudioService.backups.insert(AudioService.Backup(url: newer),at: 0)
        let request = RetryRecordingRequest(audioURL: failed, translateMode: true)
        check(request.resolve(in: AudioService.backups.map { $0.url }) == failed, "old notification remains bound to failed audio")
        check(RetryRecordingRequest(userInfo: request.userInfo)?.translateMode == true, "translation mode survives notification")
        check(RetryRecordingRequest(userInfo: ["backup":"../secret.wav","translate":false]) == nil, "path injection rejected")
        check(request.resolve(in: [newer]) == nil, "pruned backup never selects a newer recording")
        STTService.output = "raw fixture"
        check(c.retryRecording(at: failed, translateMode: true), "specific backup accepted")
        check(!c.retryRecording(at: newer), "overlapping retry rejected")
        await waitFor { PasteService.pending != nil }
        check(STTService.urls.last == failed, "full pipeline reads original failed backup")
        check(LLMService.calls.last!.translate && !LLMService.calls.last!.aliases, "retry preserves translation and alias exclusion")
        check(FileManager.default.fileExists(atPath: failed.path), "retry does not delete retained backup")
        PasteService.complete(true)
        check(c.isIdle && HistoryService.records.count == 1, "retry records final result once")
        c.repasteLastText();check(PasteService.texts.count == 2, "menu re-pastes last final text")
        check(STTService.calls == 2 && LLMService.calls.count == 1, "re-paste invokes neither ASR nor LLM")
        PasteService.complete(true)
        check(HistoryService.records.count == 1 && c.isIdle, "re-paste does not duplicate history")
        LLMService.output = "";AppDelegate.retries = []
        check(c.retryRecording(at: newer, translateMode: false), "ordinary retry starts")
        await waitFor { PasteService.pending != nil }
        check(AppDelegate.retries.isEmpty, "fallback notice waits for actual paste dispatch callback")
        check(PasteService.texts.last == "raw fixture", "ordinary polish failure preserves existing raw fallback")
        PasteService.complete(true)
        check(AppDelegate.retries.first?.0 == newer && AppDelegate.retries.first?.2 == true, "successful raw fallback notice explains second paste")
        check(c.isIdle, "polish fallback releases state")
        AppDelegate.retries = []
        let count = PasteService.texts.count
        c.retryRecording(at: failed, translateMode: true)
        await waitFor { !AppDelegate.retries.isEmpty }
        check(PasteService.texts.count == count && c.isIdle, "translation failure never pastes fallback and releases state")
        AppDelegate.retries = []; AppDelegate.notifications = []
        LLMService.shared.isConfigured = false
        let callsBefore = STTService.calls
        check(!c.retryRecording(at: failed, translateMode: true), "translation without LLM refuses retry")
        check(AppDelegate.retries.isEmpty && AppDelegate.notifications == ["翻译需要先配置 LLM"], "missing LLM explains configuration instead of retry loop")
        check(STTService.calls == callsBefore, "missing LLM sends no ASR request")
        check(RetryRecordingRequest.notificationBody(fallbackAlreadyPasted: true) == "原文已贴；点此再贴一份润色版", "post-fallback notification explains duplicate paste")
        check(RetryRecordingRequest.notificationBody(fallbackAlreadyPasted: false) == "这段没处理成功，点此重试", "plain failure retry notice unchanged")
        print("PASS: \(checks) recovery assertions; no real services used")
    }
}
