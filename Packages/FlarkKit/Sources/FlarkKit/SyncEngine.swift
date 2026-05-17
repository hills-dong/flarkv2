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

    /// Called on the main actor whenever the projection changes.
    public var onChange: (@Sendable (Projection) -> Void)?

    public init(repo: SpaceRepository, clock: HLCClock, identity: DeviceIdentity) {
        self.repo = repo
        self.clock = clock
        self.identity = identity
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
        MergeReducer.reduce(&p, events: [event])
        projection = p
        pendingEvents.append(event)
        emit()
        Task { await self.flush() }
    }

    public func flush() async {
        let batch = pendingEvents
        pendingEvents = []
        for e in batch {
            do {
                try await repo.append(e)
                knownEventPaths.insert("events/\(e.authorID)/\(e.hlc.description)-\(e.eventID).json")
            } catch {
                pendingEvents.append(e)   // retry on the next tick
            }
        }
    }

    // MARK: - Pull / merge

    @discardableResult
    public func sync() async -> Bool {
        await flush()
        guard let paths = try? await repo.listEventPaths() else { return false }
        let fresh = paths.filter { !knownEventPaths.contains($0) }

        var loaded: [Event] = []
        for path in fresh {
            if let e = try? await repo.loadEvent(at: path), e.isAuthentic() {
                loaded.append(e)
                clock.receive(e.hlc)
            }
            knownEventPaths.insert(path)
        }

        var p = projection
        var changed = false
        if !loaded.isEmpty {
            MergeReducer.reduce(&p, events: loaded)
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
        guard changed else { return false }
        projection = p
        emit()
        return true
    }

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 15) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private func emit() {
        let snapshot = projection
        if let cb = onChange { cb(snapshot) }
    }
}
