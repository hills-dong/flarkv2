import Foundation
import Security

/// Tiny secret-store wrapper. Holds the Ed25519 device private key and
/// per-Space WebDAV credentials — never written to disk in the clear (on iOS).
///
/// On **iOS** this is the system Keychain. `sync: true` marks the item
/// `kSecAttrSynchronizable`, so iCloud Keychain replicates it to the user's
/// other devices automatically (no iCloud entitlement needed) — this is how
/// "log in on another device" works (A).
///
/// On **macOS** the legacy file-based login keychain triggers an ACL
/// "<App> wants to access X — enter your password" dialog on every read
/// whenever the app's code signature changes (which it does on every ad-hoc
/// rebuild, and we can't get a Team ID for a personal-use Mac build). The
/// data-protection keychain isn't writable for an ad-hoc-signed app either.
/// So on macOS we keep secrets in a per-user file under Application Support
/// instead — same on-disk security as the rest of the app's local data
/// (`FlarkSpaces/`), and zero password prompts.
enum Keychain {
    #if os(macOS)
    @discardableResult
    static func set(_ data: Data, account: String, sync: Bool = false) -> Bool {
        FileStore.set(data, account: account)
    }
    static func get(_ account: String) -> Data? { FileStore.get(account) }
    @discardableResult
    static func delete(_ account: String) -> Bool { FileStore.delete(account) }
    #else
    private static let service = "app.flark.client"

    @discardableResult
    static func set(_ data: Data, account: String, sync: Bool = false) -> Bool {
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
    #endif

    static func setString(_ s: String, account: String, sync: Bool = false) {
        set(Data(s.utf8), account: account, sync: sync)
    }
    static func getString(_ account: String) -> String? {
        get(account).flatMap { String(data: $0, encoding: .utf8) }
    }
}

#if os(macOS)
/// JSON file under Application Support storing all `Keychain` entries for
/// this Mac user. Concurrent access from the main app is fine (every call
/// loads, mutates and writes atomically); we don't share this file with
/// other processes.
private enum FileStore {
    private static let lock = NSLock()

    private static var url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Flark", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("secrets.json")
    }()

    private static func load() -> [String: Data] {
        guard let raw = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Data].self, from: raw)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Data]) -> Bool {
        guard let encoded = try? JSONEncoder().encode(dict) else { return false }
        do {
            try encoded.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d = load(); d[account] = data; return save(d)
    }
    static func get(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[account]
    }
    @discardableResult
    static func delete(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d = load()
        guard d.removeValue(forKey: account) != nil else { return false }
        return save(d)
    }
}
#endif
