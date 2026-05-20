import Foundation
import CryptoKit

/// Reads/writes the on-storage layout of a Space:
///
///   flark.json                                           space manifest
///   profiles/<authorID>.json                             one file per author
///   events/<authorID>/<deviceID>/<paddedSeq>.json        active + rotated logs
///   blobs/<sha256>                                       content-addressed
///
/// Each device writes only under its own `<authorID>/<deviceID>/` subtree, so
/// even when the same identity is shared across devices via iCloud Keychain,
/// no two devices ever touch the same file — the actor is the single writer.
/// The active file is a JSON array of signed events that grows in place with
/// every `append`; once it reaches `rotationEventCount` or `rotationByteSize`
/// the actor moves to the next seq, so old files become immutable "segments"
/// automatically (no separate sealing pass).
public actor SpaceRepository {
    private let backend: StorageBackend
    private let identity: DeviceIdentity
    public let spaceID: String
    public let deviceID: String
    /// Local-disk mirror of this device's own active file. Surviving an app
    /// crash mid-PUT, and accurately resuming the seq counter on next launch.
    private let outboxRoot: URL
    /// Read/write-through local cache for immutable blobs. nil ⇒ no caching
    /// (e.g. a local-file backend, where the blob is already on disk).
    private let blobCache: BlobCache?

    public init(backend: StorageBackend, identity: DeviceIdentity,
                spaceID: String, deviceID: String, outboxRoot: URL,
                rotationEventCount: Int = SpaceRepository.rotationEventCount,
                rotationByteSize: Int = SpaceRepository.rotationByteSize,
                blobCache: BlobCache? = nil) {
        self.backend = backend
        self.identity = identity
        self.spaceID = spaceID
        self.deviceID = deviceID
        self.outboxRoot = outboxRoot
        self.rotationEventCountActive = rotationEventCount
        self.rotationByteSizeActive = rotationByteSize
        self.blobCache = blobCache
    }

    /// Effective caps for THIS repository instance — tests pass small values
    /// to force rotation in a handful of events; production uses the static
    /// defaults via the parameter's default arg.
    private let rotationEventCountActive: Int
    private let rotationByteSizeActive: Int

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()
    private static let decoder = JSONDecoder()

    /// Everything for a Space lives under its own id, so a single WebDAV
    /// directory can host multiple Spaces without collisions.
    private func P(_ path: String) -> String { "\(spaceID)/\(path)" }

    // MARK: - Active file rotation

    /// Hard cap on the number of events any single file holds. Once reached,
    /// the active file freezes and the next event starts the next seq.
    public static let rotationEventCount = 1000
    /// Soft cap on encoded size. Keeps an outlier-heavy file (e.g. lots of
    /// inline content) from ballooning past what readers can practically
    /// re-download under conditional-GET misses.
    public static let rotationByteSize = 256 * 1024

    /// 8-digit zero-padded so directory listings sort by seq.
    private static func seqName(_ s: Int) -> String { String(format: "%08d", s) }

    private func deviceOutboxDir() -> URL {
        outboxRoot
            .appendingPathComponent(identity.authorID)
            .appendingPathComponent(deviceID)
    }

    private func activeFileURL(seq: Int) -> URL {
        deviceOutboxDir().appendingPathComponent("\(Self.seqName(seq)).json")
    }

    private func remotePath(seq: Int) -> String {
        P("events/\(identity.authorID)/\(deviceID)/\(Self.seqName(seq)).json")
    }

    /// In-memory tail of the active file. Loaded lazily from disk on the
    /// first write so the engine doesn't pay a cold-start I/O hit just to
    /// open a Space.
    private var activeSeq: Int = 0
    private var activeEvents: [Event] = []
    private var loaded: Bool = false

    /// Read the outbox to discover the highest seq written previously (or 1
    /// for a brand-new device). If that file's encoded form is already at
    /// capacity, advance to a fresh seq — the next `append` starts clean.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let dir = deviceOutboxDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let seqs = files
            .filter { $0.hasSuffix(".json") }
            .compactMap { Int(($0 as NSString).deletingPathExtension) }
            .sorted()
        guard let last = seqs.last else {
            activeSeq = 1
            activeEvents = []
            return
        }
        activeSeq = last
        if let data = try? Data(contentsOf: activeFileURL(seq: last)),
           let events = try? Self.decoder.decode([Event].self, from: data) {
            activeEvents = events
            // Past capacity? Open the next seq before the first append so the
            // already-full file stays untouched as an immutable segment.
            if events.count >= rotationEventCountActive || data.count >= rotationByteSizeActive {
                activeSeq = last + 1
                activeEvents = []
            }
        } else {
            activeEvents = []
        }
    }

    // MARK: - Bootstrap

    public func bootstrap(spaceName: String) async throws {
        for dir in [spaceID, P("events"), P("profiles"), P("blobs"),
                    P("events/\(identity.authorID)"),
                    P("events/\(identity.authorID)/\(deviceID)")] {
            try? await backend.makeDirectory(dir)
        }
        if !(try await backend.exists(P("flark.json"))) {
            let manifest = ["schemaVersion": "1", "spaceID": spaceID, "name": spaceName]
            let data = try Self.encoder.encode(manifest)
            try? await backend.put(P("flark.json"), data: data, precondition: .createOnly)
        }
        FlarkLog.shared.record(.info, .repo, "bootstrap",
                               path: spaceID, detail: "device \(deviceID.prefix(8))")
        // Recover from a mid-flight crash: if the outbox holds events the
        // backend never received (last PUT failed and the app died before a
        // retry), push them now. Idempotent — re-PUTting the identical body
        // costs one request but no correctness damage.
        ensureLoaded()
        if !activeEvents.isEmpty {
            FlarkLog.shared.record(.info, .repo, "recover",
                                   path: remotePath(seq: activeSeq),
                                   detail: "\(activeEvents.count) events from outbox")
            try? await pushActiveToBackend()
        }
    }

    // MARK: - Blobs (content addressed, immutable)

    public func putBlob(_ data: Data) async throws -> String {
        let id = base32(Data(SHA256.hash(data: data)))
        // Own uploads should render instantly and survive offline, even
        // before the backend round-trip — cache the bytes up front.
        blobCache?.store(data, for: id)
        let path = P("blobs/\(id)")
        if try await backend.exists(path) {
            FlarkLog.shared.record(.info, .repo, "blob.dedupe",
                                   path: path, bytes: data.count)
            return id
        }
        // createOnly: identical content → identical name → never a conflict.
        do {
            try await backend.put(path, data: data, precondition: .createOnly)
            FlarkLog.shared.record(.info, .repo, "blob.put",
                                   path: path, bytes: data.count)
        } catch StorageError.preconditionFailed {
            FlarkLog.shared.record(.info, .repo, "blob.dedupe",
                                   path: path, detail: "race-loser",
                                   bytes: data.count)
        }
        return id
    }

    public func getBlob(_ id: String) async throws -> Data {
        if let cached = blobCache?.data(for: id) { return cached }
        let data = try await backend.get(P("blobs/\(id)")).data
        blobCache?.store(data, for: id)   // content-addressed ⇒ never stale
        return data
    }

    // MARK: - Events

    /// Append one signed event. See `appendBatch` — this is the trivial
    /// single-event case.
    @discardableResult
    public func append(_ event: Event) async throws -> String {
        try await appendBatch([event])
    }

    /// Append several signed events in one PUT. Folds the engine's debounced
    /// flush window of N submits down to a single backend round-trip — the
    /// main lever for staying under 坚果云's request-count throttle.
    ///
    /// The actor's serialization is the "single writer" guarantee — no two
    /// callers ever race on the same file. Rotation that falls in the middle
    /// of a batch is handled by sealing the now-full file (one PUT for that
    /// terminal state) and continuing the rest of the batch into the next
    /// seq. If a PUT fails (network blip, throttling), the next append
    /// re-PUTs a superset of events, so a failed upload self-heals as soon
    /// as another event arrives or `flushActive` runs.
    @discardableResult
    public func appendBatch(_ events: [Event]) async throws -> String {
        ensureLoaded()
        guard !events.isEmpty else { return remotePath(seq: activeSeq) }
        var lastPath = remotePath(seq: activeSeq)
        for ev in events {
            // The file's CAP is `rotationEventCount` events; if we're at it,
            // PUT the now-full file as the FINAL state of this seq, then
            // open the next seq with this event as #1.
            if activeEvents.count >= rotationEventCountActive {
                try await persistActiveLocally()
                try await pushActiveToBackend()
                FlarkLog.shared.record(.info, .repo, "rotate",
                                       path: remotePath(seq: activeSeq),
                                       detail: "event cap → seq \(activeSeq + 1)")
                activeSeq += 1
                activeEvents = []
            }
            var e = ev
            try e.sign(with: identity)
            activeEvents.append(e)
        }
        try await persistActiveLocally()
        try await pushActiveToBackend()
        lastPath = remotePath(seq: activeSeq)
        FlarkLog.shared.record(.info, .repo, "append",
                               path: lastPath,
                               detail: "+\(events.count) events · \(activeEvents.count) in file",
                               bytes: lastEncodedSize)
        // Byte cap is checked AFTER persisting — the current file is fine at
        // this size; the cap rotates the NEXT append, which would otherwise
        // push it past the limit.
        if let data = lastEncodedSize, data >= rotationByteSizeActive {
            FlarkLog.shared.record(.info, .repo, "rotate",
                                   path: lastPath,
                                   detail: "byte cap → seq \(activeSeq + 1)")
            activeSeq += 1
            activeEvents = []
            lastEncodedSize = 0
        }
        return lastPath
    }

    /// PUT the current active file to the backend in its entirety. Used by
    /// the engine to drain a debounced flush window when no new events are
    /// arriving — and on bootstrap to recover from a mid-flight crash where
    /// the outbox has events the backend hasn't seen yet.
    public func flushActive() async throws {
        ensureLoaded()
        guard !activeEvents.isEmpty else { return }
        try await pushActiveToBackend()
    }

    /// Most recent encoded body size; cached so byte-cap rotation doesn't
    /// re-encode the array just to measure it.
    private var lastEncodedSize: Int? = nil

    private func persistActiveLocally() async throws {
        let data = try Self.encoder.encode(activeEvents)
        lastEncodedSize = data.count
        let local = activeFileURL(seq: activeSeq)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: local, options: .atomic)
    }

    private func pushActiveToBackend() async throws {
        let data = try Self.encoder.encode(activeEvents)
        lastEncodedSize = data.count
        try await backend.put(remotePath(seq: activeSeq), data: data, precondition: .none)
    }

    /// All event-file entries in the Space (every author × every deviceID).
    /// Returns the listing's etags so the engine can skip unchanged files via
    /// conditional GET. PROPFIND already carries etags, so this is one round
    /// trip per dir level — no extra HEADs.
    public func listEventEntries() async throws -> [StorageEntry] {
        var out: [StorageEntry] = []
        for authorDir in try await backend.list(P("events")) where authorDir.isDirectory {
            for deviceDir in try await backend.list(authorDir.path) where deviceDir.isDirectory {
                for f in try await backend.list(deviceDir.path)
                where !f.isDirectory && f.path.hasSuffix(".json") {
                    out.append(f)
                }
            }
        }
        return out
    }

    /// Decode a stored file into its events. Every event file is now a JSON
    /// array (active or sealed), so callers don't have to discriminate.
    public func loadEvents(at path: String) async throws -> [Event] {
        let (data, _) = try await backend.get(path)
        return try Self.decoder.decode([Event].self, from: data)
    }

    /// Conditional version: returns `nil` when the server reports the file
    /// is unchanged vs `knownEtag` (HTTP 304), saving the body download AND
    /// the redundant fold. The engine still records the etag — same one — to
    /// keep tracking the file.
    public func loadEventsIfChanged(at path: String, knownEtag: String?) async throws -> (events: [Event], etag: String?)? {
        guard let (data, etag) = try await backend.get(path, ifNoneMatch: knownEtag) else { return nil }
        let events = try Self.decoder.decode([Event].self, from: data)
        return (events, etag)
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

    /// PROPFIND-driven, etag-aware profile fetch. Profiles can change with no
    /// accompanying event (rename, avatar swap) so the engine still needs to
    /// poll them — but on an unchanged Space the etag comparison below skips
    /// every per-file GET, taking idle refreshes from 1+N requests to just 1.
    ///
    /// Returns:
    ///   - `changed`: profiles whose etag differs from `knownEtags` (apply &
    ///     overwrite locally).
    ///   - `etags`: the fresh listing's path → etag map. The caller persists
    ///     this so the next round can diff against it; paths that disappeared
    ///     remotely are simply absent.
    public func loadProfiles(knownEtags: [String: String] = [:]) async throws
        -> (changed: [String: ProfileFile], etags: [String: String]) {
        var changed: [String: ProfileFile] = [:]
        var etags: [String: String] = [:]
        for f in try await backend.list(P("profiles"))
        where !f.isDirectory && f.path.hasSuffix(".json") {
            let id = (f.path as NSString).lastPathComponent
                .replacingOccurrences(of: ".json", with: "")
            // Etag matches what we already folded → skip the GET entirely.
            if let listing = f.etag, listing == knownEtags[f.path] {
                etags[f.path] = listing
                continue
            }
            guard let (data, etag) = try? await backend.get(f.path),
                  let p = try? Self.decoder.decode(ProfileFile.self, from: data)
            else { continue }
            changed[id] = p
            etags[f.path] = etag ?? f.etag ?? ""
        }
        return (changed, etags)
    }
}

public struct ProfileFile: Codable, Sendable {
    public var displayName: String
    public var avatarBlobID: String?
    public var publicKey: String   // base64 raw Ed25519
    public var updatedAt: Int64 = 0
}
