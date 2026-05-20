import Foundation

/// A local, per-device cache of a fully-folded `Projection`.
///
/// Strictly a cache: it is **never** written to the shared/WebDAV Space (the
/// signed event log is the only trust boundary) and can always be discarded
/// and rebuilt from events. `pathEtags` records the server etag last folded
/// for each event-file path so the next sync can skip unchanged files via
/// conditional GET; `maxHLC` reseeds the clock so it never regresses.
public struct ProjectionSnapshot: Codable, Sendable {
    /// Bumped on any change to the snapshot envelope shape.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var reducerFingerprint: String
    /// path → etag of the file content currently folded into `projection`.
    /// On the next sync round, listEventEntries' etags are diffed against
    /// this map; matches mean "still up-to-date, skip the GET", mismatches
    /// (or new paths) mean "fetch and fold". A path missing from the latest
    /// listing is purged from the map (file removed remotely).
    public var pathEtags: [String: String]
    /// Same idea as `pathEtags`, but for profile files. The PROPFIND on the
    /// profiles dir already returns an etag per file, so matching entries can
    /// be skipped entirely — no GET — instead of unconditionally re-fetching
    /// every author's profile on every sync round.
    public var profileEtags: [String: String]
    public var maxHLC: HLC?
    public var projection: Projection

    public init(pathEtags: [String: String],
                profileEtags: [String: String],
                maxHLC: HLC?, projection: Projection) {
        self.schemaVersion = Self.currentSchemaVersion
        self.reducerFingerprint = MergeReducer.reducerFingerprint
        self.pathEtags = pathEtags
        self.profileEtags = profileEtags
        self.maxHLC = maxHLC
        self.projection = projection
    }

    /// Valid only if it matches the current envelope + reducer semantics.
    /// Any mismatch → caller discards it and rebuilds from the event log.
    public var isCompatible: Bool {
        schemaVersion == Self.currentSchemaVersion
            && reducerFingerprint == MergeReducer.reducerFingerprint
    }
}

/// File-backed snapshot persistence. The URL is injected by the app layer so
/// FlarkKit stays free of app-specific paths; it must point inside the local
/// app container, never the Space backend.
public struct SnapshotStore: Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> ProjectionSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(ProjectionSnapshot.self, from: data),
              snap.isCompatible else { return nil }   // corrupt/incompatible → absent
        return snap
    }

    public func save(_ snapshot: ProjectionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
