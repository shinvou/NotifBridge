import Foundation
import Security

/// Thin Codable wrapper around `SecItem*` for the Mac app.
///
/// Service is the fixed app bundle id so `security` CLI / Keychain Access can
/// inspect entries. Items are scoped to the user's login keychain and accessible
/// after first-unlock (matches typical background-app needs — Mac receiver runs
/// as menu-bar item that may be launched at login).
enum KeychainStore {
    private static let service = "com.shinvou.NotifBridge.Mac"

    static func save<T: Codable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let base: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.osStatus(updated) }
        var add = base
        add[kSecValueData as String]      = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.osStatus(status) }
    }

    static func load<T: Codable>(_ type: T.Type, account: String) -> T? {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    enum Failure: Error { case osStatus(OSStatus) }
}
