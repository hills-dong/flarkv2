import Foundation

struct SpaceConfig: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, webdav }
    /// Logical space identity, shared across devices that joined this space —
    /// also the directory name on the WebDAV backend. Two members necessarily
    /// share the same `id`; on a single device it is *not* unique, since the
    /// same spaceID may be bound to two different WebDAVs.
    let id: String
    /// Per-binding install identity. Unique on this device; keys every local
    /// store (outbox, snapshot cache, blob & thumb caches, local-backend root,
    /// WebDAV password) so that binding the same spaceID to a second WebDAV
    /// doesn't collide with the existing binding.
    let localID: String
    var name: String
    var kind: Kind
    var webdavURL: String?
    var webdavUser: String?

    init(id: String, localID: String = UUID().uuidString, name: String, kind: Kind,
         webdavURL: String? = nil, webdavUser: String? = nil) {
        self.id = id
        self.localID = localID
        self.name = name
        self.kind = kind
        self.webdavURL = webdavURL
        self.webdavUser = webdavUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.id = id
        // Legacy configs (pre-localID) inherit `id` so existing on-disk stores
        // (FlarkOutbox/<id>, FlarkSnapshots/<id>.json, ...) keep being found.
        // New joins get a fresh localID via the memberwise init above.
        self.localID = (try? c.decode(String.self, forKey: .localID)) ?? id
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.webdavURL = try? c.decode(String.self, forKey: .webdavURL)
        self.webdavUser = try? c.decode(String.self, forKey: .webdavUser)
    }
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

    // All path helpers below take a Space's per-install `localID` (not its
    // shared spaceID), so binding the same spaceID to a second WebDAV gets a
    // disjoint set of on-disk stores instead of silently sharing them.

    /// Root directory for a local-backed Space inside the app container.
    static func localRoot(for localID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("FlarkSpaces/\(localID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Local "outbox" mirror of this device's own active event files. The
    /// repository writes events here first (durable, fast) and then PUTs them
    /// to the WebDAV backend; on crash, the outbox is the source of truth for
    /// re-uploading. Never synced (it's strictly a per-install staging area).
    static func outboxRoot(for localID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("FlarkOutbox/\(localID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Local-only projection cache for a Space (never synced to the backend).
    static func snapshotURL(for localID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlarkSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(localID).json")
    }

    /// Purgeable on-disk cache of a Space's immutable image blobs. Lives in
    /// Caches (the OS may evict it under storage pressure; misses just
    /// re-download), and is never synced to the backend.
    static func blobCacheRoot(for localID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlarkBlobs/\(localID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Purgeable cache of downscaled list thumbnails (one entry per blob ×
    /// target size). Derived from blobs, so it is safe to evict and rebuild;
    /// kept separate from `blobCacheRoot` so wiping one never touches the
    /// other. Applies to every Space kind (local blobs still cost a full
    /// 2048px decode per render without it).
    static func thumbCacheRoot(for localID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlarkThumbs/\(localID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
