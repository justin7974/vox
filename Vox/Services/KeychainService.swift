import Foundation
import Security

/// Minimal wrapper around the macOS Keychain for storing API keys.
/// All keys live under a single service name so they're grouped in Keychain Access.
enum KeychainService {
    private static let service = "com.justin.vox"

    /// Fetch a stored secret; returns nil if missing.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Store or overwrite a secret. Pass an empty string to delete.
    @discardableResult
    static func set(account: String, value: String) -> Bool {
        if value.isEmpty {
            return delete(account: account)
        }
        let data = Data(value.utf8)

        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try update first; fall back to add.
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }

        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
