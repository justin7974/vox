import Foundation

struct VoxConfig: Codable {
    // === Hotkey ===
    var dictationHotkey: HotkeyConfig
    var launcherHotkey: HotkeyConfig?
    var hotkeyMode: String  // "toggle" | "hold"

    // === ASR ===
    var asr: String  // "whisper" | "qwen" | "custom"
    var whisper: WhisperConfig?
    var qwenASR: QwenASRConfig?
    var customASR: CustomASRConfig?

    // === LLM ===
    var provider: String
    var providers: [String: ProviderConfig]

    // === User ===
    var userContext: String?

    // === History ===
    var historyEnabled: Bool
    var historyRetentionDays: Int

    // === Launcher ===
    var editWindowDuration: Double
    var editWindowEnabled: Bool
    var clipboardMaxItems: Int

    struct HotkeyConfig: Codable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    struct WhisperConfig: Codable {
        var executablePath: String?
        var modelPath: String?
    }

    struct QwenASRConfig: Codable {
        var apiKey: String
    }

    struct CustomASRConfig: Codable {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    struct ProviderConfig: Codable {
        var baseURL: String
        var apiKey: String
        var model: String
        var format: String?
    }
}
