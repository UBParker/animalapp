import Foundation
import Security
import Supabase

/// Where the Supabase session lives. The SDK's own `KeychainLocalStorage` takes a service name but
/// no accessibility, and its internal Keychain writes `kSecAttrAccessibleAfterFirstUnlock`
/// (https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/Keychain.swift).
/// This app wants `...ThisDeviceOnly`, which also excludes the item from encrypted backups, so a
/// device backup restored onto a second phone never carries a live session.
struct KeychainSessionStorage: AuthLocalStorage {
    static let defaultService = "com.ashlab.AnimalTracker.auth"

    let service: String

    init(service: String = KeychainSessionStorage.defaultService) {
        self.service = service
    }

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Keychain error \(status)."
            }
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func store(key: String, value: Data) throws {
        // Delete first, then add: SecItemUpdate cannot change kSecAttrAccessible on some OS
        // versions, and a replace has to be certain about the final accessibility.
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// Test seam: reads back the stored item's accessibility class, so the promise this type makes
    /// is checked rather than assumed. Not part of `AuthLocalStorage`.
    func accessibility(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }
}
