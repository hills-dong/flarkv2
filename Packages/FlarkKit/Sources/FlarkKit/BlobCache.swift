import Foundation

/// A local, on-disk cache for content-addressed blobs (images, avatars).
///
/// Blobs are immutable and named by the SHA-256 of their bytes, so a cache
/// hit can never be stale: same id ⇒ same content, forever. This lets a
/// WebDAV-backed Space avoid re-downloading every image on each render /
/// poll, and serves them with no network at all once seen.
///
/// Strictly a cache: it lives in the OS Caches area (purgeable under storage
/// pressure) and any miss simply falls back to the backend. The URL is
/// injected by the app layer so FlarkKit stays free of app-specific paths.
public struct BlobCache: Sendable {
    private let dir: URL

    public init(directory: URL) {
        self.dir = directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    // blobIDs are base32(sha256) — already a safe, flat filename.
    private func path(_ id: String) -> URL { dir.appendingPathComponent(id) }

    public func data(for id: String) -> Data? {
        try? Data(contentsOf: path(id))
    }

    public func store(_ data: Data, for id: String) {
        try? data.write(to: path(id), options: .atomic)
    }
}
