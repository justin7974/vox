import Foundation
final class KeychainService {
    static func get(account: String) -> String? { fatalError("Real Keychain forbidden") }
    static func set(account: String, value: String) -> Bool { fatalError("Real Keychain forbidden") }
}
final class STTService { static func resolveBinary(name: String, fallback: String) -> String { fallback } }
final class HistoryService {
    static let shared = HistoryService()
    struct Record { let text: String; let timestamp: Date; var translationMode: Bool { false } }
    func getRecords() -> [Record] { fatalError("Real history forbidden") }
}
final class LLMService {
    static let shared = LLMService()
    func completeWithNamedProvider(_ name: String, userMessage: String, systemPrompt: String) async -> String? { fatalError("Real LLM forbidden") }
}
