import Foundation
import CryptoKit

/// Reads/writes the on-storage layout of a Space:
///
///   flark.json                              space manifest
///   profiles/<authorID>.json                one file per author (owner-only)
///   events/<authorID>/<hlc>-<eventID>.json  append-only, per-author dir
///   blobs/<sha256>                          content-addressed, immutable
///
/// Per-author event subdirectories mean two devices never write the same
/// file, so WebDAV needs no locking for the common path.
public actor SpaceRepository {
    private let backend: StorageBackend
    private let identity: DeviceIdentity
    public let spaceID: String

    public init(backend: StorageBackend, identity: DeviceIdentity, spaceID: String) {
        self.backend = backend
        self.identity = identity
        self.spaceID = spaceID
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()
    private static let decoder = JSONDecoder()

    /// Everything for a Space lives under its own id, so a single WebDAV
    /// directory can host multiple Spaces without collisions.
    private func P(_ path: String) -> String { "\(spaceID)/\(path)" }

    // MARK: - Bootstrap

    public func bootstrap(spaceName: String) async throws {
        for dir in [spaceID, P("events"), P("profiles"), P("blobs"),
                    P("events/\(identity.authorID)")] {
            try? await backend.makeDirectory(dir)
        }
        if !(try await backend.exists(P("flark.json"))) {
            let manifest = ["schemaVersion": "1", "spaceID": spaceID, "name": spaceName]
            let data = try Self.encoder.encode(manifest)
            try? await backend.put(P("flark.json"), data: data, precondition: .createOnly)
        }
    }

    // MARK: - Blobs (content addressed, immutable)

    public func putBlob(_ data: Data) async throws -> String {
        let id = base32(Data(SHA256.hash(data: data)))
        let path = P("blobs/\(id)")
        if try await backend.exists(path) { return id }
        // createOnly: identical content → identical name → never a conflict.
        do { try await backend.put(path, data: data, precondition: .createOnly) }
        catch StorageError.preconditionFailed { /* someone uploaded it first */ }
        return id
    }

    public func getBlob(_ id: String) async throws -> Data {
        try await backend.get(P("blobs/\(id)")).data
    }

    // MARK: - Events

    /// Appends the signed event and returns its storage path (so the sync
    /// engine can mark it known and not re-download its own writes).
    @discardableResult
    public func append(_ event: Event) async throws -> String {
        var e = event
        try e.sign(with: identity)
        let path = P("events/\(identity.authorID)/\(e.hlc.description)-\(e.eventID).json")
        let data = try Self.encoder.encode(e)
        try await backend.put(path, data: data, precondition: .createOnly)
        return path
    }

    /// All event file paths in the Space (across every author dir).
    public func listEventPaths() async throws -> [String] {
        var paths: [String] = []
        for authorDir in try await backend.list(P("events")) where authorDir.isDirectory {
            for f in try await backend.list(authorDir.path)
            where !f.isDirectory && f.path.hasSuffix(".json") {
                paths.append(f.path)
            }
        }
        return paths
    }

    public func loadEvent(at path: String) async throws -> Event {
        let (data, _) = try await backend.get(path)
        return try Self.decoder.decode(Event.self, from: data)
    }

    // MARK: - Segments (sealed history)

    /// Events per immutable segment file. Fewer than a full batch of own
    /// singles stay loose; once a batch accumulates it is sealed. Smaller =
    /// fewer loose files (the cold-start PROPFIND cost) at the price of more
    /// segment files. 100 keeps the loose pile small while ~10k events still
    /// fold from ~100 segments rather than 10k singles.
    public static let segmentBatchSize = 100
    /// Never seal the most-recent N of an author's own singles. 0: seal as
    /// soon as a full batch exists — loose count stays below a batch. (Late
    /// lower-HLC events still arrive as new singles and fold fine; the reducer
    /// is order-independent, so a recent-tail buffer isn't needed.)
    public static let segmentTailKeep = 0

    private static func basename(_ p: String) -> String {
        (p as NSString).lastPathComponent
    }

    /// A `seg-…json` file holds an array of already-signed events; a plain
    /// `<hlc>-<id>.json` holds one. The basename prefix is the discriminator.
    public static func isSegment(_ path: String) -> Bool {
        basename(path).hasPrefix("seg-")
    }

    /// Decode one storage path into events: a segment yields many, a single
    /// event file yields one. Lets the sync engine treat both uniformly.
    public func loadEvents(at path: String) async throws -> [Event] {
        let (data, _) = try await backend.get(path)
        if Self.isSegment(path) {
            return try Self.decoder.decode([Event].self, from: data)
        }
        return [try Self.decoder.decode(Event.self, from: data)]
    }

    /// Pack this device's own oldest unsealed single events into one immutable
    /// segment, then delete the now-redundant singles. The directory stays
    /// small so cold-start PROPFIND never explodes.
    ///
    /// Lock-free & convergent: the batch is the deterministic oldest `batch`
    /// of this author's own singles (excluding a fixed recent tail), so two
    /// devices of the same identity produce byte-identical segments —
    /// `createOnly` lets the loser no-op. Singles are deleted only **after**
    /// the segment is confirmed durably readable and covering the batch, so a
    /// crash anywhere is safe (re-run is idempotent; the reducer dedupes by
    /// eventID, tolerating a reader seeing both the segment and the singles).
    /// Returns the number of events sealed (0 = nothing to do this round).
    @discardableResult
    public func sealOwnHistory(batch: Int = segmentBatchSize,
                               tailKeep: Int = segmentTailKeep) async throws -> Int {
        let dir = P("events/\(identity.authorID)")
        let entries = (try? await backend.list(dir)) ?? []
        let singles = entries
            .filter { !$0.isDirectory && $0.path.hasSuffix(".json")
                      && !Self.isSegment($0.path) }
            .map(\.path)
            .sorted { Self.basename($0) < Self.basename($1) }   // HLC asc
        guard singles.count > tailKeep + batch else { return 0 }
        let chosen = Array(singles.dropLast(tailKeep).prefix(batch))

        var events: [Event] = []
        for p in chosen {
            if let e = try? await loadEvents(at: p).first { events.append(e) }
        }
        guard events.count == chosen.count else { return 0 }  // partial view
        events.sort(by: Event.order)
        guard let lo = events.first?.hlc, let hi = events.last?.hlc else { return 0 }

        let segPath = P("events/\(identity.authorID)/seg-\(lo)-\(hi).json")
        let data = try Self.encoder.encode(events)
        do {
            try await backend.put(segPath, data: data, precondition: .createOnly)
        } catch StorageError.preconditionFailed {
            // Another device already sealed this exact range — fall through
            // and still prune the singles it left behind.
        }
        // Confirm-before-delete: the segment must be readable AND cover every
        // event in the batch before any single is removed.
        let sealed = Set((try await loadEvents(at: segPath)).map(\.eventID))
        guard Set(events.map(\.eventID)).isSubset(of: sealed) else { return 0 }
        for p in chosen { try? await backend.delete(p) }
        return events.count
    }

    // MARK: - Profile

    public func writeProfile(displayName: String, avatarBlobID: String?) async throws {
        let profile = ProfileFile(displayName: displayName,
                                  avatarBlobID: avatarBlobID,
                                  publicKey: identity.publicKeyData.base64EncodedString(),
                                  updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        let data = try Self.encoder.encode(profile)
        // Author owns its own profile file → plain overwrite is safe.
        try await backend.put(P("profiles/\(identity.authorID).json"), data: data)
    }

    public func loadProfiles() async throws -> [String: ProfileFile] {
        var out: [String: ProfileFile] = [:]
        for f in try await backend.list(P("profiles"))
        where !f.isDirectory && f.path.hasSuffix(".json") {
            let id = (f.path as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
            if let (data, _) = try? await backend.get(f.path),
               let p = try? Self.decoder.decode(ProfileFile.self, from: data) {
                out[id] = p
            }
        }
        return out
    }
}

public struct ProfileFile: Codable, Sendable {
    public var displayName: String
    public var avatarBlobID: String?
    public var publicKey: String   // base64 raw Ed25519
    public var updatedAt: Int64 = 0
}
