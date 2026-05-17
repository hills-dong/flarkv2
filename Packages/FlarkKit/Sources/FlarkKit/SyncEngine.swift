import Foundation

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

    /// Called on the main actor whenever the projection changes.
    public var onChange: (@Sendable (Projection) -> Void)?

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
        guard let paths = try? await repo.listEventPaths() else { return false }
        var fresh = paths.filter { !knownEventPaths.contains($0) }
        let totalFresh = fresh.count
        if let cap = maxNewEvents, fresh.count > cap {
            fresh.sort { Self.basename($0) > Self.basename($1) }   // newest first
            fresh = Array(fresh.prefix(cap))
        }
        hasUnsyncedHistory = totalFresh > fresh.count

        var loaded: [Event] = []
        for path in fresh {
            if let e = try? await repo.loadEvent(at: path), e.isAuthentic() {
                loaded.append(e)
                clock.receive(e.hlc)
                bumpMaxHLC(e.hlc)
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
        if !fresh.isEmpty { snapshotDirty = true }
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

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 15, window: Int? = 500) {
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
