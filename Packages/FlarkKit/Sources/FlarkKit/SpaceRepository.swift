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
