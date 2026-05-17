import Foundation
import Security

/// Tiny Keychain wrapper. Holds the Ed25519 device private key and per-Space
/// WebDAV credentials — never written to disk in the clear.
enum Keychain {
    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.flark.client",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.flark.client",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func setString(_ s: String, account: String) { set(Data(s.utf8), account: account) }
    static func getString(_ account: String) -> String? { get(account).flatMap { String(data: $0, encoding: .utf8) } }
}
