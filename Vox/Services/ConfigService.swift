import Foundation

final class ConfigService {
    static let shared = ConfigService()

    private let configDir = NSHomeDirectory() + "/.vox"
    private var configPath: String { configDir + "/config.json" }
    private var raw: [String: Any] = [:]

    // MARK: - Init

    private init() {
        migrateConfigDir()
        reload()
    }

    // MARK: - Public API

    var configExists: Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            raw = [:]
            return
        }
        raw = json
        migrateApiKeysToKeychain()
    }

    /// Sets `raw[key] = value`. If value is a provider-dict containing a non-empty apiKey,
    /// route that apiKey into the keychain and strip it from the on-disk JSON.
    func write(key: String, value: Any) {
        var stored: Any = value
        if var dict = value as? [String: Any], let apiKey = dict["apiKey"] as? String {
            if !apiKey.isEmpty {
                KeychainService.set(account: key, value: apiKey)
            }
            dict["apiKey"] = ""  // leave placeholder so existing parsers still find the field
            stored = dict
        }
        raw[key] = stored
        persistRaw()
    }

    private func persistRaw() {
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Raw dict access for SetupWindow and other code that builds config manually
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
        guard let cfg = raw["custom-asr"] as? [String: Any],
              let baseURL = cfg["baseURL"] as? String,
              let model = cfg["model"] as? String else { return nil }
        let key = apiKey(for: "custom-asr") ?? (cfg["apiKey"] as? String ?? "")
        return (baseURL, key, model)
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
        guard let cfg = raw[name] as? [String: Any],
              let baseURL = cfg["baseURL"] as? String,
              let model = cfg["model"] as? String else { return nil }
        // qwen-llm shares the ASR key when ASR is also qwen.
        let keychainAccount = (name == "qwen-llm" && asrProvider == "qwen") ? "qwen-asr" : name
        let key = apiKey(for: keychainAccount) ?? (cfg["apiKey"] as? String ?? "")
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

    // MARK: - Edit Window

    var editWindowEnabled: Bool {
        raw["editWindowEnabled"] as? Bool ?? true
    }

    var editWindowDuration: Double {
        raw["editWindowDuration"] as? Double ?? 3.0
    }

    // MARK: - Keychain helpers

    /// Keychain-first lookup with legacy fallback to the JSON dict.
    private func apiKey(for providerKey: String) -> String? {
        if let kc = KeychainService.get(account: providerKey), !kc.isEmpty {
            return kc
        }
        if let dict = raw[providerKey] as? [String: Any],
           let legacy = dict["apiKey"] as? String, !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    /// One-shot migration: any apiKey field still sitting in config.json gets moved into the keychain
    /// and replaced with an empty placeholder. Runs on every reload but is a no-op after the first pass.
    private func migrateApiKeysToKeychain() {
        var mutated = false
        for (key, value) in raw {
            guard var dict = value as? [String: Any],
                  let apiKey = dict["apiKey"] as? String,
                  !apiKey.isEmpty else { continue }
            if KeychainService.set(account: key, value: apiKey) {
                dict["apiKey"] = ""
                raw[key] = dict
                mutated = true
                NSLog("Vox: Migrated \(key) apiKey to Keychain")
            }
        }
        if mutated { persistRaw() }
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
