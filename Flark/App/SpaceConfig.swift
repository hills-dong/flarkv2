import Foundation

struct SpaceConfig: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, webdav }
    let id: String                 // spaceID; also the local directory name
    var name: String
    var kind: Kind
    var webdavURL: String?
    var webdavUser: String?

    var passwordAccount: String { "space.\(id).password" }
}

/// Persists the list of Spaces (config only — secrets stay in Keychain).
enum SpaceStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("flark-spaces.json")
    }

    static func load() -> [SpaceConfig] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([SpaceConfig].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SpaceConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Root directory for a local-backed Space inside the app container.
    static func localRoot(for id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("FlarkSpaces/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
