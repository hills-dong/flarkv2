import Foundation
import Security

/// Tiny Keychain wrapper. Holds the Ed25519 device private key and per-Space
/// WebDAV credentials — never written to disk in the clear.
///
/// `sync: true` marks the item `kSecAttrSynchronizable`, so iCloud Keychain
/// replicates it to the user's other devices automatically (no iCloud
/// entitlement needed) — this is how "log in on another device" works (A).
enum Keychain {
    private static let service = "app.flark.client"

    @discardableResult
    static func set(_ data: Data, account: String, sync: Bool = false) -> Bool {
        // Clear any existing copy regardless of its sync flag.
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(del as CFDictionary)

        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: sync
        ]
        // Synchronizable items can't use ...ThisDeviceOnly accessibility.
        add[kSecAttrAccessible as String] = sync
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    static func setString(_ s: String, account: String, sync: Bool = false) {
        set(Data(s.utf8), account: account, sync: sync)
    }
    static func getString(_ account: String) -> String? {
        get(account).flatMap { String(data: $0, encoding: .utf8) }
    }
}
