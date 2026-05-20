import Foundation

/// What the sync engine is doing right now, for a user-facing status line.
/// `done`/`total` are event counts; the indicator stays up — with live
/// progress — until `done == total`. A stalled round keeps the last known
/// progress and just annotates *why* it stalled (rate-limited vs offline).
/// No retry countdown: pulls only happen when the user explicitly refreshes,
/// so there is no automatic next-round to count down to.
public enum SyncActivity: Equatable, Sendable {
    case idle                                   // fully caught up
    case syncing(done: Int, total: Int)         // actively pulling/folding
    case throttled(done: Int, total: Int)       // server pushback; user must retry
    case offline(done: Int, total: Int)         // no network; user must retry
}

/// Drives convergence: publishes local events, pulls remote ones, folds them
/// into a Projection with the order-independent reducer. No server arbiter —
/// every device independently reaches the same state.
public actor SyncEngine {
    private let repo: SpaceRepository
    private let clock: HLCClock
    private let identity: DeviceIdentity
    public private(set) var projection = Projection()

    /// path → server etag of the file content already folded. A future poll
    /// round sends `If-None-Match: <etag>` for each path; the server returns
    /// 304 for unchanged files and we skip the redownload entirely. The map
    /// also doubles as "have I folded this path at this version" dedupe.
    private var pathEtags: [String: String] = [:]
    /// path → etag for profile files. Parallel to `pathEtags`, but for the
    /// profile listing — lets sync skip per-file GETs when nothing changed.
    private var profileEtags: [String: String] = [:]
    private var pendingEvents: [Event] = []

    private let snapshotStore: SnapshotStore?
    private var maxHLC: HLC?
    private var snapshotDirty = false

    /// Last known (done, total) so a stalled round can keep showing progress
    /// instead of dropping to a bare error state.
    private var lastProgress: (done: Int, total: Int) = (0, 0)

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
        pathEtags = snap.pathEtags
        profileEtags = snap.profileEtags
        maxHLC = snap.maxHLC
        if let h = snap.maxHLC { clock.receive(h) }   // never let the clock regress
        emit()
    }

    /// Persist the current projection as a local cache. No-op if nothing
    /// changed since the last write. Never touches the shared Space.
    public func persistSnapshot() {
        guard let store = snapshotStore, snapshotDirty else { return }
        store.save(ProjectionSnapshot(pathEtags: pathEtags,
                                      profileEtags: profileEtags,
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

    /// True if the last windowed `sync` left older files unfetched — the UI
    /// can show a "load earlier" affordance; subsequent manual refreshes
    /// keep backfilling.
    public private(set) var hasUnsyncedHistory = false

    /// Fetch the next older window now (e.g. user scrolled to the bottom).
    @discardableResult
    public func loadOlder(_ batch: Int = 16) async -> Bool {
        await sync(maxNewFiles: batch)
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
        guard !batch.isEmpty else { return }
        do {
            // One PUT per drain — events that piled up during the actor's
            // serialization window go in a single backend round-trip. The
            // engine's debounced submit dispatch is what collects them; this
            // method just turns the queue into one upload.
            _ = try await repo.appendBatch(batch)
        } catch {
            pendingEvents.append(contentsOf: batch)   // retry on the next tick
        }
    }

    // MARK: - Pull / merge

    /// Pull & fold remote events.
    ///
    /// `maxNewFiles` bounds how many remote files are fetched this round,
    /// newest-first (filenames are zero-padded seq-prefixed, so per-device
    /// the basename sorts by recency). A new member joining a 10k-event
    /// Space gets the recent activity immediately instead of blocking on
    /// the entire log; older files backfill over subsequent polling rounds.
    /// Unbounded when `nil` (legacy behavior). Order-independent: the
    /// reducer derives topic aggregates from the reply bucket, so an older
    /// topic-create folded after newer replies still converges.
    @discardableResult
    public func sync(maxNewFiles: Int? = nil) async -> Bool {
        // Surface the round to the status bar from the very first instant. A
        // short manual refresh (e.g. 4 files in <1s) would otherwise complete
        // before the activity hop to MainActor delivered any visible state.
        let (d0, t0) = lastProgress
        publishActivity(.syncing(done: d0, total: max(t0, d0)))
        await flush()
        let roundStart = Date()
        let entries: [StorageEntry]
        do {
            entries = try await repo.listEventEntries()
        } catch {
            // Keep the last known progress visible; just say *why* it stalled.
            // No auto-retry — the user will pull-to-refresh when they're ready.
            let (d, t) = lastProgress
            let throttled = Self.isThrottled(error)
            FlarkLog.shared.record(.error, .sync, throttled ? "throttled" : "offline",
                                   detail: error.localizedDescription)
            publishActivity(throttled
                ? .throttled(done: d, total: t)
                : .offline(done: d, total: t))
            return false
        }
        // Diff the listing against our recorded path→etag map. Three buckets:
        //   stale  : path known but server etag differs → the file grew (an
        //            active file got new events appended); refetch.
        //   newAll : path never seen → cold fetch.
        //   else   : etag unchanged → skip, server confirms it via 304.
        var stale: [StorageEntry] = []
        var newAll: [StorageEntry] = []
        for e in entries {
            if let known = pathEtags[e.path] {
                if e.etag != nil, e.etag != known { stale.append(e) }
            } else {
                newAll.append(e)
            }
        }
        let totalNew = newAll.count

        // Newest first per device. Stale (already-folded files) are usually
        // small in number and always urgent (active file grew), so fetch
        // them all every round; only window the cold-fetch backlog.
        newAll.sort { Self.basename($0.path) > Self.basename($1.path) }
        if let cap = maxNewFiles, newAll.count > cap {
            newAll = Array(newAll.prefix(cap))
        }
        hasUnsyncedHistory = totalNew > newAll.count

        var loaded: [Event] = []
        var skipped304 = 0
        var fetchErrors = 0
        for entry in stale + newAll {
            do {
                // Conditional GET — if the server says 304 (etag matched in
                // a race between PROPFIND and GET), we just record the etag
                // and move on. Otherwise fold the array.
                guard let result = try await repo.loadEventsIfChanged(
                    at: entry.path, knownEtag: pathEtags[entry.path]) else {
                    if let t = entry.etag { pathEtags[entry.path] = t }
                    skipped304 += 1
                    continue
                }
                for e in result.events where e.isAuthentic() {
                    loaded.append(e)
                    clock.receive(e.hlc)
                    bumpMaxHLC(e.hlc)
                }
                pathEtags[entry.path] = result.etag ?? entry.etag ?? ""
            } catch {
                fetchErrors += 1
                FlarkLog.shared.record(.warn, .sync, "fetch.fail",
                                       path: entry.path,
                                       detail: error.localizedDescription)
                continue
            }
        }

        var p = projection
        var changed = false
        if !loaded.isEmpty {
            // Already verified above (e.isAuthentic() gate) — don't re-verify.
            MergeReducer.reduceTrusted(&p, events: loaded)
            changed = true
        }
        // Profiles can change with no accompanying event, so the engine still
        // polls them — but the etag-aware loader skips the GET for any
        // profile whose listing-etag matches what we already folded.
        if let fresh = try? await repo.loadProfiles(knownEtags: profileEtags) {
            for (id, f) in fresh.changed where DeviceIdentity.authorID(
                forPublicKey: Data(base64Encoded: f.publicKey) ?? Data()) == id {
                let before = p.profiles[id]
                p.applyProfile(authorID: id, displayName: f.displayName,
                               avatarBlobID: f.avatarBlobID, stampMillis: f.updatedAt)
                if p.profiles[id] != before { changed = true }
            }
            // Persist the listing's full etag map; dropped paths fall out and
            // changed ones get their freshly-fetched etag in.
            if profileEtags != fresh.etags {
                profileEtags = fresh.etags
                snapshotDirty = true
            }
        }
        if !newAll.isEmpty || !stale.isEmpty { snapshotDirty = true }
        // Reclaim: forget paths that no longer exist remotely. Guard a
        // transient empty listing from wiping the whole map.
        if !entries.isEmpty {
            let liveSet = Set(entries.map(\.path))
            let before = pathEtags.count
            pathEtags = pathEtags.filter { liveSet.contains($0.key) }
            if pathEtags.count != before { snapshotDirty = true }
        }
        // Persistent progress: events folded so far vs an estimate of the
        // whole space (one rotation-cap of events per as-yet-unfetched file).
        let leftover = (totalNew - newAll.count) * SpaceRepository.rotationEventCount
        let done = p.appliedEventIDs.count
        let total = done + leftover
        lastProgress = (done, total)
        let complete = leftover == 0 && !hasUnsyncedHistory
        publishActivity(complete ? .idle : .syncing(done: done, total: total))
        let roundMs = Int(Date().timeIntervalSince(roundStart) * 1000)
        FlarkLog.shared.record(
            fetchErrors > 0 ? .warn : .info, .sync, "round",
            detail: "\(entries.count) listed · \(loaded.count) folded · \(skipped304) 304 · \(stale.count) stale · \(newAll.count) fetched\(fetchErrors > 0 ? " · \(fetchErrors) errors" : "")",
            durationMs: roundMs)
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

    // MARK: - Push / lifecycle

    /// Push side only — flushes any queued local events to the backend so
    /// remote readers see this device's writes without waiting for the next
    /// manual refresh. Called automatically after every local mutation.
    /// Fetch side stays manual (only `sync()` / `refresh`).
    public func pushOutbox() async {
        await flush()
        try? await repo.flushActive()
    }

    /// Tear-down before closing the Space (logout / switch space / scene
    /// backgrounding). Drains the outbox and persists the snapshot so the
    /// next session opens with a fresh local cache and no stranded writes.
    public func shutdown() async {
        await flush()
        try? await repo.flushActive()
        persistSnapshot()
    }

    private func emit() {
        let snapshot = projection
        if let cb = onChange { cb(snapshot) }
    }
}
