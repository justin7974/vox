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
    struct Backup { let url: URL }
    static var starts = 0
    static var backups: [Backup] = []
    var lastBackupURL: URL? { Self.backups.first?.url }
    func getBackups() -> [Backup] { Self.backups }
    func startRecording() { Self.starts += 1 }
    func stopRecording() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vox-325-flow-\(UUID().uuidString).wav")
        try! Data(repeating: 0, count: 20000).write(to: url)
        Self.backups.insert(Backup(url: url), at: 0)
        return url
    }
}
final class STTService {
    static let shared = STTService()
    static var output = "fixture raw"
    static var calls = 0
    static var urls: [URL] = []
    func transcribe(audioFile: URL) async -> String { Self.calls += 1; Self.urls.append(audioFile); return Self.output }
}
final class LLMService {
    struct Call { let custom: String?; let translate: Bool; let required: Bool; let aliases: Bool }
    static let shared = LLMService()
    static var calls: [Call] = []
    static var output = "fixture polished"
    var isConfigured = true
    func process(rawText: String, contextHint: String? = nil, customSystemPrompt: String? = nil,
                 translateMode: Bool = false, requireLLM: Bool = false, applyAliases: Bool = false, onFailure: (() -> Void)? = nil) async -> String {
        Self.calls.append(Call(custom: customSystemPrompt, translate: translateMode, required: requireLLM, aliases: applyAliases))
        if Self.output.isEmpty && isConfigured { onFailure?() }
        return Self.output
    }
}
final class PasteService {
    static let shared = PasteService()
    var lastPastedText: String? { Self.texts.last }
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
    func getRecords() -> [Record] { Self.records.reversed() }
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
    static var retries: [(URL?, Bool, Bool)] = []
    static func showRetryNotification(audioURL: URL?, translateMode: Bool, fallbackAlreadyPasted: Bool = false) { retries.append((audioURL, translateMode, fallbackAlreadyPasted)) }
    static func showNotification(title: String, message: String) { notifications.append(message) }
}
