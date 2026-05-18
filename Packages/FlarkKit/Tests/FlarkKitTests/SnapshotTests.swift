import XCTest
@testable import FlarkKit

/// The snapshot is a cache that must round-trip to a projection identical to
/// one freshly folded from the event log, and be safely rejected when stale.
final class SnapshotTests: XCTestCase {

    private func signed(_ id: DeviceIdentity, _ clock: HLCClock,
                        _ payload: Event.Payload) -> Event {
        var e = Event(hlc: clock.send(), authorID: id.authorID,
                      publicKey: id.publicKeyData, spaceID: "s1", payload: payload)
        try? e.sign(with: id)
        return e
    }

    private func sampleProjection() -> Projection {
        let a = DeviceIdentity.generate()
        let b = DeviceIdentity.generate()
        let ca = HLCClock(nodeID: a.authorID, now: { 1_000 })
        let cb = HLCClock(nodeID: b.authorID, now: { 1_001 })
        let events = [
            signed(a, ca, .topicCreate(topicID: "t1",
                                       body: ContentDocument(text: "ship 22:00"))),
            signed(a, ca, .topicCreate(topicID: "t2",
                                       body: ContentDocument(segments: [.text("food "), .emoji(id: "u_pizza")]))),
            signed(b, cb, .replyCreate(replyID: "r1", topicID: "t1",
                                       body: ContentDocument(text: "on it"))),
            signed(a, ca, .reactionSet(targetID: "t1", targetType: .topic,
                                       emojiID: "u_fire", removed: false)),
            signed(b, cb, .reactionSet(targetID: "r1", targetType: .reply,
                                       emojiID: "u_thumbsup", removed: false)),
        ]
        return MergeReducer.build(from: events)
    }

    private func assertEqual(_ p: Projection, _ q: Projection,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.topics, q.topics, file: file, line: line)
        XCTAssertEqual(p.profiles, q.profiles, file: file, line: line)
        XCTAssertEqual(p.appliedEventIDs, q.appliedEventIDs, file: file, line: line)
        XCTAssertEqual(p.topicRowsByRecency, q.topicRowsByRecency, file: file, line: line)
        for id in p.topics.keys {
            XCTAssertEqual(p.replies(forTopic: id).map(\.id),
                           q.replies(forTopic: id).map(\.id), file: file, line: line)
            XCTAssertEqual(p.tallies(forTarget: id), q.tallies(forTarget: id),
                           file: file, line: line)
        }
        XCTAssertEqual(p.tallies(forTarget: "r1"), q.tallies(forTarget: "r1"),
                       file: file, line: line)
    }

    func testProjectionCodableRoundTrip() throws {
        let p = sampleProjection()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Projection.self, from: data)
        assertEqual(p, decoded)
        // Reactions survive the dict↔array transform.
        XCTAssertEqual(decoded.tallies(forTarget: "t1").first?.emojiID, "u_fire")
        XCTAssertTrue(decoded.hasReacted(author: p.tallies(forTarget: "r1").first!.authorIDs.first!,
                                         target: "r1", emoji: "u_thumbsup"))
    }

    func testSnapshotStoreRoundTripAndContinuedFold() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SnapshotStore(url: url)

        let p = sampleProjection()
        store.save(ProjectionSnapshot(knownEventPaths: ["s1/events/x/1.json"],
                                      maxHLC: HLC(wallMillis: 1, counter: 0, nodeID: "x"),
                                      projection: p))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.knownEventPaths, ["s1/events/x/1.json"])
        assertEqual(p, loaded.projection)

        // A restored projection can keep folding new events identically.
        let a = DeviceIdentity.generate()
        let extra = signed(a, HLCClock(nodeID: a.authorID, now: { 9_000 }),
                           .replyCreate(replyID: "r2", topicID: "t1",
                                        body: ContentDocument(text: "later")))
        var fromSnap = loaded.projection
        MergeReducer.reduce(&fromSnap, events: [extra])
        var fromScratch = p
        MergeReducer.reduce(&fromScratch, events: [extra])
        assertEqual(fromSnap, fromScratch)
        XCTAssertEqual(fromSnap.topics["t1"]?.replyCount, 2)
    }

    func testIncompatibleOrCorruptSnapshotRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SnapshotStore(url: url)

        XCTAssertNil(store.load())                                  // absent

        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(store.load())                                  // corrupt

        // Tamper the reducer fingerprint → must be treated as absent.
        var snap = ProjectionSnapshot(knownEventPaths: [], maxHLC: nil,
                                      projection: sampleProjection())
        snap.reducerFingerprint = "stale-fingerprint"
        try JSONEncoder().encode(snap).write(to: url)
        XCTAssertFalse(snap.isCompatible)
        XCTAssertNil(store.load())
    }
}
