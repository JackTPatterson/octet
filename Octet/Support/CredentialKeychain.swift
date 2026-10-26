import Foundation
import Security

/// Where credential profiles keep their secrets: one Keychain item per
/// profile and variable, so a token never sits in settings or on disk.
enum CredentialKeychain {
    private static let service = "Octet Credentials"

    /// Secrets already read this run. Every terminal, agent and command
    /// starts by asking for its profile's variables, and each Keychain read
    /// is a chance for macOS to ask; so it's read once, and again only after
    /// Octet changes it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: String?] = [:]

    static func get(_ account: String) -> String? {
        if let hit = lock.withLock({ known[account] }) { return hit }
        let value = read(account)
        lock.withLock { known[account] = .some(value) }
        return value
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.withLock { known[account] = nil }
        let data = Data(value.utf8)
        if SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = key
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        lock.withLock { known[account] = nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Everything a profile kept.
    static func delete(_ profile: CredentialProfile) {
        for variable in profile.variables {
            delete(CredentialProfiles.keychainAccount(profileId: profile.id, variable: variable.name))
        }
    }
}
