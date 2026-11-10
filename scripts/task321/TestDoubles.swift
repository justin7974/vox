import Foundation
// Never link real LogService/KeychainService into these tests.
final class LogService {
    static let shared = LogService()
    static var messages: [String] = []
    func debug(_ text: String) { Self.messages.append(text) }
}
enum KeychainService {
    static func get(account: String) -> String? { fatalError("Default Keychain access forbidden in tests") }
    static func set(account: String, value: String) -> Bool { fatalError("Default Keychain access forbidden in tests") }
}
enum AppDelegate { static func showNotification(title: String, message: String) {} }
final class DictionaryService { static let shared = DictionaryService(); let formatted = "" }
