import Foundation

struct SpaceConfig: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, webdav }
    let id: String                 // spaceID; also the local directory name
    var name: String
    var kind: Kind
    var webdavURL: String?
    var webdavUser: String?

}

/// Persists the list of Spaces (config only — secrets stay in Keychain).
enum SpaceStore {
    /// Spaces are per-account (synced via iCloud Keychain), so each local
    /// user keeps their own list and switching users never mixes them.
    static func load(account id: String) -> [SpaceConfig] {
        guard let data = Keychain.get(AccountStore.spacesAccount(id)),
              let list = try? JSONDecoder().decode([SpaceConfig].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SpaceConfig], account id: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        Keychain.set(data, account: AccountStore.spacesAccount(id), sync: true)
    }

    /// Root directory for a local-backed Space inside the app container.
    static func localRoot(for id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("FlarkSpaces/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Local-only projection cache for a Space (never synced to the backend).
    static func snapshotURL(for id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlarkSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).json")
    }
}
