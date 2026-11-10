import Foundation
final class LogService { static let shared = LogService(); func debug(_ s: String) {} }
final class ConfigService {
    struct ProviderConfig { let baseURL: String; let apiKey: String; let model: String; let format: String? }
    static let shared = ConfigService()
    var llmProvider: String? { nil }
    var userContext: String? { nil }
    func llmProviderConfig(for name: String) -> ProviderConfig? { nil }
}
final class DictionaryService { static let shared = DictionaryService(); let formatted = "" }
final class AliasService { static let shared = AliasService(); func apply(_ s: String) -> String { "alias:"+s } }
enum AppDelegate { static func showNotification(title: String, message: String) { fatalError("unexpected UI") } }
