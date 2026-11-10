import Cocoa

// Short state lock protects only the snapshot. A separate serial writer queue orders
// disk/Keychain transactions; Keychain is NEVER called while the state lock is held.
final class ConfigService: @unchecked Sendable {
    static let shared = ConfigService()

    private let configDir: String
    private var configPath: String { configDir + "/config.json" }
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "com.vox.config.writes")
    private var storage: [String: Any] = [:]
    private var raw: [String: Any] { synchronized { storage } }
    private let getKey: (String) -> String?
    private let setKey: (String, String) -> Bool
    private let reportError: (String) -> Void

    private convenience init() {
        self.init(directory: NSHomeDirectory() + "/.vox",
                  getKey: { KeychainService.get(account: $0) },
                  setKey: { KeychainService.set(account: $0, value: $1) },
                  reportError: { message in
                      DispatchQueue.main.async {
                          let alert = NSAlert()
                          alert.messageText = "Vox Settings"
                          alert.informativeText = message
                          alert.runModal()
                      }
                  }, migrateDirectory: true)
    }

    // Explicit paths and key-store functions keep tests away from the real profile/Keychain.
    init(directory: String, getKey: @escaping (String) -> String?,
         setKey: @escaping (String, String) -> Bool,
         reportError: @escaping (String) -> Void, migrateDirectory: Bool = false) {
        self.configDir = directory
        self.getKey = getKey
        self.setKey = setKey
        self.reportError = reportError
        if migrateDirectory { migrateConfigDir() }
        reload()
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var configExists: Bool { FileManager.default.fileExists(atPath: configPath) }

    private func readDisk() throws -> (value: [String: Any], bytes: Data?) {
        guard configExists else { return ([:], nil) }
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (json, data)
    }

    func reload() {
        writes.sync {
            do {
                let disk = try readDisk()
                let migrated = migrateApiKeysToKeychain(disk.value, expected: disk.bytes)
                synchronized { storage = migrated }
            } catch {
                // Keep the last known-good snapshot, but never write over corrupt bytes.
                reportError("config.json could not be read. Fix the file before saving; it has not been replaced.")
            }
        }
    }

    @discardableResult
    func write(key: String, value: Any) -> Bool { write(values: [key: value]) }

    /// Merge into the latest disk document, retaining unknown settings/fields. An explicit
    /// empty apiKey means delete; omitted apiKey means retain the existing key.
    @discardableResult
    func write(values: [String: Any]) -> Bool {
        writes.sync {
            do {
                let disk = try readDisk()
                var next = disk.value
                var oldKeys: [String: String] = [:]
                for (key, value) in values {
                    if var dict = value as? [String: Any] {
                        var merged = next[key] as? [String: Any] ?? [:]
                        if let secret = dict["apiKey"] as? String {
                            let old = getKey(key) ?? ""
                            guard setKey(key, secret) else {
                                restoreKeys(oldKeys)
                                reportError("Keychain refused the change. Settings were not saved.")
                                return false
                            }
                            oldKeys[key] = old
                            dict["apiKey"] = ""
                        }
                        merged.merge(dict) { _, new in new }
                        next[key] = merged
                    } else { next[key] = value }
                }
                do { try persist(next, expected: disk.bytes) }
                catch {
                    restoreKeys(oldKeys)
                    throw error
                }
                synchronized { storage = next }
                return true
            } catch {
                reportError("Could not save config.json. The existing file was preserved; check its JSON and permissions.")
                return false
            }
        }
    }

    private func restoreKeys(_ values: [String: String]) {
        for (account, old) in values where !setKey(account, old) {
            reportError("Keychain rollback could not be verified. Check your API key in Settings before using this provider.")
        }
    }

    private func persist(_ value: [String: Any], expected: Data?) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let directory = URL(fileURLWithPath: configDir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: configPath)
        let current = configExists ? try Data(contentsOf: url) : nil
        guard current == expected else { throw CocoaError(.fileWriteUnknown) }
        if let original = current {
            try JSONBackupStore.backup(original, directory: directory, prefix: "config-backup-")
        }
        // Backup/pruning may take time: reject a manual edit made during that interval.
        guard (configExists ? try Data(contentsOf: url) : nil) == expected else { throw CocoaError(.fileWriteUnknown) }
        try JSONBackupStore.atomicWrite(data, to: url)
    }

    var rawDict: [String: Any] { raw }

    // MARK: - Hotkey

    var hotkeyMode: String { raw["hotkeyMode"] as? String ?? "toggle" }
    var hotkeyKeyCode: UInt32 { UInt32(raw["hotkeyKeyCode"] as? Int ?? 50) }  // kVK_ANSI_Grave
    var hotkeyModifiers: UInt32 { UInt32(raw["hotkeyModifiers"] as? Int ?? 4096) }  // controlKey

    // MARK: - ASR

    var asrProvider: String { raw["asr"] as? String ?? "whisper" }

    var qwenASRApiKey: String? {
        apiKey(for: "qwen-asr")
    }

    var customASRConfig: (baseURL: String, apiKey: String, model: String)? {
        let snapshot = raw
        guard let cfg = snapshot["custom-asr"] as? [String: Any],
              let baseURL = cfg["baseURL"] as? String, let model = cfg["model"] as? String else { return nil }
        return (baseURL, apiKey(for: "custom-asr", snapshot: snapshot) ?? "", model)
    }

    var whisperExecPath: String {
        if let configured = (raw["whisper"] as? [String: Any])?["executablePath"] as? String,
           !configured.isEmpty {
            return configured
        }
        return STTService.resolveBinary(name: "whisper-cli", fallback: "/opt/homebrew/bin/whisper-cli")
    }

    var whisperModelPath: String {
        (raw["whisper"] as? [String: Any])?["modelPath"] as? String
            ?? NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"
    }

    // MARK: - LLM

    var llmProvider: String? { raw["provider"] as? String }

    func llmProviderConfig(for name: String) -> (baseURL: String, apiKey: String, model: String, format: String?)? {
        let snapshot = raw
        guard let cfg = snapshot[name] as? [String: Any],
              let baseURL = cfg["baseURL"] as? String, let model = cfg["model"] as? String else { return nil }
        let shared = name == "qwen-llm" && snapshot["asr"] as? String == "qwen" ? "qwen-asr" : name
        let key = apiKey(for: shared, snapshot: snapshot) ?? apiKey(for: name, snapshot: snapshot) ?? ""
        return (baseURL, key, model, cfg["format"] as? String)
    }

    var userContext: String? { raw["userContext"] as? String }

    /// Enumerate provider names configured in config.json (any top-level dict
    /// that has both `baseURL` and `model` — excludes ASR-only entries like qwen-asr).
    var availableLLMProviders: [String] {
        raw.compactMap { (key, value) -> String? in
            guard let dict = value as? [String: Any],
                  dict["baseURL"] is String,
                  dict["model"] is String else { return nil }
            return key
        }.sorted()
    }

    // MARK: - History

    var historyEnabled: Bool {
        get { raw["historyEnabled"] as? Bool ?? true }
        set { write(key: "historyEnabled", value: newValue) }
    }

    var historyRetentionDays: Int {
        get { raw["historyRetentionDays"] as? Int ?? 7 }
        set { write(key: "historyRetentionDays", value: newValue) }
    }

    // MARK: - Keychain helpers

    /// Keychain-first lookup with legacy fallback to the JSON dict.
    private func apiKey(for providerKey: String, snapshot: [String: Any]? = nil) -> String? {
        let snapshot = snapshot ?? raw // release snapshot lock before Keychain can prompt
        if let secret = getKey(providerKey), !secret.isEmpty { return secret }
        if let dict = snapshot[providerKey] as? [String: Any],
           let legacy = dict["apiKey"] as? String, !legacy.isEmpty { return legacy }
        return nil
    }

    // Called only on the writer queue, with no state lock held. Readers keep using
    // the last good snapshot while a Keychain authorization prompt is outstanding.
    private func migrateApiKeysToKeychain(_ original: [String: Any], expected: Data?) -> [String: Any] {
        var next = original
        var mutated = false
        for (key, value) in original {
            guard var dict = value as? [String: Any], let secret = dict["apiKey"] as? String, !secret.isEmpty else { continue }
            guard setKey(key, secret) else {
                reportError("A legacy API key could not be moved to Keychain. The original config is retained; unlock Keychain and reload.")
                continue
            }
            dict["apiKey"] = ""
            next[key] = dict
            mutated = true
        }
        if mutated {
            do { try persist(next, expected: expected) }
            catch {
                reportError("API key migration could not save config.json. Original settings retained.")
                return original
            }
        }
        return next
    }

    // MARK: - Migration

    private func migrateConfigDir() {
        let fm = FileManager.default
        let oldDir = NSHomeDirectory() + "/.voiceinput"
        guard fm.fileExists(atPath: oldDir), !fm.fileExists(atPath: configDir) else { return }
        do {
            try fm.moveItem(atPath: oldDir, toPath: configDir)
            NSLog("Vox: Migrated config from ~/.voiceinput → ~/.vox")
        } catch {
            NSLog("Vox: Config migration failed: \(error.localizedDescription)")
        }
    }
}
