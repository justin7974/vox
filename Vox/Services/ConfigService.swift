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
    }

    func write(key: String, value: Any) {
        raw[key] = value
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
        (raw["qwen-asr"] as? [String: Any])?["apiKey"] as? String
    }

    var customASRConfig: (baseURL: String, apiKey: String, model: String)? {
        guard let cfg = raw["custom-asr"] as? [String: Any],
              let baseURL = cfg["baseURL"] as? String,
              let apiKey = cfg["apiKey"] as? String,
              let model = cfg["model"] as? String else { return nil }
        return (baseURL, apiKey, model)
    }

    var whisperExecPath: String {
        (raw["whisper"] as? [String: Any])?["executablePath"] as? String
            ?? "/opt/homebrew/bin/whisper-cli"
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
              let apiKey = cfg["apiKey"] as? String,
              let model = cfg["model"] as? String else { return nil }
        return (baseURL, apiKey, model, cfg["format"] as? String)
    }

    var userContext: String? { raw["userContext"] as? String }

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
