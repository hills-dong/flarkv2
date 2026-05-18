import Foundation

/// What the sync engine is doing right now, for a user-facing status line.
/// `done`/`total` are event counts (a sealed segment ≈ a full batch); the
/// indicator stays up — with live progress — until `done == total`. A stalled
/// round keeps the last known progress and just annotates *why* it stalled
/// (rate-limited vs offline) instead of dropping the progress.
public enum SyncActivity: Equatable, Sendable {
    case idle                                   // fully caught up
    case syncing(done: Int, total: Int)         // actively pulling/folding
    /// Server rate-limited; `retryAt` is when the next round fires (UI counts down).
    case throttled(done: Int, total: Int, retryAt: Date)
    case offline(done: Int, total: Int, retryAt: Date)
    case compacting                             // packing history into a segment
}

/// Drives convergence: publishes local events, pulls remote ones, folds them
/// into a Projection with the order-independent reducer. No server arbiter —
/// every device independently reaches the same state.
public actor SyncEngine {
    private let repo: SpaceRepository
    private let clock: HLCClock
    private let identity: DeviceIdentity
    public private(set) var projection = Projection()

    private var knownEventPaths: Set<String> = []
    private var pendingEvents: [Event] = []
    private var pollTask: Task<Void, Never>?

    private let snapshotStore: SnapshotStore?
    private var maxHLC: HLC?
    private var snapshotDirty = false

    /// Sealed-history segments are big (≈1000 events); fetch at most this many
    /// per round so a fresh device backfills over a few rounds instead of one
    /// request burst that the WebDAV host rate-limits.
    private let maxNewSegmentsPerRound = 4
    /// Attempt a compaction once this many new events have been folded since
    /// the last attempt — drains the loose tail promptly instead of letting
    /// it linger between sparse sync rounds.
    private let sealEveryNEvents = 10
    private var eventsSinceSeal = 0
    private var sealing = false
    /// Last known (done, total) so a stalled round can keep showing progress
    /// instead of dropping to a bare error state.
    private var lastProgress: (done: Int, total: Int) = (0, 0)
    /// Polling cadence — also the delay until the next auto-retry, so the UI
    /// can show a recovery countdown.
    private var pollInterval: TimeInterval = 15

    /// Called on the main actor whenever the projection changes.
    public var onChange: (@Sendable (Projection) -> Void)?

    /// Coarse background activity, for a status indicator. De-duplicated so
    /// the UI isn't churned with identical values.
    public private(set) var activity: SyncActivity = .idle
    private var onActivity: (@Sendable (SyncActivity) -> Void)?

    public func setOnActivity(_ handler: @escaping @Sendable (SyncActivity) -> Void) {
        self.onActivity = handler
    }

    private func publishActivity(_ a: SyncActivity) {
        // While a compaction runs, keep showing it — a concurrent sync round
        // must not flip the indicator back to syncing/idle underneath it.
        if sealing, a != .compacting { return }
        guard a != activity else { return }
        activity = a
        onActivity?(a)
    }

    public init(repo: SpaceRepository, clock: HLCClock, identity: DeviceIdentity,
                snapshotStore: SnapshotStore? = nil) {
        self.repo = repo
        self.clock = clock
        self.identity = identity
        self.snapshotStore = snapshotStore
    }

    /// Restore the local snapshot cache so the UI paints instantly and sync
    /// only folds genuinely-new events. A missing/incompatible/corrupt
    /// snapshot is simply ignored — a full rebuild from the event log is the
    /// safe fallback and the only correctness path.
    public func restoreSnapshot() {
        guard let snap = snapshotStore?.load() else { return }
        projection = snap.projection
        knownEventPaths = Set(snap.knownEventPaths)
        maxHLC = snap.maxHLC
        if let h = snap.maxHLC { clock.receive(h) }   // never let the clock regress
        emit()
    }

    /// Persist the current projection as a local cache. No-op if nothing
    /// changed since the last write. Never touches the shared Space.
    public func persistSnapshot() {
        guard let store = snapshotStore, snapshotDirty else { return }
        store.save(ProjectionSnapshot(knownEventPaths: Array(knownEventPaths),
                                      maxHLC: maxHLC, projection: projection))
        snapshotDirty = false
    }

    private func bumpMaxHLC(_ h: HLC) {
        if let m = maxHLC { if h > m { maxHLC = h } } else { maxHLC = h }
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Server pushback (rate-limit / locked / overloaded / refused — incl.
    /// hosts like jianguoyun that throttle by dropping or stalling the
    /// connection instead of returning 429) vs a genuine no-network state.
    /// Bias toward 限流: only call it 离线 when the device truly has no link.
    static func isThrottled(_ error: Error) -> Bool {
        guard let s = error as? StorageError else { return true }
        switch s {
        case .server, .unauthorized, .preconditionFailed, .notFound:
            return true
        case .transport(let detail):
            let d = detail.lowercased()
            // Real connectivity loss → 离线; anything else → 限流.
            let offline = ["-1009", "offline",            // not connected
                           "-1003", "cannot find host",   // DNS / no network
                           "-1004", "could not connect to the server"]
            return !offline.contains { d.contains($0) }
        }
    }

    /// True if the last windowed `sync` left older events unfetched — the UI
    /// can show a "load earlier" affordance; polling also keeps backfilling.
    public private(set) var hasUnsyncedHistory = false

    /// Fetch the next older window now (e.g. user scrolled to the bottom).
    @discardableResult
    public func loadOlder(_ batch: Int = 500) async -> Bool {
        await sync(maxNewEvents: batch)
    }

    public func setOnChange(_ handler: @escaping @Sendable (Projection) -> Void) {
        self.onChange = handler
    }

    /// Show our own name/avatar instantly without waiting for a sync round.
    public func setLocalProfile(authorID: String, displayName: String, avatarBlobID: String?) {
        var p = projection
        p.applyProfile(authorID: authorID, displayName: displayName,
                       avatarBlobID: avatarBlobID,
                       stampMillis: Int64(Date().timeIntervalSince1970 * 1000))
        projection = p
        emit()
    }

    // MARK: - Local mutations

    /// Builds and signs the event so it is immediately authentic — the
    /// reducer drops unauthentic events, so local UI needs a signed one.
    public func makeEvent(_ payload: Event.Payload, authorID: String, publicKey: Data) -> Event {
        var e = Event(hlc: clock.send(), authorID: authorID, publicKey: publicKey,
                      spaceID: repo.spaceID, payload: payload)
        try? e.sign(with: identity)
        return e
    }

    /// Apply locally for instant UI, queue for durable publish.
    public func submit(_ event: Event) {
        var p = projection
        MergeReducer.reduceTrusted(&p, events: [event])   // just signed locally
        projection = p
        bumpMaxHLC(event.hlc)
        snapshotDirty = true
        pendingEvents.append(event)
        emit()
        Task { await self.flush() }
    }

    public func flush() async {
        let batch = pendingEvents
        pendingEvents = []
        for e in batch {
            do {
                let path = try await repo.append(e)
                knownEventPaths.insert(path)
            } catch {
                pendingEvents.append(e)   // retry on the next tick
            }
        }
    }

    // MARK: - Pull / merge

    /// Pull & fold remote events.
    ///
    /// `maxNewEvents` bounds how many of the not-yet-folded event files are
    /// fetched **this round**, newest-first (event filenames are HLC-prefixed,
    /// so the basename sorts by time). A new member joining a 10k-topic Space
    /// gets the recent topics immediately instead of blocking on the entire
    /// log; the remaining older events backfill over subsequent rounds
    /// (polling) without ever doing one catastrophic download. Unbounded when
    /// `nil` (legacy behavior). Order-independent: the reducer derives topic
    /// aggregates from the reply bucket, so older create events folded after
    /// their newer replies still converge.
    @discardableResult
    public func sync(maxNewEvents: Int? = nil) async -> Bool {
        await flush()
        let paths: [String]
        do {
            paths = try await repo.listEventPaths()
        } catch {
            // Keep the last known progress visible; just say *why* it stalled
            // and when the next automatic retry fires (UI counts down to it).
            let (d, t) = lastProgress
            let retryAt = Date().addingTimeInterval(pollInterval)
            publishActivity(Self.isThrottled(error)
                ? .throttled(done: d, total: t, retryAt: retryAt)
                : .offline(done: d, total: t, retryAt: retryAt))
            return false
        }
        let freshAll = paths.filter { !knownEventPaths.contains($0) }
        // Segments hold sealed old history; singles are the live tail. Window
        // them separately: newest singles first for fast first-paint, only a
        // few big segments per round so backfill never bursts into a rate cap.
        var freshSegs = freshAll.filter { SpaceRepository.isSegment($0) }
        var freshSingles = freshAll.filter { !SpaceRepository.isSegment($0) }
        let totalSingles = freshSingles.count, totalSegs = freshSegs.count

        freshSingles.sort { Self.basename($0) > Self.basename($1) }   // newest first
        if let cap = maxNewEvents, freshSingles.count > cap {
            freshSingles = Array(freshSingles.prefix(cap))
        }
        freshSegs.sort { Self.basename($0) > Self.basename($1) }      // newest first
        if freshSegs.count > maxNewSegmentsPerRound {
            freshSegs = Array(freshSegs.prefix(maxNewSegmentsPerRound))
        }
        hasUnsyncedHistory = totalSingles > freshSingles.count
            || totalSegs > freshSegs.count

        var loaded: [Event] = []
        for path in freshSegs + freshSingles {
            if let events = try? await repo.loadEvents(at: path) {
                for e in events where e.isAuthentic() {
                    loaded.append(e)
                    clock.receive(e.hlc)
                    bumpMaxHLC(e.hlc)
                }
            }
            knownEventPaths.insert(path)
        }

        var p = projection
        var changed = false
        if !loaded.isEmpty {
            // Already verified above (e.isAuthentic() gate) — don't re-verify.
            MergeReducer.reduceTrusted(&p, events: loaded)
            changed = true
        }
        // Profiles always refresh — the per-author file is the trust boundary,
        // and they can change with no accompanying event.
        if let profiles = try? await repo.loadProfiles() {
            for (id, f) in profiles where DeviceIdentity.authorID(
                forPublicKey: Data(base64Encoded: f.publicKey) ?? Data()) == id {
                let before = p.profiles[id]
                p.applyProfile(authorID: id, displayName: f.displayName,
                               avatarBlobID: f.avatarBlobID, stampMillis: f.updatedAt)
                if p.profiles[id] != before { changed = true }
            }
        }
        // knownEventPaths grew even when no authentic events loaded — persist
        // so the next cold start doesn't re-walk/re-read those files.
        if !freshSegs.isEmpty || !freshSingles.isEmpty { snapshotDirty = true }
        // Reclaim: forget paths that no longer exist (singles that sealing
        // packed into a segment and deleted). Their events live on in a folded
        // segment, so dropping the dead path is safe and stops the snapshot
        // growing without bound. Guard a transient empty listing from wiping
        // the set; a rare consistency-lag drop only causes one idempotent
        // re-fold next round.
        if !paths.isEmpty {
            let before = knownEventPaths.count
            knownEventPaths.formIntersection(paths)
            if knownEventPaths.count != before { snapshotDirty = true }
        }
        // Persistent progress: events folded so far vs an estimate of the
        // whole space (a segment ≈ a full batch). Stays up until done == total.
        let leftover = (totalSingles - freshSingles.count)
            + (totalSegs - freshSegs.count) * SpaceRepository.segmentBatchSize
        let done = p.appliedEventIDs.count
        let total = done + leftover
        lastProgress = (done, total)
        let complete = leftover == 0 && !hasUnsyncedHistory
        publishActivity(complete ? .idle : .syncing(done: done, total: total))
        eventsSinceSeal += loaded.count
        maybeSealHistory()
        guard changed else {
            persistSnapshot()
            return false
        }
        projection = p
        snapshotDirty = true
        persistSnapshot()
        emit()
        return true
    }

    /// Periodically pack our own oldest singles into a sealed segment so the
    /// author dir stays small. Runs detached (sealing reads ~1000 files) and
    /// non-reentrant; failures are retried on the next due round (idempotent).
    private func maybeSealHistory() {
        guard !sealing, eventsSinceSeal >= sealEveryNEvents else { return }
        eventsSinceSeal = 0          // reset even if it no-ops, so we don't
                                     // re-list the author dir every round
        sealing = true
        publishActivity(.compacting)
        let r = repo
        Task { [weak self] in
            _ = try? await r.sealOwnHistory()
            await self?.endSealing()
        }
    }

    private func endSealing() {
        sealing = false
        // Drop the compaction banner; the next poll round re-derives the real
        // state (idle / syncing) within seconds.
        publishActivity(.idle)
    }

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 15, window: Int? = 500) {
        pollInterval = interval
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync(maxNewEvents: window)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel(); pollTask = nil
        persistSnapshot()
    }

    private func emit() {
        let snapshot = projection
        if let cb = onChange { cb(snapshot) }
    }
}
