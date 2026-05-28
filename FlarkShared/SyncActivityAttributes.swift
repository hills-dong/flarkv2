import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity payload for the Dynamic Island sync indicator.
///
/// Mirrors `FlarkKit.SyncActivity` in a Codable form suitable for ActivityKit.
/// Compiled into both the main app (which calls `Activity.request/update/end`)
/// and the widget extension (which renders the island UI), so the layout lives
/// in this top-level directory rather than inside either target.
public struct SyncActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var done: Int
        public var total: Int
        public var phase: Phase

        public init(done: Int, total: Int, phase: Phase) {
            self.done = done
            self.total = total
            self.phase = phase
        }
    }

    public enum Phase: String, Codable, Hashable {
        case syncing, throttled, offline
    }

    /// Space name shown in the lock-screen / expanded view header.
    public var spaceName: String

    public init(spaceName: String) {
        self.spaceName = spaceName
    }
}
#endif
