import Cocoa
// Test-only services. No UI, microphone, API, input events, clipboard or Keychain.
final class NSSound { init?(named: String) {}; func play() {} }
final class LogService {
    static let shared = LogService()
    static var errors: [String] = []
    func debug(_ text: String) {}
    func error(_ text: String) { Self.errors.append(text) }
}
final class ConfigService { static let shared = ConfigService(); var configExists = true }
final class AudioService {
    static let shared = AudioService()
    var onAudioLevel: ((Float) -> Void)?
    var hasAudio = true
    var peakPower: Float = -10
    static var starts = 0
    func startRecording() { Self.starts += 1 }
    func stopRecording() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vox325-flow-\(UUID().uuidString).wav")
        try! Data(repeating: 0, count: 20000).write(to: url)
        return url
    }
}
final class STTService {
    static let shared = STTService()
    static var output = "fixture raw"
    static var calls = 0
    func transcribe(audioFile: URL) async -> String { Self.calls += 1; return Self.output }
}
final class LLMService {
    struct Call { let custom: String?; let translate: Bool; let required: Bool; let aliases: Bool }
    static let shared = LLMService()
    static var calls: [Call] = []
    static var output = "fixture polished"
    var isConfigured = true
    func process(rawText: String, contextHint: String? = nil, customSystemPrompt: String? = nil,
                 translateMode: Bool = false, requireLLM: Bool = false, applyAliases: Bool = false) async -> String {
        Self.calls.append(Call(custom: customSystemPrompt, translate: translateMode, required: requireLLM, aliases: applyAliases))
        return Self.output
    }
}
final class PasteService {
    static let shared = PasteService()
    static var pending: ((Bool) -> Void)?
    static var texts: [String] = []
    func paste(text: String, completion: ((Bool) -> Void)? = nil) { Self.texts.append(text); Self.pending = completion }
    static func complete(_ dispatched: Bool) { let done = pending; pending = nil; done?(dispatched) }
}
final class ContextService {
    static let shared = ContextService()
    func detect() -> String { "fixture" }
    func contextHint(for: String) -> String? { nil }
}
final class HistoryService {
    struct Record { let text: String; let original: String?; let translation: Bool }
    static let shared = HistoryService()
    static var records: [Record] = []
    func addRecord(text: String, originalText: String? = nil, isTranslation: Bool = false) {
        Self.records.append(Record(text: text, original: originalText, translation: isTranslation))
    }
}
final class StatusOverlay {
    static var phases: [VoxPhase] = []
    func show(phase: VoxPhase) { Self.phases.append(phase) }
    func hide() { Self.phases.append(.idle) }
    func updateAudioLevel(_ level: Float) {}
}
final class AppDelegate {
    static let shared = AppDelegate()
    var translateMode = false
    static var notifications: [String] = []
    static func showNotification(title: String, message: String) { notifications.append(message) }
}
