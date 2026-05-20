import Foundation

/// One observable data-plane event for the in-app diagnostics page. Emitted
/// from the storage backend (every HTTP / file call), the repository (every
/// semantic append / rotate / blob op), and the sync engine (every poll
/// round, 304 skip, fold). The UI subscribes and shows them newest-first so
/// the user can audit exactly what the device is reading and writing.
public struct LogEvent: Identifiable, Sendable, Hashable {
    public enum Level: String, Sendable, Hashable { case info, warn, error }
    public enum Category: String, Sendable, Hashable {
        /// Storage backend layer — WebDAV HTTP calls or LocalFileBackend
        /// file operations. The lowest-level "what bytes moved" signal.
        case storage
        /// SpaceRepository semantic events: append batch, rotate seq, flush
        /// active file, blob put, bootstrap recovery.
        case repo
        /// SyncEngine round-level events: listing diff, fold, 304 skip,
        /// throttle/offline detection.
        case sync
    }
    public let id: UUID
    public let time: Date
    public let level: Level
    public let category: Category
    public let action: String
    public let path: String?
    public let detail: String?
    public let bytes: Int?
    public let durationMs: Int?

    public init(time: Date = Date(),
                level: Level,
                category: Category,
                action: String,
                path: String? = nil,
                detail: String? = nil,
                bytes: Int? = nil,
                durationMs: Int? = nil) {
        self.id = UUID()
        self.time = time
        self.level = level
        self.category = category
        self.action = action
        self.path = path
        self.detail = detail
        self.bytes = bytes
        self.durationMs = durationMs
    }
}

/// Bounded in-memory ring buffer for LogEvents. Process-wide singleton: a
/// lock guards `buffer` and `listeners` so any actor / Task may record into
/// it without ceremony. The UI uses `snapshot()` for first paint and
/// `subscribe(_:)` for live updates.
public final class FlarkLog: @unchecked Sendable {
    public static let shared = FlarkLog()
    private let lock = NSLock()
    private var buffer: [LogEvent] = []
    private var listeners: [(UUID, @Sendable (LogEvent) -> Void)] = []
    /// 1000 entries comfortably covers a typical session without bounding
    /// app memory; the UI shows newest-first so older spill is acceptable.
    public let capacity: Int

    private init(capacity: Int = 1000) { self.capacity = capacity }

    public func record(_ level: LogEvent.Level,
                       _ category: LogEvent.Category,
                       _ action: String,
                       path: String? = nil,
                       detail: String? = nil,
                       bytes: Int? = nil,
                       durationMs: Int? = nil) {
        let event = LogEvent(level: level, category: category, action: action,
                             path: path, detail: detail,
                             bytes: bytes, durationMs: durationMs)
        lock.lock()
        buffer.append(event)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let snapshot = listeners.map(\.1)
        lock.unlock()
        for cb in snapshot { cb(event) }
    }

    public func snapshot() -> [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Returns an opaque token; pass it to `unsubscribe` on teardown so the
    /// UI doesn't keep stale closures pinned after navigating away.
    @discardableResult
    public func subscribe(_ cb: @escaping @Sendable (LogEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners.append((id, cb))
        lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        listeners.removeAll { $0.0 == id }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
