import Foundation
import FlarkKit
#if canImport(ActivityKit)
import ActivityKit

/// Bridges the engine's `SyncActivity` updates to a Live Activity in the
/// Dynamic Island. iOS-only — `ActivityKit` doesn't exist on macOS, so the
/// whole file is compiled out there.
///
/// Lifecycle: the first non-idle update starts the activity; subsequent
/// non-idle updates call `update()`; the first idle update ends it.
@MainActor
final class SyncLiveActivityHost {
    private var current: Activity<SyncActivityAttributes>?
    private var spaceName: String = ""

    func setSpaceName(_ name: String) {
        spaceName = name
        // If an activity is already on screen for a different space, force a
        // restart so the name in the header refreshes (`attributes` is fixed
        // for the activity's lifetime; only the content state can update).
        if let cur = current {
            let state = cur.content.state
            Task { @MainActor in
                await cur.end(nil, dismissalPolicy: .immediate)
                self.current = nil
                self.start(state: state)
            }
        }
    }

    /// Translate `SyncActivity` → activity create/update/end.
    func apply(_ status: SyncActivity) {
        switch status {
        case .idle:
            end()
        case let .syncing(done, total):
            update(.init(done: done, total: total, phase: .syncing))
        case let .throttled(done, total):
            update(.init(done: done, total: total, phase: .throttled))
        case let .offline(done, total):
            update(.init(done: done, total: total, phase: .offline))
        }
    }

    private func update(_ state: SyncActivityAttributes.ContentState) {
        if let cur = current {
            Task { await cur.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            start(state: state)
        }
    }

    private func start(state: SyncActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = SyncActivityAttributes(spaceName: spaceName)
        do {
            current = try Activity.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
        } catch {
            // Activities can fail to start under low-power mode or when the
            // user has disabled them per-app. Swallow — sync still works,
            // we just don't paint to the island.
            FlarkLog.shared.record(.warn, .sync, "ACTIVITY_START_FAILED",
                                    detail: "\(error)")
        }
    }

    private func end() {
        guard let cur = current else { return }
        current = nil
        Task { await cur.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
