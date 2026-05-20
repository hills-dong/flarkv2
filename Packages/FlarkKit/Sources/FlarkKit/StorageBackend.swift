import Foundation

public struct StorageEntry: Sendable, Equatable {
    public let path: String        // relative to the Space root
    public let isDirectory: Bool
    public let etag: String?
    public init(path: String, isDirectory: Bool, etag: String?) {
        self.path = path; self.isDirectory = isDirectory; self.etag = etag
    }
}

public enum WritePrecondition: Sendable {
    case none
    case createOnly          // If-None-Match: *  — fail if it already exists
    case ifMatch(String)     // optimistic concurrency for the rare mutable file
}

public enum StorageError: Error, Sendable, Equatable {
    case notFound
    case preconditionFailed   // 412 / already exists — caller should reconcile
    case unauthorized
    case transport(String)
    case server(Int)
}

/// The only thing the sync engine knows about persistence. Local folder,
/// WebDAV, or a future self-hosted server all implement this — transparently.
public protocol StorageBackend: Sendable {
    /// Children of a directory (one level). Empty if the dir is absent.
    func list(_ directory: String) async throws -> [StorageEntry]
    func get(_ path: String) async throws -> (data: Data, etag: String?)
    /// Conditional GET. If `knownEtag` matches the server's current copy, the
    /// implementation returns nil (304-style "still valid, save the bytes").
    /// Otherwise returns the fresh body + the new etag. With `nil` knownEtag,
    /// always returns the body — equivalent to a plain `get`.
    func get(_ path: String, ifNoneMatch knownEtag: String?) async throws -> (data: Data, etag: String?)?
    func put(_ path: String, data: Data, precondition: WritePrecondition) async throws
    func makeDirectory(_ path: String) async throws
    func exists(_ path: String) async throws -> Bool
    /// Remove a file. Idempotent: deleting an absent path is not an error
    /// (the postcondition — path gone — already holds).
    func delete(_ path: String) async throws
}

public extension StorageBackend {
    func put(_ path: String, data: Data) async throws {
        try await put(path, data: data, precondition: .none)
    }

    /// Default conditional GET = always re-download. Backends that can do a
    /// real 304 (WebDAV via `If-None-Match`, local file via mtime) override.
    func get(_ path: String, ifNoneMatch knownEtag: String?) async throws -> (data: Data, etag: String?)? {
        try await get(path)
    }
}
