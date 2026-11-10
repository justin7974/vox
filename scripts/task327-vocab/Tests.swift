import Foundation

@main @MainActor struct VocabTests {
    typealias W = DictionaryAutoUpdateService
    static var checks = 0
    static func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    @MainActor final class F {
        let dir: URL
        let dict: DictionaryService
        var clock = VocabTests.date("2026-11-10T03:00:00Z")
        var idle = true, enabled = true, canScan = true, fail = false, brokenAliases = false, becomeBusy = false
        var calls = 0
        var records: [W.HistoryRecord] = [], seen: [[W.HistoryRecord]] = []
        var proposals: [W.Proposal] = []
        var aliases: [W.AliasRule] = []
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox-vocab-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["ExistingTerm", ["futureField": true]] as [Any]).write(to: dir.appendingPathComponent("dictionary.json"))
            dict = DictionaryService(directory: dir.path)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
        var stateURL: URL { dir.appendingPathComponent("dictionary-auto-update.json") }
        func worker() -> W {
            W(directory: dir.path, dictionary: dict, now: { self.clock },
              calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c },
              isEnabled: { self.enabled }, isIdle: { self.idle }, canScan: { self.canScan }, history: { self.records },
              aliases: { if self.brokenAliases { throw CocoaError(.fileReadCorruptFile) }; return self.aliases },
              scan: { records, _ in
                self.calls += 1; self.seen.append(records)
                if self.fail { throw NSError(domain: "PRIVATE_ERROR_BODY", code: 99, userInfo: [NSLocalizedDescriptionKey:"DO_NOT_STORE_TRANSCRIPT_SECRET"]) }
                if self.becomeBusy { self.idle = false }
                return self.proposals
              })
        }
        @discardableResult func history(_ text: String, at timestamp: Date? = nil) -> W.HistoryRecord {
            let r = W.HistoryRecord(text: text, timestamp: timestamp ?? clock.addingTimeInterval(-60)); records.append(r); return r
        }
        func proposal(_ wrong: String, _ suggested: String, _ records: [W.HistoryRecord]) -> W.Proposal { W.Proposal(wrong: wrong, suggested: suggested, recordIDs: records.map { $0.id }) }
        func nextDay() { clock = clock.addingTimeInterval(86400) }
    }
    static func main() async throws {
        do {
            let f = try F(); let w = f.worker(); f.clock = date("2026-11-10T02:59:59Z")
            check(await w.tick() == .skipped, "03 gate")
            f.clock = date("2026-11-10T03:00:00Z"); f.idle = false
            check(await w.tick() == .busy, "idle gate"); f.idle = true; f.enabled = false
            check(await w.tick() == .skipped, "toggle gate")
            check(f.calls == 0 && !FileManager.default.fileExists(atPath: f.stateURL.path), "no early side effect")
        }
        do {
            let f = try F(); let a = f.history("PRIVATE_BODY_1 Clawd"), b = f.history("PRIVATE_BODY_2 Clawd")
            f.proposals = [f.proposal("Clawd", "ClaudeCode", [a,b])]
            check(await f.worker().tick() == .added(1), "verified repeat accepted")
            check(f.dict.terms.contains("ClaudeCode"), "actual dictionary")
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f.dict.dictPath))) as! [Any]
            check((rows[1] as? [String:Any])?["futureField"] as? Bool == true, "unknown rows preserved")
            let state = String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self)
            check(!state.contains("PRIVATE_BODY"), "no transcript persisted")
            check(state.contains("committed") && state.contains(a.id), "audit evidence")
            let backups = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasPrefix("dictionary-backup-") }
            check(backups.count == 1, "backup")
            _ = await f.worker().tick(); check(f.calls == 1, "restart once per day")
            f.nextDay(); _ = await f.worker().tick(); check(f.calls == 1, "no model without new records")
        }
        do {
            let f = try F(); let r = f.history("Clawd and FakeClawdSuffix")
            f.proposals = [W.Proposal(wrong: "Clawd", suggested: "ClaudeCode", recordIDs: [r.id,r.id,"fake"]), W.Proposal(wrong: "FakeClawd", suggested: "OtherProper", recordIDs: [r.id,"fake"])]
            _ = await f.worker().tick(); check(f.dict.terms == ["ExistingTerm"], "duplicate/phantom/nonliteral evidence rejected")
        }
        do {
            let f = try F(); let a = f.history("Cloud 公司 lowercase Clawd Qwne Ambig X"), b = f.history("Cloud 公司 lowercase Clawd Qwne Ambig X again")
            f.proposals = [("Cloud","ClaudeCode"),("公司","Corporation"),("lowercase","ProperName"),("X","AnotherTerm"),("Clawd","ExistingTerm"),("Qwne","Qwen"),("Ambig","NameA"),("Ambig","NameB")].map { f.proposal($0.0,$0.1,[a,b]) }
            f.aliases = [W.AliasRule(from: "Qwne", to: "Qwen")]
            _ = await f.worker().tick(); check(f.dict.terms == ["ExistingTerm"], "safety filters")
        }
        do {
            let f = try F(); let text = (0..<12).map { "ErrName\($0)" }.joined(separator: " ")
            let a = f.history(text), b = f.history(text + " next")
            f.proposals = (0..<12).map { f.proposal("ErrName\($0)","ProperName\($0)",[a,b]) }
            check(await f.worker().tick() == .added(10), "limit 10")
            _ = await f.worker().tick(); check(f.dict.terms.count == 11 && f.calls == 1, "no same-day overflow")
            f.nextDay(); check(await f.worker().tick() == .added(2), "overflow next night")
            check(f.calls == 1 && f.dict.terms.count == 13, "overflow survives restart without LLM")
        }
        do {
            let f = try F(); let stamp = f.clock.addingTimeInterval(-120.1234567)
            for i in 0..<155 { f.history("Record \(i)", at: stamp) }
            _ = await f.worker().tick(); check(f.seen[0].count == 150, "bounded batch")
            f.nextDay(); _ = await f.worker().tick(); check(f.seen[1].count == 5, "timestamp tie overflow")
            check(Set(f.seen[0].map { $0.id }).isDisjoint(with: Set(f.seen[1].map { $0.id })), "subsecond cursor avoids rescan")
            f.nextDay(); _ = await f.worker().tick(); check(f.calls == 2, "155 records exactly once")
        }
        do {
            let f = try F(); let a = f.history("Clawd one"); f.proposals = [f.proposal("Clawd","ClaudeCode",[a])]
            _ = await f.worker().tick(); check(f.dict.terms.count == 1, "one queues")
            f.nextDay(); let b = f.history("Clawd two"); f.proposals = [f.proposal("Clawd","ClaudeCode",[b])]
            check(await f.worker().tick() == .added(1), "cross-night repeat")
            check(f.seen[1].map { $0.id } == [b.id], "incremental only")
        }
        do {
            let f = try F(); f.history("Clawd one"); f.fail = true
            check(await f.worker().tick() == .failed, "model failure")
            _ = await f.worker().tick(); check(f.calls == 1, "no same-day paid retry")
            f.fail = false; f.nextDay(); _ = await f.worker().tick()
            check(f.calls == 2 && f.seen[1].count == 1, "failed cursor retained")
            f.clock = f.clock.addingTimeInterval(-86400); _ = await f.worker().tick(); check(f.calls == 2, "clock rollback protected")
        }
        do {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            f.proposals = [f.proposal("Clawd","ClaudeCode",[a,b])]; f.becomeBusy = true
            let w = f.worker(); _ = await w.tick(); check(f.dict.terms.count == 1 && f.calls == 1, "foreground wins after model")
            f.idle = true; check(await w.tick() == .added(1) && f.calls == 1, "next idle writes without model")
        }
        for broken in ["dictionary","aliases","state"] {
            let f = try F(); f.history("Clawd one")
            if broken == "dictionary" { try Data("{broken".utf8).write(to: URL(fileURLWithPath: f.dict.dictPath)) }
            if broken == "aliases" { f.brokenAliases = true }
            if broken == "state" { try Data("{broken".utf8).write(to: f.stateURL) }
            let before = try Data(contentsOf: URL(fileURLWithPath: f.dict.dictPath))
            check(await f.worker().tick() == .failed && f.calls == 0, "\(broken) fails before model")
            check(try Data(contentsOf: URL(fileURLWithPath: f.dict.dictPath)) == before, "\(broken) byte preservation")
        }
        do {
            let f = try F(); try JSONSerialization.data(withJSONObject: ["", " A ", ["future":true]] as [Any]).write(to: URL(fileURLWithPath: f.dict.dictPath))
            check(f.dict.updateTerm(at: 0, to: "RenamedTerm"), "UI index ignores empty rows")
            check(f.dict.terms == ["RenamedTerm"], "correct term updated")
            f.dict.removeTerm(at: 0); check(f.dict.terms.isEmpty, "correct term removed")
            for i in 0..<7 { _ = f.dict.addTerm("Term\(i)") }
            let backups = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasPrefix("dictionary-backup-") }
            check(backups.count == 5, "backup retention")
            try Data("not json".utf8).write(to: URL(fileURLWithPath: f.dict.dictPath))
            check(!f.dict.addTerm("MustNotOverwrite"), "manual corruption guard")
            check(try String(contentsOfFile: f.dict.dictPath, encoding: .utf8) == "not json", "original bytes")
        }
        do {
            let f = try F(); let url = f.dir.appendingPathComponent("config.json")
            try Data("{\"futureField\":{\"intact\":true}}".utf8).write(to: url)
            var errors = 0, keys = 0
            let c = ConfigService(directory: f.dir.path, getKey: { _ in keys += 1; return nil }, setKey: { _,_ in keys += 1; return true }, reportError: { _ in errors += 1 })
            check(c.dictionaryAutoUpdateEnabled, "default enabled"); c.dictionaryAutoUpdateEnabled = false
            check(!c.dictionaryAutoUpdateEnabled && errors == 0 && keys == 0, "switch no credentials")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String:Any]
            check((json["futureField"] as? [String:Any])?["intact"] as? Bool == true, "config unknown preserved")
        }
        // A persisted prepared audit reconciles either side of the atomic rename.
        for wasWritten in [false, true] {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            f.proposals = [f.proposal("Clawd", "ClaudeCode", [a,b])]; f.becomeBusy = true
            _ = await f.worker().tick()
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            let candidate = (json["pending"] as! [[String:Any]])[0]
            var entry = candidate; entry["occurrences"] = 2
            json["audit"] = [["timestamp": "2026-11-10T03:00:00Z", "day": "1-2026-11-10", "entries": [entry], "status": "prepared"]]
            try JSONSerialization.data(withJSONObject: json).write(to: f.stateURL)
            if wasWritten { _ = try f.dict.addTermsSafely(["ClaudeCode"]) }
            f.idle = true; f.becomeBusy = false
            _ = await f.worker().tick()
            check(f.dict.terms.filter { $0 == "ClaudeCode" }.count == 1, "prepared transaction recovery")
            check(f.calls == 1, "recovery never calls model")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            let audit = saved["audit"] as! [[String:Any]]
            check(audit.last?["status"] as? String == "committed", "recovery commit audit")
            check((audit.last?["entries"] as? [[String:Any]])?.first?["occurrences"] as? Int == 2, "explicit real occurrence count")
            if wasWritten {
                let run = try W.readLastRun(directory: f.dir.path)
                check(run?.reasonCode == .recovered && run?.failed == false && run?.added == 1, "recovered prepared is visible as confirmed success")
            }
        }
        // A slow scan permits foreground work and reentrant ticks, never a second scan.
        do {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            var continuation: CheckedContinuation<[W.Proposal], Error>?
            var calls = 0
            let worker = W(directory: f.dir.path, dictionary: f.dict, now: { f.clock },
                calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c },
                isEnabled: { f.enabled }, isIdle: { f.idle }, history: { f.records }, aliases: { [] },
                scan: { _, _ in calls += 1; return try await withCheckedThrowingContinuation { continuation = $0 } })
            let first = Task { await worker.tick() }
            while continuation == nil { await Task.yield() }
            check(await worker.tick() == .skipped && calls == 1, "in-flight tick guard")
            f.enabled = false
            continuation!.resume(returning: [f.proposal("Clawd", "ClaudeCode", [a,b])])
            _ = await first.value
            check(f.dict.terms.count == 1, "toggle off while awaiting refuses write")
            f.enabled = true; _ = await worker.tick()
            check(f.dict.terms.contains("ClaudeCode") && calls == 1, "toggle on resumes pending only")
        }
        do {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            f.proposals = [f.proposal("Clawd", "ClaudeCode", [a,b])]
            f.aliases = [W.AliasRule(from: "Unrelated[A-Z]+", to: "Other", matchMode: "regex")]
            _ = await f.worker().tick()
            check(f.dict.terms.contains("ClaudeCode"), "unrelated regex allows candidate")
        }
        do {
            let f = try F()
            check(try W.readAliasRules(directory: f.dir.path).isEmpty, "missing alias file is empty")
            let url = f.dir.appendingPathComponent("aliases.json")
            let bytes = try JSONSerialization.data(withJSONObject: ["future-row", ["unknown":true], ["from":"Clawd", "to":"Claude", "futureField":true]] as [Any])
            try bytes.write(to: url)
            let rules = try W.readAliasRules(directory: f.dir.path)
            check(rules.count == 1 && rules[0].from == "Clawd", "unknown alias entries retained and ignored")
            check(try Data(contentsOf: url) == bytes, "read never changes alias bytes")
            try Data("[{\"from\":1,\"to\":\"Claude\"}]".utf8).write(to: url)
            do { _ = try W.readAliasRules(directory: f.dir.path); check(false, "damaged known alias must throw") }
            catch { check(true, "damaged known alias refused") }
        }
        for pattern in ["Cl[a-z]+", "["] {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            f.proposals = [f.proposal("Clawd", "ClaudeCode", [a,b])]
            f.aliases = [W.AliasRule(from: pattern, to: "Other", matchMode: "regex")]
            _ = await f.worker().tick()
            check(f.dict.terms.count == 1, "matching or invalid regex blocks candidate")
        }
        do {
            let f = try F(); let wrong = String(repeating: "A", count: 38) + "!"
            let a = f.history(wrong + " one"), b = f.history(wrong + " two")
            f.proposals = [f.proposal(wrong, "CorrectProper", [a,b])]
            f.aliases = [W.AliasRule(from: "^(a+)+$", to: "Other", matchMode: "regex")]
            let started = ProcessInfo.processInfo.systemUptime
            _ = await f.worker().tick()
            check(ProcessInfo.processInfo.systemUptime - started < 1, "pathological regex is bounded")
            check(!f.dict.terms.contains("CorrectProper"), "regex timeout fails closed")
        }
        // Shared response parser: both manual/auto paths accept just an enclosing
        // json or unlabelled fence; malformed content must remain a failure.
        do {
            struct Parsed: Decodable { let suggestions: [Int] }
            let json = "{\"suggestions\":[1,2]}"
            for raw in [json, "```json\n" + json + "\n```", "```\n" + json + "\n```", "```JSON\r\n" + json + "\r\n```"] {
                check(try JSONResponseParser.decode(Parsed.self, from: raw).suggestions == [1,2], "shared plain/fenced JSON")
            }
            for raw in ["```json\n{broken}\n```", "{broken", "```json\n" + json, "prose\n" + json, "```python\n" + json + "\n```"] {
                do { _ = try JSONResponseParser.decode(Parsed.self, from: raw); check(false, "malformed JSON must fail") }
                catch { check(true, "malformed JSON refused") }
            }
        }
        do {
            let f = try F(); f.history("Clawd one"); f.canScan = false
            check(await f.worker().tick() == .skipped && f.calls == 0, "none provider skips scanner")
            let original = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            check((original["attemptedDays"] as? [String])?.isEmpty == true, "none provider spends no daily claim")
            check(try W.readLastRun(directory: f.dir.path) == nil, "none provider creates no synthetic run timestamp")
            _ = await f.worker().tick(); check(f.calls == 0, "none provider repeated tick stays free")
            f.canScan = true; _ = await f.worker().tick()
            check(f.calls == 1, "same date can scan after provider configured")
            check(!W.hasConfiguredProvider(["provider":"none","none":["baseURL":"https://example.invalid", "model":"x"]]), "explicit none never configured")
            check(!W.hasConfiguredProvider([:]) && !W.hasConfiguredProvider(["provider":"missing"]), "nil or missing provider disabled")
            check(!W.hasConfiguredProvider(["provider":"p","p":["baseURL":"", "model":"x"]]), "invalid model config disabled")
            check(W.hasConfiguredProvider(["provider":"p","p":["baseURL":"https://example.invalid", "model":"x"]]), "non-secret config presence gate")
        }
        do {
            let f = try F(); let a = f.history("Clawd one"), b = f.history("Clawd two")
            f.proposals = [f.proposal("Clawd","ClaudeCode",[a,b])]; f.becomeBusy = true
            _ = await f.worker().tick(); f.nextDay(); f.idle = true; f.canScan = false
            check(await f.worker().tick() == .added(1), "pending applies without provider")
            check(f.calls == 1, "pending write never requests unavailable provider")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            check(!(json["attemptedDays"] as! [String]).contains("1-2026-11-11"), "pending-only write spends no scan claim")
            let run = try W.readLastRun(directory: f.dir.path)
            check(run?.added == 1 && run?.failed == false && run?.reasonCode == .completed, "actual pending write status")
        }
        do {
            let f = try F(); f.history("PRIVATE_BODY Clawd"); f.fail = true
            _ = await f.worker().tick()
            let status = try W.readLastRun(directory: f.dir.path)
            check(status?.timestamp == f.clock && status?.failed == true && status?.added == 0 && status?.reasonCode == .scanFailed, "failed run has fixed reason code")
            let before = try Data(contentsOf: f.stateURL)
            check(!String(decoding: before, as: UTF8.self).contains("PRIVATE") && !String(decoding: before, as: UTF8.self).contains("SECRET"), "failure persistence excludes raw errors/body")
            _ = try W.readLastRun(directory: f.dir.path)
            check(try Data(contentsOf: f.stateURL) == before && f.calls == 1, "status read does not write or scan")
            _ = await f.worker().tick()
            check(try W.readLastRun(directory: f.dir.path) == status, "idle tick preserves last failure")
            f.canScan = false; _ = await f.worker().tick()
            check(try W.readLastRun(directory: f.dir.path) == status, "none provider does not erase prior failure/time")
        }
        do {
            let f = try F(); try Data("{damaged".utf8).write(to: f.stateURL)
            _ = await f.worker().tick()
            check(try Data(contentsOf: f.stateURL) == Data("{damaged".utf8), "failed status cannot replace corrupt state")
            do { _ = try W.readLastRun(directory: f.dir.path); check(false, "damaged status must throw") }
            catch { check(true, "read-only damaged status rejected") }
        }
        do {
            let f = try F()
            // Exact r1 schema deliberately omits both new optional fields.
            let legacy: [String:Any] = ["version":1,"attemptedDays":[],"cursorIDs":[],"pending":[],"audit":[]]
            try JSONSerialization.data(withJSONObject: legacy).write(to: f.stateURL)
            check(try W.readLastRun(directory: f.dir.path) == nil, "r1 status absence compatible")
            _ = await f.worker().tick()
            check(try W.readLastRun(directory: f.dir.path)?.reasonCode == .noNewHistory, "r1 worker state loads and upgrades")
        }
        do {
            let f = try F(); f.canScan = false
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
            func key(_ date: Date) -> String {
                let p = c.dateComponents([.era,.year,.month,.day], from: date)
                return "\(p.era!)-\(p.year!)-\(p.month!)-\(p.day!)"
            }
            let dates = (0..<65).map { f.clock.addingTimeInterval(Double(-$0) * 86400) }
            let iso = ISO8601DateFormatter()
            let audits = (0..<250).map { ["timestamp":iso.string(from: f.clock.addingTimeInterval(Double(-$0))),"day":key(f.clock),"entries":[],"status":"committed"] as [String:Any] }
            let old: [String:Any] = ["timestamp":"2026-08-01T03:00:00Z","day":"1-2026-8-1","entries":[],"status":"not_applied"]
            let json: [String:Any] = ["version":1,"attemptedDays":dates.map(key),"cursorIDs":[],"pending":[],"audit":audits + [old]]
            try JSONSerialization.data(withJSONObject: json).write(to: f.stateURL)
            _ = await f.worker().tick()
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            check((saved["attemptedDays"] as! [String]).count == 30, "attempt dates bounded to thirty calendar days")
            check((saved["audit"] as! [[String:Any]]).count == 200, "confirmed audit capped at 200")
            check(!(saved["audit"] as! [[String:Any]]).contains { $0["day"] as? String == "1-2026-8-1" }, "old audit trimmed")
            // Rolling the clock back does not delete a recent already-claimed later date.
            f.clock = f.clock.addingTimeInterval(-86400); _ = await f.worker().tick()
            let back = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            check((back["attemptedDays"] as! [String]).contains("1-2026-11-10"), "recent future claim retained during rollback")
            check((back["attemptedDays"] as! [String]).count == 30, "rollback retention stays bounded")
        }
        do {
            let f = try F(); f.canScan = false
            let entries: [[String:Any]] = [
                ["wrong":"OldWrong1","suggested":"ExistingTerm","recordIDs":["id1","id2"],"occurrences":2],
                ["wrong":"OldWrong2","suggested":"NotWritten","recordIDs":["id3","id4"],"occurrences":2]
            ]
            // Partial authoritative match is unresolved, so an old prepared journal
            // must survive pruning and must not permit another prepared transaction.
            let prepared: [String:Any] = ["timestamp":"2026-08-01T03:00:00Z","day":"1-2026-8-1","entries":entries,"status":"prepared"]
            let legacy: [String:Any] = ["version":1,"attemptedDays":[],"cursorIDs":[],"pending":[],"audit":[prepared]]
            try JSONSerialization.data(withJSONObject: legacy).write(to: f.stateURL)
            check(await f.worker().tick() == .failed, "unresolved prepared blocks continuation")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            let audit = saved["audit"] as! [[String:Any]]
            check(audit.count == 1 && audit[0]["status"] as? String == "prepared", "old unresolved prepared survives retention")
            check(try W.readLastRun(directory: f.dir.path)?.reasonCode == .recoveryFailed && f.calls == 0, "recovery failure code no extra scan")
        }
        do {
            // Eagle's exact reproduction: the first history predates the future
            // jump, so a future cursor cannot accidentally mask duplicate scans.
            let f = try F()
            f.history("Clawd zero")
            f.clock = date("2029-11-10T04:00:00Z"); _ = await f.worker().tick()
            check(f.calls == 1, "future tick scans once")
            f.clock = date("2026-11-11T04:00:00Z")
            for i in 0..<5 {
                f.history("Clawd \(i)", at: f.clock.addingTimeInterval(-1))
                _ = await f.worker().tick()
                f.clock = f.clock.addingTimeInterval(60)
            }
            check(f.calls - 1 == 1, "forward jump then return: one scan despite five new dictations")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as! [String:Any]
            let days = saved["attemptedDays"] as! [String]
            check(days.contains("1-2026-11-11") && days.contains("1-2029-11-10"), "current and future claims both survive save")
            f.clock = date("2029-11-10T05:00:00Z"); f.history("Clawd revisit future")
            _ = await f.worker().tick()
            check(f.calls == 2, "revisit already-claimed future day does not scan twice")
        }
        do {
            let f = try F()
            f.history("Rollback seed", at: date("2026-11-10T02:00:00Z"))
            f.clock = date("2026-11-11T04:00:00Z"); _ = await f.worker().tick()
            f.clock = date("2026-11-10T04:00:00Z")
            for i in 0..<5 {
                f.history("Rollback new \(i)", at: f.clock.addingTimeInterval(-1))
                _ = await f.worker().tick()
                f.clock = f.clock.addingTimeInterval(60)
            }
            check(f.calls == 2, "backward jump: one scan per distinct day")
            f.clock = date("2026-11-11T05:00:00Z"); f.history("Rollback restored")
            _ = await f.worker().tick()
            check(f.calls == 2, "restore after rollback retains the already-claimed later day")
        }
        do {
            let f = try F(); f.canScan = false
            let future: [String:Any] = ["timestamp":"2029-11-10T04:00:00Z","day":"1-2029-11-10","entries":[],"status":"committed"]
            let stale: [String:Any] = ["timestamp":"2026-08-01T04:00:00Z","day":"1-2026-8-1","entries":[],"status":"committed"]
            let legacy: [String:Any] = ["version":1,"attemptedDays":["1-2029-11-10","1-2026-11-10","1-2026-8-1"],"cursorIDs":[],"pending":[],"audit":[future,stale],"retentionAnchor":"2029-11-10T04:00:00Z"]
            try JSONSerialization.data(withJSONObject:legacy).write(to:f.stateURL)
            _ = await f.worker().tick()
            let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:f.stateURL)) as! [String:Any]
            check(Set(saved["attemptedDays"] as! [String]) == Set(["1-2029-11-10","1-2026-11-10"]), "now window removes old claims while retaining all future dates")
            let audits = saved["audit"] as! [[String:Any]]
            check(audits.count == 1 && audits[0]["day"] as? String == "1-2029-11-10", "future audit retained even when older anchor was persisted")
        }
        print("PASS: \(checks) vocabulary regression assertions; isolated paths, no network or Keychain")
    }
}
