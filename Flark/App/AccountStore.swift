import Foundation

/// One local account = one device identity (Ed25519 key) + its name + its
/// Spaces. The app supports several on one device; logout just switches the
/// active one, it never deletes data.
struct AccountRef: Codable, Identifiable, Hashable {
    let id: String        // == authorID (base32(sha256(pubkey))), stable & unique
    var name: String
}

/// Directory of accounts (synced via iCloud Keychain) + which one is active
/// on THIS device (device-local, so different devices can use different
/// accounts). All per-account secrets are namespaced by account id.
enum AccountStore {
    private static let indexAccount = "flark.accounts.index"
    private static let currentKey = "flark.account.current"   // UserDefaults (device-local)

    // MARK: directory

    static func accounts() -> [AccountRef] {
        guard let d = Keychain.get(indexAccount),
              let list = try? JSONDecoder().decode([AccountRef].self, from: d) else { return [] }
        return list
    }

    static func setAccounts(_ list: [AccountRef]) {
        if let d = try? JSONEncoder().encode(list) {
            Keychain.set(d, account: indexAccount, sync: true)
        }
    }

    static func upsert(id: String, name: String) {
        var list = accounts()
        if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = name }
        else { list.append(AccountRef(id: id, name: name)) }
        setAccounts(list)
    }

    static func remove(id: String) {
        setAccounts(accounts().filter { $0.id != id })
    }

    // MARK: active selection (device-local)

    static var currentID: String? {
        get { UserDefaults.standard.string(forKey: currentKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: currentKey) }
            else { UserDefaults.standard.removeObject(forKey: currentKey) }
        }
    }

    // MARK: per-account keychain accounts

    static func keyAccount(_ id: String) -> String { "flark.acct.\(id).key" }
    static func nameAccount(_ id: String) -> String { "flark.acct.\(id).name" }
    static func spacesAccount(_ id: String) -> String { "flark.acct.\(id).spaces" }
    /// Keyed by the Space's per-install `localID` (not its shared spaceID),
    /// since the password belongs to a specific WebDAV binding — two bindings
    /// of the same spaceID may legitimately use different credentials.
    static func spacePassword(_ id: String, _ localID: String) -> String {
        "flark.acct.\(id).space.\(localID).pw"
    }
}
