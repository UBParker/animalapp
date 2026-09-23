import Foundation
import Security

/// Generic-password keychain items. The Anthropic API key lives here and nowhere else.
struct KeychainStore {
    static let apiKeyAccount = "anthropic-api-key"

    let service: String

    init(service: String = "AnimalTracker") {
        self.service = service
    }

    enum KeychainError: Error { case status(OSStatus) }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            // Background sync needs the key after the first unlock; never off this device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
