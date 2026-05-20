import Foundation

/// FileManager-backed storage. Used both for the on-device store (app
/// Application Support) and for "local folder" Spaces shared via iCloud/SMB.
public final class LocalFileBackend: StorageBackend, @unchecked Sendable {
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(_ path: String) -> URL {
        var u = root
        for c in path.split(separator: "/") { u.appendPathComponent(String(c)) }
        return u
    }

    /// Local "etag" = size+mtime fingerprint; good enough for change detection.
    private func etag(for u: URL) -> String? {
        guard let a = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        let size = (a[.size] as? Int) ?? 0
        let mod = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mod * 1000))"
    }

    public func list(_ directory: String) async throws -> [StorageEntry] {
        let dir = url(directory)
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            FlarkLog.shared.record(.info, .storage, "LIST",
                                   path: directory, detail: "0 entries")
            return []
        }
        let entries = items.map { item -> StorageEntry in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rel = directory.isEmpty ? item.lastPathComponent : "\(directory)/\(item.lastPathComponent)"
            return StorageEntry(path: rel, isDirectory: isDir, etag: isDir ? nil : etag(for: item))
        }
        FlarkLog.shared.record(.info, .storage, "LIST",
                               path: directory, detail: "\(entries.count) entries")
        return entries
    }

    public func get(_ path: String) async throws -> (data: Data, etag: String?) {
        let u = url(path)
        guard let data = fm.contents(atPath: u.path) else {
            FlarkLog.shared.record(.warn, .storage, "GET",
                                   path: path, detail: "not found")
            throw StorageError.notFound
        }
        FlarkLog.shared.record(.info, .storage, "GET",
                               path: path, bytes: data.count)
        return (data, etag(for: u))
    }

    /// Conditional GET against the local mtime/size fingerprint. Lets tests
    /// exercise the same 304 path as the WebDAV backend.
    public func get(_ path: String, ifNoneMatch knownEtag: String?) async throws -> (data: Data, etag: String?)? {
        let u = url(path)
        let current = etag(for: u)
        if let known = knownEtag, current == known {
            FlarkLog.shared.record(.info, .storage, "GET",
                                   path: path, detail: "304 not modified")
            return nil
        }
        guard let data = fm.contents(atPath: u.path) else {
            FlarkLog.shared.record(.warn, .storage, "GET",
                                   path: path, detail: "not found")
            throw StorageError.notFound
        }
        FlarkLog.shared.record(.info, .storage, "GET",
                               path: path, bytes: data.count)
        return (data, current)
    }

    public func put(_ path: String, data: Data, precondition: WritePrecondition) async throws {
        let u = url(path)
        switch precondition {
        case .createOnly where fm.fileExists(atPath: u.path):
            FlarkLog.shared.record(.info, .storage, "PUT",
                                   path: path, detail: "createOnly skipped (exists)")
            throw StorageError.preconditionFailed
        case .ifMatch(let tag) where etag(for: u) != tag:
            FlarkLog.shared.record(.warn, .storage, "PUT",
                                   path: path, detail: "ifMatch failed")
            throw StorageError.preconditionFailed
        default: break
        }
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic replace so a half-written file is never observed by readers.
        try data.write(to: u, options: .atomic)
        FlarkLog.shared.record(.info, .storage, "PUT",
                               path: path, bytes: data.count)
    }

    public func makeDirectory(_ path: String) async throws {
        try fm.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    public func exists(_ path: String) async throws -> Bool {
        fm.fileExists(atPath: url(path).path)
    }

    public func delete(_ path: String) async throws {
        let u = url(path)
        guard fm.fileExists(atPath: u.path) else { return }   // idempotent
        try fm.removeItem(at: u)
        FlarkLog.shared.record(.info, .storage, "DELETE", path: path)
    }
}
