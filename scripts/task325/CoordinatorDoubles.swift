import Cocoa

// No real UI, microphone, HTTP, clipboard, Keychain, input events or user configuration.
struct FixtureApplication { let bundleIdentifier: String?; let processIdentifier: pid_t }
final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: FixtureApplication? = FixtureApplication(bundleIdentifier: "fixture-app-a", processIdentifier: 42)
}
final class NSSound { init?(named: String) {} ; func play() {} }
final class NSEvent {
    struct EventTypeMask { static let keyDown = EventTypeMask() }
    var own = false
    static var global: ((NSEvent) -> Void)?
    static var local: ((NSEvent) -> NSEvent?)?
    static func addGlobalMonitorForEvents(matching: EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? { global = handler; return "global" }
    static func addLocalMonitorForEvents(matching: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? { local = handler; return "local" }
    static func removeMonitor(_ monitor: Any) {
        if monitor as? String == "global" { global = nil } else { local = nil }
    }
    static func key(own: Bool) { let event = NSEvent(); event.own = own; global?(event); _ = local?(event) }
}
final class LogService {
    static let shared = LogService()
    static var messages: [String] = []
    func debug(_ s: String) { Self.messages.append(s) }
}
final class ConfigService {
    static let shared = ConfigService()
    var configExists = true
    var editWindowEnabled = true
    var editWindowDuration: TimeInterval = 3
}
final class AudioService {
    static let shared = AudioService()
    var onAudioLevel: ((Float) -> Void)?
    var hasAudio = true
    var peakPower: Float = -10
    func startRecording() {}
    func stopRecording() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vox-edit-test-\(UUID().uuidString).wav")
        try! Data(repeating: 0, count: 20000).write(to: url)
        return url
    }
}
final class STTService { static let shared = STTService(); func transcribe(audioFile: URL) async -> String { "fixture input" } }
final class LLMService {
    static let shared = LLMService()
    static let editPrompt = "fixture prompt"
    var isConfigured = true
    func process(rawText: String, contextHint: String? = nil, customSystemPrompt: String? = nil,
                 translateMode: Bool = false, requireLLM: Bool = false, applyAliases: Bool = false) async -> String { "fixture output" }
}
final class PasteService {
    static let shared = PasteService()
    static var pending: ((Bool) -> Void)?
    static var texts: [String] = []
    func paste(text: String, beforePaste: (() -> Bool)? = nil, completion: ((Bool) -> Void)? = nil) {
        Self.texts.append(text); Self.pending = completion
    }
    static func isOwnPasteEvent(_ event: NSEvent) -> Bool { event.own }
    static func complete(_ ok: Bool) { let callback = pending; pending = nil; callback?(ok) }
}
final class ContextService {
    static let shared = ContextService()
    func detect() -> String { "fixture" }
    func contextHint(for: String) -> String? { nil }
}
final class HistoryService {
    static let shared = HistoryService()
    static var records = 0
    func addRecord(text: String, originalText: String? = nil, isTranslation: Bool = false) { Self.records += 1 }
}
final class StatusOverlay {
    static var windows = 0
    static var successes: [String] = []
    static var hidden = 0
    func show(phase: VoxPhase) {}
    func hide() { Self.hidden += 1 }
    func updateAudioLevel(_ level: Float) {}
    func showEditWindow(duration: TimeInterval) { Self.windows += 1 }
    func showEditRecording() {}
    func showEditProcessing() {}
    func showSuccess(_ text: String, autoDismissAfter: TimeInterval = 0.8) { Self.successes.append(text) }
}
final class AppDelegate {
    static let shared = AppDelegate()
    var translateMode = false
    static func showNotification(title: String, message: String) {}
}
