import Foundation
import Security

/// Wraps a single Keychain generic-password item that holds the OpenAI API key.
/// The key is **never** stored in `UserDefaults` — only here (doc 10). `set(nil)`
/// deletes the item; reads tolerate a missing item by returning `nil`.
/// Note: declared non-`final` (a small deviation from the contract's `final
/// class`) purely so tests can inject an in-memory subclass and avoid touching
/// the system Keychain, which may be unavailable in CI.
class KeychainStore {
    private let service = "com.foretype.openai-api-key"
    private let account = "default"

    init() {}

    /// Read the stored API key, or `nil` if none is present (or on any error).
    func read() -> String? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Store the API key, replacing any existing one. Passing `nil` (or empty)
    /// deletes the item entirely so absence means "send no Authorization header."
    func set(_ value: String?) {
        guard let value, !value.isEmpty else {
            delete()
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery()

        // Update if present; otherwise add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    // MARK: - Private

    private func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
