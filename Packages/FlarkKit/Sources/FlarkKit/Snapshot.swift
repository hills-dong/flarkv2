import Foundation

/// A local, per-device cache of a fully-folded `Projection`.
///
/// Strictly a cache: it is **never** written to the shared/WebDAV Space (the
/// signed event log is the only trust boundary) and can always be discarded
/// and rebuilt from events. `knownEventPaths` lets sync skip re-reading files
/// it already folded; `maxHLC` reseeds the clock so it never regresses.
public struct ProjectionSnapshot: Codable, Sendable {
    /// Bumped only when the snapshot envelope shape changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var reducerFingerprint: String
    public var knownEventPaths: [String]
    public var maxHLC: HLC?
    public var projection: Projection

    public init(knownEventPaths: [String], maxHLC: HLC?, projection: Projection) {
        self.schemaVersion = Self.currentSchemaVersion
        self.reducerFingerprint = MergeReducer.reducerFingerprint
        self.knownEventPaths = knownEventPaths
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
