import Foundation
import Security

// Thin wrapper around the macOS Keychain for storing per-provider API keys.
// We use kSecClassGenericPassword with a fixed service prefix and a per-
// provider account name. Reads return nil when the item doesn't exist;
// writes upsert.
enum Keychain {
    private static let service = "com.disklens.app.aikeys"

    static func save(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: "Keychain", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot encode value"])
        }
        // Try to update an existing item first; insert if it doesn't exist.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let msg = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
        return NSError(domain: "Keychain", code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
