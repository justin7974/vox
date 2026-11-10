import Foundation
import AVFoundation

func waitFor(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now()+2) == .success }

var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { print("FAIL: \(label)"); exit(1) }
}
func data(_ json: Any) -> Data { try! JSONSerialization.data(withJSONObject: json) }
final class MockHTTP: URLProtocol {
    static var response: [String: Any] = [:]
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data(Self.response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SilentChunks: STTProvider {
    let name = "fake-silent"
    var attempts: [String:Int] = [:]
    func transcribe(audioFile: URL) async -> String? {
        let key = audioFile.lastPathComponent
        attempts[key, default:0] += 1
        return key == "3" ? "" : key
    }
}
final class Chunks: STTProvider {
    let name = "fake"
    var attempts: [String: Int] = [:]
    let recover: Bool
    init(recover: Bool) { self.recover = recover }
    func transcribe(audioFile: URL) async -> String? {
        let key = audioFile.lastPathComponent
        attempts[key, default: 0] += 1
        if key == "2" && (!recover || attempts[key] == 1) { return nil }
        return key
    }
}
@main struct Regressions {
    static func main() async throws {
        let a = AliasService.Alias.make
        check(AliasService.apply("我用cloud code写", aliases: [a("cloud code", "Claude Code", .word, false)]) == "我用Claude Code写", "CJK adjacency")
        check(AliasService.apply("C++ node.js xnode.js", aliases: [a("C++", "cpp", .word, false), a("node.js", "node", .word, false)]) == "cpp node xnode.js", "Latin punctuation boundary")
        for pattern in ["^", ".*?", "(?=a)"] {
            check(AliasService.apply("abc", aliases: [a(pattern,"X",.regex,false)]) == "abc", "zero-width ignored")
        }
        let start = ProcessInfo.processInfo.systemUptime
        check(AliasService.apply(String(repeating:"a",count:10000)+"!", aliases:[a("(a+)+$","X",.regex,false)]).hasSuffix("!"), "pathological regex discarded")
        check(ProcessInfo.processInfo.systemUptime - start < 1, "regex deadline")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox321-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let alias = AliasService(directory:dir.path)
        let file = URL(fileURLWithPath:alias.aliasPath)
        let corrupt = Data("[{bad".utf8); try corrupt.write(to:file)
        check(!alias.addAlias(a("a","b",.word,false)), "corrupt alias save refused")
        check(try Data(contentsOf:file) == corrupt, "corrupt bytes unchanged")
        let rows: [Any] = [["from":"a","to":"b","matchMode":"word","custom":42], ["from":"bad","to":"x","matchMode":"future"], "unknown"]
        try data(rows).write(to:file)
        let loaded = alias.aliases
        check(loaded.count == 1, "invalid mode skipped")
        check(alias.updateAlias(loaded[0],to:a("a","c",.word,false)), "valid mutation")
        let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [Any]
        check((saved[0] as! [String:Any])["custom"] as? Int == 42 && saved.count == 3, "unknown rows/fields preserved")
        check(!alias.removeAlias(loaded[0]), "stale mutation refused")
        let cfgDir = dir.appendingPathComponent("config"); try FileManager.default.createDirectory(at:cfgDir, withIntermediateDirectories:true)
        let cfgFile = cfgDir.appendingPathComponent("config.json")
        try data(["asr":"qwen", "qwen-llm":["baseURL":"https://local.invalid","model":"test","extra":1],"unknown":99]).write(to:cfgFile)
        var keys = ["qwen-llm":"own-key"]; var fail = false; var errors:[String] = []
        let cfg = ConfigService(directory:cfgDir.path, getKey:{keys[$0]},setKey:{k,v in if fail {return false};keys[k] = v.isEmpty ? nil : v;return true},reportError:{errors.append($0)})
        check(cfg.llmProviderConfig(for:"qwen-llm")?.apiKey == "own-key", "qwen own-key fallback")
        let before = try Data(contentsOf:cfgFile); fail = true
        check(!cfg.write(key:"qwen-llm",value:["apiKey":"new-key"]), "Keychain failure refused")
        check(try Data(contentsOf:cfgFile) == before && keys["qwen-llm"] == "own-key", "failed save retains key/file")
        fail = false
        check(cfg.write(key:"qwen-llm",value:["apiKey":"new-key","model":"new"]), "secret save")
        check(!(String(data:try Data(contentsOf:cfgFile),encoding:.utf8)!).contains("new-key"), "no plaintext secret")
        check(cfg.write(key:"qwen-llm",value:["apiKey":""]), "explicit key clearing")
        check(keys["qwen-llm"] == nil, "Keychain deleted")
        check((cfg.rawDict["qwen-llm"] as? [String:Any])?["extra"] as? Int == 1 && cfg.rawDict["unknown"] as? Int == 99, "unknown config preserved")
        // Fail disk persistence AFTER a successful key-store change, then verify rollback.
        keys["qwen-llm"] = "prior-key"
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:cfgDir.path)
        check(!cfg.write(key:"qwen-llm",value:["apiKey":"should-rollback"]), "disk failure surfaced")
        check(keys["qwen-llm"] == "prior-key", "disk failure rolls back key")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cfgDir.path)
        try corrupt.write(to:cfgFile)
        check(!cfg.write(key:"provider",value:"none"), "corrupt config refused")
        check(try Data(contentsOf:cfgFile) == corrupt, "corrupt config unchanged")
        try data(["unknown":99]).write(to:cfgFile);cfg.reload()
        DispatchQueue.concurrentPerform(iterations:100) { i in
            if i % 2 == 0 {_ = cfg.write(key:"counter",value:i)}
            else {_ = cfg.rawDict;_ = cfg.availableLLMProviders;_ = cfg.llmProviderConfig(for:"missing")}
        }
        check(cfg.rawDict["unknown"] as? Int == 99, "concurrent config access")
        check(!errors.isEmpty, "failures surfaced")
        // Backup migration: no plaintext API key may survive in any generated backup.
        let migrationDir = dir.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at:migrationDir,withIntermediateDirectories:true)
        let migrationFile = migrationDir.appendingPathComponent("config.json")
        try data(["legacy":["apiKey":"SECRET-MIGRATE","model":"test"],"nested":[["apiKey":"SECRET-NESTED"]]]).write(to:migrationFile)
        let migrated = ConfigService(directory:migrationDir.path,getKey:{_ in nil},setKey:{_,_ in true},reportError:{_ in})
        let firstBackups = try FileManager.default.contentsOfDirectory(at:migrationDir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("config-backup-")}
        check(try firstBackups.count == 1 && (firstBackups.allSatisfy { !(String(data:try Data(contentsOf:$0),encoding:.utf8)!).contains("SECRET-") }), "migration's very first backup redacts secrets")
        for i in 0..<9 { check(migrated.write(key:"counter",value:i), "backup retention save") }
        let backups = try FileManager.default.contentsOfDirectory(at:migrationDir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("config-backup-")}
        check(backups.count == 5, "config backups retained at five")
        check(try backups.allSatisfy { !(String(data:try Data(contentsOf:$0),encoding:.utf8)!).contains("SECRET-") }, "all backup credentials redacted recursively")
        check(try backups.allSatisfy { ((try FileManager.default.attributesOfItem(atPath:$0.path)[.posixPermissions]) as? Int) == 0o600 }, "backup permissions600")
        let rotatingAlias = AliasService(directory:dir.appendingPathComponent("rotating-alias").path)
        for i in 0..<9 { check(rotatingAlias.addAlias(a("word\(i)","replacement",.word,false)), "alias retention save") }
        let aliasBackups = try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:rotatingAlias.aliasPath).deletingLastPathComponent(),includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("aliases-backup-")}
        check(aliasBackups.count == 5, "alias backups retained at five")
        // A blocked Keychain read must not retain the configuration snapshot lock.
        let blockedDir = dir.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at:blockedDir,withIntermediateDirectories:true)
        try data(["test":["baseURL":"https://local.invalid","model":"test"]]).write(to:blockedDir.appendingPathComponent("config.json"))
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), done = DispatchSemaphore(value:0), read = DispatchSemaphore(value:0)
        let blocked = ConfigService(directory:blockedDir.path,getKey:{_ in entered.signal();release.wait();return "fake"},setKey:{_,_ in true},reportError:{_ in})
        DispatchQueue.global().async { _ = blocked.llmProviderConfig(for:"test");done.signal() }
        check(waitFor(entered), "Keychain read entered")
        DispatchQueue.global().async { _ = blocked.rawDict;read.signal() }
        let independentRead = waitFor(read)
        release.signal(); _ = waitFor(done)
        check(independentRead, "snapshot reads proceed during Keychain read")
        let setEntered = DispatchSemaphore(value:0), setRelease = DispatchSemaphore(value:0), setDone = DispatchSemaphore(value:0), setRead = DispatchSemaphore(value:0)
        let blockedWrite = ConfigService(directory:blockedDir.path,getKey:{_ in nil},setKey:{_,_ in setEntered.signal();setRelease.wait();return true},reportError:{_ in})
        DispatchQueue.global().async { _ = blockedWrite.write(key:"key",value:["apiKey":"fake"]);setDone.signal() }
        check(waitFor(setEntered), "Keychain write entered")
        DispatchQueue.global().async { _ = blockedWrite.rawDict;setRead.signal() }
        let independentWriteRead = waitFor(setRead)
        setRelease.signal(); _ = waitFor(setDone)
        check(independentWriteRead, "snapshot reads proceed during Keychain write")
        DispatchQueue.concurrentPerform(iterations:100) { i in
            if i % 2 == 0 { _ = alias.aliases }
            else { _ = alias.addAlias(a("","x",.word,false)); _ = alias.lastError }
        }
        check(true, "lastError concurrent access completed (TSAN also runs this)")
        let sc = URLSessionConfiguration.ephemeral;sc.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration:sc)
        let open = OpenAIProvider(baseURL:"https://local.invalid",apiKey:"fake",model:"test",session:session)
        for reason in ["length","max_tokens","content_filter"] {
            MockHTTP.response = ["choices":[["finish_reason":reason,"message":["content":"PRIVATE-RESULT"]]]]
            let result = await open.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
            check(result.isEmpty, "OpenAI abnormal finish rejected")
        }
        for reason in ["tool_calls", "unknown", "stop_sequence", "eos"] {
            MockHTTP.response = ["choices":[["finish_reason":reason,"message":["content":"PRIVATE-RESULT"]]]]
            let result = await open.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
            check(result == "PRIVATE-RESULT", "compatible finish marker accepted")
        }
        MockHTTP.response = ["choices":[["message":["content":"PRIVATE-RESULT"]]]]
        let omitted = await open.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        check(omitted == "PRIVATE-RESULT", "missing finish marker accepted")
        MockHTTP.response = ["choices":[["finish_reason":"stop","message":["content":"PRIVATE-RESULT"]]]]
        let normal = await open.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        check(normal == "PRIVATE-RESULT", "normal finish accepted")
        check(LLMResponse.outputBudget(for:String(repeating:"中",count:2000)) > 2048 && LLMResponse.outputBudget(for:String(repeating:"中",count:20000)) == 8192, "bounded output budget")
        let anth = AnthropicProvider(baseURL:"https://local.invalid",apiKey:"fake",model:"test",session:session)
        MockHTTP.response = ["stop_reason":"max_tokens","content":[["type":"text","text":"PRIVATE-RESULT"]]]
        let trunc = await anth.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        check(trunc.isEmpty, "Anthropic truncation rejected")
        for reason in ["length", "content_filter"] {
            MockHTTP.response["stop_reason"] = reason
            let result = await anth.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
            check(result.isEmpty, "Anthropic explicit failure marker rejected")
        }
        for reason in ["stop_sequence", "eos"] {
            MockHTTP.response["stop_reason"] = reason
            let result = await anth.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
            check(result == "PRIVATE-RESULT", "Anthropic compatible finish accepted")
        }
        MockHTTP.response["stop_reason"] = nil
        let noReason = await anth.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        check(noReason == "PRIVATE-RESULT", "Anthropic missing finish accepted")
        MockHTTP.response["stop_reason"] = "end_turn"
        let complete = await anth.complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        check(complete == "PRIVATE-RESULT", "Anthropic normal completion")
        check(!LogService.messages.joined().contains("PRIVATE"), "logs omit content")
        let chunks = ["1","2","3"].map {URL(fileURLWithPath:$0)}
        let bad = Chunks(recover:false);var failedIndex = 0
        let partial = await STTService.transcribeChunks(chunks,provider:bad){index,_ in failedIndex=index}
        check(partial.isEmpty && failedIndex == 2 && bad.attempts["2"] == 2 && bad.attempts["3"] == nil, "missing chunk fails whole recording")
        let good = Chunks(recover:true)
        let full = await STTService.transcribeChunks(chunks,provider:good){_,_ in}
        check(full == "1 2 3" && good.attempts["2"] == 2, "chunk retry recovery")
        let silent = SilentChunks(); var silenceFailures = 0
        let kept = await STTService.transcribeChunks(chunks,provider:silent){_,_ in silenceFailures += 1}
        check(kept == "1 2" && silenceFailures == 0, "silent last segment preserves preceding speech")
        check(silent.attempts["3"] == 1, "successful silence is not retried")
        check(QwenASRProvider.requestTimeout(audioBytes:5_700_000) > 180, "size-based timeout")
        check(STTService.filterHallucination("这是真实语音♪后半句必须保留") == "这是真实语音后半句必须保留", "music preserves text")
        check(WhisperLocalProvider.executionTimeout(audioDuration:3600) == 5520, "Whisper timeout scales with recording duration")
        check(WhisperLocalProvider.executionTimeout(audioDuration:100000) == 21600, "Whisper timeout bounded at six hours")
        check(WhisperLocalProvider.executionTimeout(audioDuration:nil) == 300, "unknown duration has explicit fallback")
        let wav = dir.appendingPathComponent("duration.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:16000, channels:1)!
        try autoreleasepool {
            let audioFile = try AVAudioFile(forWriting:wav, settings:format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:64000)!
            buffer.frameLength = 64000
            try audioFile.write(from:buffer)
        }
        check(abs((WhisperLocalProvider.audioDuration(wav) ?? 0)-4) < 0.01, "actual WAV header drives duration")
        // Actual ASR provider response parsing, with in-process HTTP only.
        let qwen = QwenASRProvider(apiKey:"fake",session:session)
        MockHTTP.response = ["choices":[["message":["content":""]]]]
        let qwenSilence = await qwen.transcribe(audioFile:wav)
        check(qwenSilence == "", "Qwen HTTP success-empty is silence")
        MockHTTP.response = ["error":["message":"mock failure"]]
        let qwenFailure = await qwen.transcribe(audioFile:wav)
        check(qwenFailure == nil, "Qwen API failure is distinct from silence")
        let custom = WhisperAPIProvider(baseURL:"https://local.invalid",apiKey:"fake",model:"fake",session:session)
        MockHTTP.response = ["text":""]
        let customSilence = await custom.transcribe(audioFile:wav)
        check(customSilence == "", "custom HTTP success-empty is silence")
        MockHTTP.response = [:]
        let malformed = await custom.transcribe(audioFile:wav)
        check(malformed == nil, "custom malformed reply is failure")
        MockHTTP.status = 503
        MockHTTP.response = ["text":"partial"]
        let httpFailure = await custom.transcribe(audioFile:wav)
        check(httpFailure == nil, "HTTP failure never contributes partial text")
        MockHTTP.status = 200
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = await ProcessRunner.run(executable:"/bin/sleep",arguments:["10"],timeout:0.1)
        check(timeout.stopped && ProcessInfo.processInfo.systemUptime - started < 3, "process deadline")
        let task = Task {await ProcessRunner.run(executable:"/bin/sleep",arguments:["10"],timeout:30)}
        try await Task.sleep(nanoseconds:100_000_000);task.cancel()
        let cancelled = await task.value
        check(cancelled.stopped, "process cancellation")
        let big = await ProcessRunner.run(executable:"/usr/bin/head",arguments:["-c","1000000","/dev/zero"],timeout:5)
        check(big.status == 0 && big.data.count == 1_000_000, "stdout exceeds pipe capacity")
        let stderr = await ProcessRunner.run(executable:"/usr/bin/perl",arguments:["-e","print STDERR 'x' x 1000000; print 'ok';"],timeout:5)
        check(stderr.status == 0 && String(data:stderr.data,encoding:.utf8) == "ok", "stderr drains concurrently")
        let stubbornStart = ProcessInfo.processInfo.systemUptime
        let stubborn = await ProcessRunner.run(executable:"/usr/bin/perl",arguments:["-e","$SIG{TERM}='IGNORE'; sleep 10;"],timeout:0.2)
        check(stubborn.stopped && ProcessInfo.processInfo.systemUptime - stubbornStart < 3, "SIGTERM refusal escalates")
        let failedTool = await ProcessRunner.run(executable:"/usr/bin/false",arguments:[],timeout:1)
        check(failedTool.status != 0, "nonzero local tool rejected")
        let shutdownTask = Task { await ProcessRunner.run(executable:"/bin/sleep",arguments:["10"],timeout:30) }
        try await Task.sleep(nanoseconds:100_000_000)
        ProcessRunner.cancelAll()
        let shutdown = await shutdownTask.value
        check(shutdown.stopped, "app shutdown cancels active tools across callers")
        let missing = await ProcessRunner.run(executable:"/does-not-exist",arguments:[],timeout:1)
        check(missing.status != 0, "launch error")
        print("PASS: \(checks) isolated regressions")
    }
}
