import XCTest
@testable import FlarkKit

/// Two independent devices pointed at the SAME local directory (the "no
/// server, shared folder" scenario) must converge through the event log.
final class StorageSyncTests: XCTestCase {

    func testTwoDevicesConvergeViaSharedFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flark-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let backendA = LocalFileBackend(root: root)
        let backendB = LocalFileBackend(root: root)   // same folder, other device
        let dong = DeviceIdentity.generate()
        let zhang = DeviceIdentity.generate()

        let repoA = SpaceRepository(backend: backendA, identity: dong, spaceID: "s1")
        let repoB = SpaceRepository(backend: backendB, identity: zhang, spaceID: "s1")
        let engineA = SyncEngine(repo: repoA, clock: HLCClock(nodeID: dong.authorID),
                                 identity: dong)
        let engineB = SyncEngine(repo: repoB, clock: HLCClock(nodeID: zhang.authorID),
                                 identity: zhang)
        try await repoA.bootstrap(spaceName: "Team")

        // Dong posts a topic with an inline blob; Zhang replies + reacts.
        let blob = try await repoA.putBlob(Data("png-bytes".utf8))
        let doc = ContentDocument(segments: [.text("ship "), .image(blobID: blob, width: 1, height: 1)])
        let t = await engineA.makeEvent(.topicCreate(topicID: "t1", body: doc),
                                        authorID: dong.authorID, publicKey: dong.publicKeyData)
        await engineA.submit(t)
        await engineA.flush()

        await engineB.sync()
        let r = await engineB.makeEvent(.replyCreate(replyID: "r1", topicID: "t1",
                                                     body: ContentDocument(text: "on it")),
                                        authorID: zhang.authorID, publicKey: zhang.publicKeyData)
        await engineB.submit(r)
        let rx = await engineB.makeEvent(.reactionSet(targetID: "t1", targetType: .topic,
                                                      emojiID: "u_fire", removed: false),
                                         authorID: zhang.authorID, publicKey: zhang.publicKeyData)
        await engineB.submit(rx)
        await engineB.flush()

        await engineA.sync()

        let pA = await engineA.projection
        let pB = await engineB.projection
        XCTAssertNotNil(pA.topics["t1"])
        XCTAssertEqual(pA.topics["t1"]?.replyCount, 1)
        XCTAssertEqual(pA.replies(forTopic: "t1").first?.id, "r1")
        XCTAssertEqual(pA.tallies(forTarget: "t1").first?.emojiID, "u_fire")
        XCTAssertEqual(pA.topics["t1"]?.body, pB.topics["t1"]?.body)
        XCTAssertEqual(pA.replies(forTopic: "t1").count, pB.replies(forTopic: "t1").count)

        // The content-addressed blob is retrievable by the other device.
        let fetched = try await repoB.getBlob(blob)
        XCTAssertEqual(String(data: fetched, encoding: .utf8), "png-bytes")
    }

    /// Wraps a backend and counts event-file GETs so tests can prove the
    /// snapshot/windowing actually eliminates redundant downloads.
    actor CountingBackend: StorageBackend {
        let wrapped: StorageBackend
        private(set) var eventGets = 0
        init(_ w: StorageBackend) { wrapped = w }
        func list(_ d: String) async throws -> [StorageEntry] { try await wrapped.list(d) }
        func get(_ p: String) async throws -> (data: Data, etag: String?) {
            if p.contains("/events/") { eventGets += 1 }
            return try await wrapped.get(p)
        }
        func put(_ p: String, data: Data, precondition: WritePrecondition) async throws {
            try await wrapped.put(p, data: data, precondition: precondition)
        }
        func makeDirectory(_ p: String) async throws { try await wrapped.makeDirectory(p) }
        func exists(_ p: String) async throws -> Bool { try await wrapped.exists(p) }
        func delete(_ p: String) async throws { try await wrapped.delete(p) }
    }

    /// Deterministically write `n` topic-create events (strictly increasing
    /// HLC) straight to storage — bypasses the engine's async flush so the
    /// files are guaranteed on disk before we assert.
    private func seedTopics(_ n: Int, into repo: SpaceRepository,
                            author: DeviceIdentity) async throws {
        var ms: Int64 = 1_000
        let clock = HLCClock(nodeID: author.authorID, now: { ms })
        for i in 0..<n {
            ms += 1                                   // strictly newer each time
            var e = Event(hlc: clock.send(), authorID: author.authorID,
                          publicKey: author.publicKeyData, spaceID: "s1",
                          payload: .topicCreate(topicID: "t\(i)",
                                                body: ContentDocument(text: "x")))
            try e.sign(with: author)
            try await repo.append(e)
        }
    }

    /// A new device restoring a snapshot must not re-download events it has
    /// already folded — the cold-start round-trip cliff is gone.
    func testSnapshotSkipsKnownEventDownloads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flark-snap-\(UUID().uuidString)")
        let snapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: snapURL) }

        let author = DeviceIdentity.generate()
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1")
        try await repoW.bootstrap(spaceName: "T")
        try await seedTopics(8, into: repoW, author: author)

        let store = SnapshotStore(url: snapURL)
        let countA = CountingBackend(LocalFileBackend(root: root))
        let repoA = SpaceRepository(backend: countA, identity: author, spaceID: "s1")
        let engineA = SyncEngine(repo: repoA, clock: HLCClock(nodeID: author.authorID),
                                 identity: author, snapshotStore: store)
        await engineA.restoreSnapshot()
        await engineA.sync()                      // first run: must read the 8 files
        await engineA.stopPolling()               // persists the snapshot
        let getsA = await countA.eventGets
        XCTAssertEqual(getsA, 8)

        // Fresh engine, same snapshot: restore + sync downloads zero events.
        let countB = CountingBackend(LocalFileBackend(root: root))
        let repoB = SpaceRepository(backend: countB, identity: author, spaceID: "s1")
        let engineB = SyncEngine(repo: repoB, clock: HLCClock(nodeID: author.authorID),
                                 identity: author, snapshotStore: store)
        await engineB.restoreSnapshot()
        let p0 = await engineB.projection
        XCTAssertEqual(p0.topics.count, 8)        // painted instantly from cache
        await engineB.sync()
        let getsB = await countB.eventGets
        XCTAssertEqual(getsB, 0)                  // no redundant re-download
        let pB = await engineB.projection
        XCTAssertEqual(pB.topics.count, 8)
    }

    /// Windowed sync fetches only the newest N events up front; the rest
    /// backfill over subsequent rounds and the projection still converges.
    func testWindowedSyncBackfillsNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flark-win-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let author = DeviceIdentity.generate()
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1")
        try await repoW.bootstrap(spaceName: "T")
        try await seedTopics(12, into: repoW, author: author)

        let count = CountingBackend(LocalFileBackend(root: root))
        let repo = SpaceRepository(backend: count, identity: author, spaceID: "s1")
        let engine = SyncEngine(repo: repo, clock: HLCClock(nodeID: author.authorID),
                                identity: author)

        await engine.sync(maxNewEvents: 5)        // newest 5 only
        let p1 = await engine.projection
        XCTAssertEqual(p1.topics.count, 5)
        let gets1 = await count.eventGets
        XCTAssertEqual(gets1, 5)
        let hasMore = await engine.hasUnsyncedHistory
        XCTAssertTrue(hasMore)
        // Newest-first: t11..t7 (highest HLC) loaded before older ones.
        XCTAssertNotNil(p1.topics["t11"])
        XCTAssertNil(p1.topics["t0"])

        var guardRounds = 0
        while await engine.hasUnsyncedHistory, guardRounds < 10 {
            await engine.loadOlder(5)
            guardRounds += 1
        }
        let pN = await engine.projection
        XCTAssertEqual(pN.topics.count, 12)       // fully converged
        let getsN = await count.eventGets
        XCTAssertEqual(getsN, 12)                 // each event fetched exactly once
    }

    /// Sealing packs the author's oldest singles into one immutable segment
    /// and deletes them, so a fresh device folds the whole history from a
    /// handful of files instead of thousands — and still converges exactly.
    func testSealingCollapsesHistoryAndConverges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flark-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // `author` writes the history; `viewer` is a different identity that
        // only reads it. Sealing is per-own-author, so the viewer engines
        // never auto-seal `author`'s dir — keeping GET counts deterministic
        // while we drive sealing explicitly via `repoW`.
        let author = DeviceIdentity.generate()
        let viewer = DeviceIdentity.generate()
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1")
        try await repoW.bootstrap(spaceName: "T")
        try await seedTopics(250, into: repoW, author: author)

        // A viewer engine that folds all 250 singles before sealing.
        let snapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapURL) }
        let store = SnapshotStore(url: snapURL)
        let count = CountingBackend(LocalFileBackend(root: root))
        let repo = SpaceRepository(backend: count, identity: viewer, spaceID: "s1")
        let engine = SyncEngine(repo: repo, clock: HLCClock(nodeID: viewer.authorID),
                                identity: viewer, snapshotStore: store)
        await engine.sync()
        let g1 = await count.eventGets
        XCTAssertEqual(g1, 250)                   // folded every single once

        // One call seals exactly one batch (oldest 100, HLC order).
        let firstSealed = try await repoW.sealOwnHistory()
        XCTAssertEqual(firstSealed, SpaceRepository.segmentBatchSize)  // 100

        // Drain the rest: 250 → two 100-event segments + 50 loose singles
        // (< a batch, so they stay loose by design).
        while try await repoW.sealOwnHistory() > 0 {}
        let dir = "s1/events/\(author.authorID)"
        let after = try await LocalFileBackend(root: root).list(dir)
            .filter { !$0.isDirectory }
        XCTAssertEqual(after.filter { SpaceRepository.isSegment($0.path) }.count, 2)
        XCTAssertEqual(after.filter { !SpaceRepository.isSegment($0.path) }.count, 50)

        // Idempotent: < a batch left, nothing more to seal.
        let leftover = try await repoW.sealOwnHistory()
        XCTAssertEqual(leftover, 0)

        // Next sync: folds the 2 new segments (re-fold is idempotent) and
        // reclaims the 200 now-dead single paths from knownEventPaths.
        await engine.sync()
        let p = await engine.projection
        XCTAssertEqual(p.topics.count, 250)       // still exactly converged
        let g2 = await count.eventGets
        XCTAssertEqual(g2 - g1, 2)                // only the 2 new segment GETs
        await engine.stopPolling()                // persists the snapshot
        XCTAssertEqual(store.load()?.knownEventPaths.count, 52)  // 2 segs + 50

        // A truly fresh device (no snapshot) folds all 250 from 2 segs + 50
        // singles — far fewer GETs than one-file-per-event would need.
        let coldCount = CountingBackend(LocalFileBackend(root: root))
        let coldRepo = SpaceRepository(backend: coldCount, identity: viewer, spaceID: "s1")
        let cold = SyncEngine(repo: coldRepo, clock: HLCClock(nodeID: viewer.authorID),
                              identity: viewer)
        while await cold.hasUnsyncedHistory { await cold.sync() }
        await cold.sync()
        let coldP = await cold.projection
        XCTAssertEqual(coldP.topics.count, 250)
        let coldGets = await coldCount.eventGets
        XCTAssertEqual(coldGets, 52)              // 2 segments + 50 singles
    }

    func testPropfindParserExtractsEntries() {
        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/flark/events/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
        </d:prop></d:propstat></d:response>
        <d:response><d:href>/flark/events/abc/001.json</d:href>
        <d:propstat><d:prop><d:resourcetype/><d:getetag>"v1"</d:getetag>
        </d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = PropfindParser.parse(Data(xml.utf8),
                                           base: URL(string: "https://h/flark/")!,
                                           requested: "events")
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("001.json") && !$0.isDirectory })
    }
}
