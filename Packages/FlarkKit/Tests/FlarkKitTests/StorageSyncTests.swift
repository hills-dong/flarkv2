import XCTest
@testable import FlarkKit

/// Two independent devices pointed at the SAME local directory (the "no
/// server, shared folder" scenario) must converge through the event log.
final class StorageSyncTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flark-\(tag)-\(UUID().uuidString)")
    }

    func testTwoDevicesConvergeViaSharedFolder() async throws {
        let root = tempURL("backend")
        let outboxA = tempURL("outboxA")
        let outboxB = tempURL("outboxB")
        defer { for u in [root, outboxA, outboxB] {
            try? FileManager.default.removeItem(at: u)
        } }

        let backendA = LocalFileBackend(root: root)
        let backendB = LocalFileBackend(root: root)   // same folder, other device
        let dong = DeviceIdentity.generate()
        let zhang = DeviceIdentity.generate()

        let repoA = SpaceRepository(backend: backendA, identity: dong, spaceID: "s1",
                                    deviceID: "dev-dong", outboxRoot: outboxA)
        let repoB = SpaceRepository(backend: backendB, identity: zhang, spaceID: "s1",
                                    deviceID: "dev-zhang", outboxRoot: outboxB)
        let engineA = SyncEngine(repo: repoA, clock: HLCClock(nodeID: dong.authorID),
                                 identity: dong)
        let engineB = SyncEngine(repo: repoB, clock: HLCClock(nodeID: zhang.authorID),
                                 identity: zhang)
        try await repoA.bootstrap(spaceName: "Team")

        // Dong posts a topic with an inline blob; Zhang replies + reacts.
        let blob = try await repoA.putBlob(Data("png-bytes".utf8))
        let doc = ContentDocument(body: "ship \n![](blob://\(blob))")
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

    /// Wraps a backend and counts event-file GETs (both unconditional and
    /// conditional-with-body) so tests can prove conditional-GET / etag
    /// caching actually skips the redundant downloads.
    actor CountingBackend: StorageBackend {
        let wrapped: StorageBackend
        private(set) var eventBodyGets = 0   // returned a body (200)
        private(set) var event304s = 0       // conditional GET returned nil
        private(set) var profileBodyGets = 0
        init(_ w: StorageBackend) { wrapped = w }
        func list(_ d: String) async throws -> [StorageEntry] { try await wrapped.list(d) }
        func get(_ p: String) async throws -> (data: Data, etag: String?) {
            if p.contains("/events/") { eventBodyGets += 1 }
            if p.contains("/profiles/") { profileBodyGets += 1 }
            return try await wrapped.get(p)
        }
        func get(_ p: String, ifNoneMatch knownEtag: String?) async throws -> (data: Data, etag: String?)? {
            let r = try await wrapped.get(p, ifNoneMatch: knownEtag)
            if p.contains("/events/") {
                if r == nil { event304s += 1 } else { eventBodyGets += 1 }
            }
            return r
        }
        func put(_ p: String, data: Data, precondition: WritePrecondition) async throws {
            try await wrapped.put(p, data: data, precondition: precondition)
        }
        func makeDirectory(_ p: String) async throws { try await wrapped.makeDirectory(p) }
        func exists(_ p: String) async throws -> Bool { try await wrapped.exists(p) }
        func delete(_ p: String) async throws { try await wrapped.delete(p) }
    }

    /// Write `n` topic-create events through the repository so they land in
    /// the new layout (active file, rotates as configured) instead of going
    /// through the engine's pendingEvents queue.
    private func seedTopics(_ n: Int, into repo: SpaceRepository,
                            author: DeviceIdentity) async throws {
        var ms: Int64 = 1_000
        let clock = HLCClock(nodeID: author.authorID, now: { ms })
        for i in 0..<n {
            ms += 1                                   // strictly newer each time
            let e = Event(hlc: clock.send(), authorID: author.authorID,
                          publicKey: author.publicKeyData, spaceID: "s1",
                          payload: .topicCreate(topicID: "t\(i)",
                                                body: ContentDocument(text: "x")))
            // `append` signs internally, so no need to pre-sign here.
            try await repo.append(e)
        }
    }

    /// A new device restoring a snapshot must not re-fetch event-file bodies
    /// it has already folded — conditional GET on each unchanged path comes
    /// back as 304 so steady-state polling never re-downloads sealed history.
    func testSnapshotSkipsUnchangedFiles() async throws {
        let root = tempURL("snap")
        let outbox = tempURL("snap-outbox")
        let snapURL = tempURL("snap-cache").appendingPathExtension("json")
        defer { for u in [root, outbox, snapURL] {
            try? FileManager.default.removeItem(at: u)
        } }

        let author = DeviceIdentity.generate()
        // Rotate every 3 events so 8 topics produce 3 files (seq 1: 3, seq 2:
        // 3, seq 3: 2). Multiple files exercise the per-path etag map and
        // make the assertion robust against any single-file edge case.
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1",
                                    deviceID: "dev-w", outboxRoot: outbox,
                                    rotationEventCount: 3)
        try await repoW.bootstrap(spaceName: "T")
        try await seedTopics(8, into: repoW, author: author)

        let store = SnapshotStore(url: snapURL)
        let countA = CountingBackend(LocalFileBackend(root: root))
        let repoA = SpaceRepository(backend: countA, identity: author, spaceID: "s1",
                                    deviceID: "dev-a-reader", outboxRoot: tempURL("readerA"))
        let engineA = SyncEngine(repo: repoA, clock: HLCClock(nodeID: author.authorID),
                                 identity: author, snapshotStore: store)
        await engineA.restoreSnapshot()
        await engineA.sync()                      // first run: must read every file
        await engineA.shutdown()                  // drains + persists the snapshot
        let bodiesA = await countA.eventBodyGets
        XCTAssertEqual(bodiesA, 3)                // 3 files, one body per file

        // Fresh engine, same snapshot: restore + sync downloads zero bodies;
        // conditional GET returns 304 for every still-current file.
        let countB = CountingBackend(LocalFileBackend(root: root))
        let repoB = SpaceRepository(backend: countB, identity: author, spaceID: "s1",
                                    deviceID: "dev-b-reader", outboxRoot: tempURL("readerB"))
        let engineB = SyncEngine(repo: repoB, clock: HLCClock(nodeID: author.authorID),
                                 identity: author, snapshotStore: store)
        await engineB.restoreSnapshot()
        let p0 = await engineB.projection
        XCTAssertEqual(p0.topics.count, 8)        // painted instantly from cache
        await engineB.sync()
        let bodiesB = await countB.eventBodyGets
        XCTAssertEqual(bodiesB, 0)                // no body re-downloaded
        let pB = await engineB.projection
        XCTAssertEqual(pB.topics.count, 8)
    }

    /// Profile files are tiny but get re-fetched on every sync round in v1 —
    /// once their listing-etag is cached, subsequent rounds must skip the GET
    /// entirely (no `If-None-Match` either, just trust the PROPFIND etag).
    func testProfileEtagSkipsRedundantGets() async throws {
        let root = tempURL("prof")
        let outbox = tempURL("prof-outbox")
        defer { for u in [root, outbox] {
            try? FileManager.default.removeItem(at: u)
        } }
        let author = DeviceIdentity.generate()
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1",
                                    deviceID: "dev-w", outboxRoot: outbox)
        try await repoW.bootstrap(spaceName: "T")
        try await repoW.writeProfile(displayName: "Alice", avatarBlobID: nil)

        let count = CountingBackend(LocalFileBackend(root: root))
        let reader = DeviceIdentity.generate()
        let repoR = SpaceRepository(backend: count, identity: reader, spaceID: "s1",
                                    deviceID: "dev-r", outboxRoot: tempURL("readerR"))
        let engine = SyncEngine(repo: repoR, clock: HLCClock(nodeID: reader.authorID),
                                identity: reader)
        await engine.sync()                       // first round: 1 GET for the profile
        var n = await count.profileBodyGets
        XCTAssertEqual(n, 1)
        await engine.sync()                       // second round: etag matches, 0 GETs
        n = await count.profileBodyGets
        XCTAssertEqual(n, 1)

        // Mutating the profile bumps its mtime → etag changes → re-fetch.
        try await repoW.writeProfile(displayName: "Alice II", avatarBlobID: nil)
        await engine.sync()
        n = await count.profileBodyGets
        XCTAssertEqual(n, 2)
        let p = await engine.projection
        XCTAssertEqual(p.profiles[author.authorID]?.displayName, "Alice II")
    }

    /// Windowed sync fetches only the newest N files up front; the rest
    /// backfill over subsequent rounds and the projection still converges.
    func testWindowedSyncBackfillsNewestFirst() async throws {
        let root = tempURL("win")
        let outbox = tempURL("win-outbox")
        defer { try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outbox) }

        let author = DeviceIdentity.generate()
        // Tiny rotation cap → 12 topics ⇒ 12 files (one per event) so the
        // window cap of 5 unambiguously caps file fetches.
        let repoW = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: author, spaceID: "s1",
                                    deviceID: "dev-w", outboxRoot: outbox,
                                    rotationEventCount: 1)
        try await repoW.bootstrap(spaceName: "T")
        try await seedTopics(12, into: repoW, author: author)

        let count = CountingBackend(LocalFileBackend(root: root))
        let repo = SpaceRepository(backend: count, identity: author, spaceID: "s1",
                                   deviceID: "dev-reader", outboxRoot: tempURL("reader"))
        let engine = SyncEngine(repo: repo, clock: HLCClock(nodeID: author.authorID),
                                identity: author)

        await engine.sync(maxNewFiles: 5)         // newest 5 files only
        let p1 = await engine.projection
        XCTAssertEqual(p1.topics.count, 5)
        let bodies1 = await count.eventBodyGets
        XCTAssertEqual(bodies1, 5)
        let hasMore = await engine.hasUnsyncedHistory
        XCTAssertTrue(hasMore)
        // Newest-first: t11..t7 (highest seq) loaded before older ones.
        XCTAssertNotNil(p1.topics["t11"])
        XCTAssertNil(p1.topics["t0"])

        var guardRounds = 0
        while await engine.hasUnsyncedHistory, guardRounds < 10 {
            await engine.loadOlder(5)
            guardRounds += 1
        }
        let pN = await engine.projection
        XCTAssertEqual(pN.topics.count, 12)       // fully converged
        let bodiesN = await count.eventBodyGets
        XCTAssertEqual(bodiesN, 12)               // each file fetched exactly once
    }

    /// The active file's seq advances once the configured event cap is hit;
    /// the old file remains immutable on the backend and is read once on
    /// cold-start (it never changes its etag again).
    func testActiveFileRotation() async throws {
        let root = tempURL("rot")
        let outbox = tempURL("rot-outbox")
        defer { try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outbox) }

        let author = DeviceIdentity.generate()
        let repo = SpaceRepository(backend: LocalFileBackend(root: root),
                                   identity: author, spaceID: "s1",
                                   deviceID: "dev-w", outboxRoot: outbox,
                                   rotationEventCount: 4)
        try await repo.bootstrap(spaceName: "T")
        try await seedTopics(10, into: repo, author: author)

        // Layout: rotation=4 → files 1 (4 events), 2 (4), 3 (2). Each file
        // lives at events/<authorID>/<deviceID>/<paddedSeq>.json.
        let listing = try await repo.listEventEntries().sorted { $0.path < $1.path }
        XCTAssertEqual(listing.count, 3)
        XCTAssertTrue(listing[0].path.hasSuffix("/00000001.json"))
        XCTAssertTrue(listing[1].path.hasSuffix("/00000002.json"))
        XCTAssertTrue(listing[2].path.hasSuffix("/00000003.json"))
        // The first two seqs are full, the third holds the leftover tail.
        let s1 = try await repo.loadEvents(at: listing[0].path)
        let s2 = try await repo.loadEvents(at: listing[1].path)
        let s3 = try await repo.loadEvents(at: listing[2].path)
        XCTAssertEqual(s1.count, 4)
        XCTAssertEqual(s2.count, 4)
        XCTAssertEqual(s3.count, 2)
    }

    /// Two physical devices that share an authorID (iCloud-Keychain identity
    /// sync) each write under their own deviceID subtree. The single-writer
    /// guarantee is per directory, so neither device ever stomps on the
    /// other's file — and the projection still merges to one state.
    func testSameAuthorMultipleDevicesConverge() async throws {
        let root = tempURL("multidev")
        let outboxA = tempURL("multidev-a")
        let outboxB = tempURL("multidev-b")
        defer { for u in [root, outboxA, outboxB] {
            try? FileManager.default.removeItem(at: u)
        } }

        let identity = DeviceIdentity.generate()   // same key on both "devices"
        let repoA = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: identity, spaceID: "s1",
                                    deviceID: "iphone", outboxRoot: outboxA)
        let repoB = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: identity, spaceID: "s1",
                                    deviceID: "ipad", outboxRoot: outboxB)
        try await repoA.bootstrap(spaceName: "T")

        let clockA = HLCClock(nodeID: identity.authorID, now: { 1_000 })
        let clockB = HLCClock(nodeID: identity.authorID, now: { 1_010 })
        let eA = Event(hlc: clockA.send(), authorID: identity.authorID,
                       publicKey: identity.publicKeyData, spaceID: "s1",
                       payload: .topicCreate(topicID: "from-iphone",
                                             body: ContentDocument(text: "a")))
        let eB = Event(hlc: clockB.send(), authorID: identity.authorID,
                       publicKey: identity.publicKeyData, spaceID: "s1",
                       payload: .topicCreate(topicID: "from-ipad",
                                             body: ContentDocument(text: "b")))
        try await repoA.append(eA)
        try await repoB.append(eB)

        // Listings see both subtrees side by side.
        let entries = try await repoA.listEventEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.path.contains("/iphone/") })
        XCTAssertTrue(entries.contains { $0.path.contains("/ipad/") })

        // A reader (third identity) folds both files into one Projection.
        let reader = DeviceIdentity.generate()
        let repoR = SpaceRepository(backend: LocalFileBackend(root: root),
                                    identity: reader, spaceID: "s1",
                                    deviceID: "reader-dev",
                                    outboxRoot: tempURL("reader"))
        let engine = SyncEngine(repo: repoR, clock: HLCClock(nodeID: reader.authorID),
                                identity: reader)
        await engine.sync()
        let p = await engine.projection
        XCTAssertNotNil(p.topics["from-iphone"])
        XCTAssertNotNil(p.topics["from-ipad"])
    }

    func testPropfindParserExtractsEntries() {
        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/flark/events/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
        </d:prop></d:propstat></d:response>
        <d:response><d:href>/flark/events/abc/dev1/00000001.json</d:href>
        <d:propstat><d:prop><d:resourcetype/><d:getetag>"v1"</d:getetag>
        </d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = PropfindParser.parse(Data(xml.utf8),
                                           base: URL(string: "https://h/flark/")!,
                                           requested: "events")
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("00000001.json") && !$0.isDirectory })
    }
}
