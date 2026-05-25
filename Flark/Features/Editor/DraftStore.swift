import Foundation
import FlarkKit

/// Identity of an in-flight editor session, used to key a persisted draft so
/// the four flows — new topic, new reply, edit topic, edit reply — never
/// trample each other. A single new-topic slot per space is the right call
/// since the composer is modal: only one can be open at a time.
enum DraftKey: Hashable {
    case newTopic
    case newReply(topicID: String)
    case editTopic(topicID: String)
    case editReply(replyID: String)

    fileprivate var filename: String {
        switch self {
        case .newTopic: return "newTopic.json"
        case .newReply(let id): return "newReply_\(DraftKey.safe(id)).json"
        case .editTopic(let id): return "editTopic_\(DraftKey.safe(id)).json"
        case .editReply(let id): return "editReply_\(DraftKey.safe(id)).json"
        }
    }

    /// Topic/reply ids are HLC-shaped (`<hlc>-<author>`), which is safe enough
    /// for a filename, but other id sources have shown up before — strip any
    /// path-hostile chars defensively so a stray `/` can't escape the dir.
    private static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: ":", with: "_")
    }
}

/// File-backed store for unsent composer drafts. Lives in Application Support
/// so iOS doesn't reclaim it under storage pressure (caches would). One
/// directory per space (keyed by `localID`) so binding the same spaceID to a
/// second WebDAV doesn't see leftover drafts from the first binding.
enum DraftStore {
    private static func directory(localID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlarkDrafts/\(localID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(key: DraftKey, localID: String) -> URL {
        directory(localID: localID).appendingPathComponent(key.filename)
    }

    static func load(key: DraftKey, localID: String) -> ContentDocument? {
        guard let data = try? Data(contentsOf: url(key: key, localID: localID)) else { return nil }
        return try? ContentDocument.decode(data)
    }

    /// Persists `doc` for `key`, or removes the file if `doc` is empty or
    /// equals `initial` (i.e., the user hasn't actually diverged from the
    /// pre-filled body in an edit flow — keeping a no-op draft would mask
    /// remote edits the next time the composer opens).
    static func save(_ doc: ContentDocument, key: DraftKey, localID: String, initial: ContentDocument) {
        let url = url(key: key, localID: localID)
        if doc.isEmpty || doc == initial {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? doc.encoded() else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(key: DraftKey, localID: String) {
        try? FileManager.default.removeItem(at: url(key: key, localID: localID))
    }
}
