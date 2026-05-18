import XCTest
@testable import FlarkKit

final class ConvergenceTests: XCTestCase {

    private func signed(_ id: DeviceIdentity, _ clock: HLCClock,
                        _ payload: Event.Payload, space: String = "s1") -> Event {
        var e = Event(hlc: clock.send(), authorID: id.authorID,
                      publicKey: id.publicKeyData, spaceID: space, payload: payload)
        try? e.sign(with: id)
        return e
    }

    func testHLCTotalOrderAndStringSortable() {
        let c = HLCClock(nodeID: "node1", now: { 1000 })
        let a = c.send(), b = c.send()
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(a.description, b.description) // string order == logical order
    }

    func testSignatureRejectsTamperAndImpersonation() {
        let id = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: id.authorID)
        var e = signed(id, clock, .topicCreate(topicID: "t1",
                                               body: ContentDocument(text: "yo")))
        XCTAssertTrue(e.isAuthentic())
        // tamper payload → signature invalid
        e.signature = Data(repeating: 0, count: e.signature.count)
        XCTAssertFalse(e.isAuthentic())
        // impersonation: claim someone else's id with our key
        var imp = Event(hlc: clock.send(), authorID: "someone-else",
                        publicKey: id.publicKeyData, spaceID: "s1",
                        payload: .topicCreate(topicID: "t2",
                                              body: ContentDocument(text: "x")))
        try? imp.sign(with: id)
        XCTAssertFalse(imp.isAuthentic())
    }

    /// Two devices create topics/replies and react concurrently. Applying the
    /// event sets in opposite orders must yield identical projections.
    func testOrderIndependentConvergence() {
        let dongID = DeviceIdentity.generate()
        let zhangID = DeviceIdentity.generate()
        let dc = HLCClock(nodeID: dongID.authorID, now: { 1_000 })
        let zc = HLCClock(nodeID: zhangID.authorID, now: { 1_001 })

        let e1 = signed(dongID, dc, .topicCreate(topicID: "t1",
                                                 body: ContentDocument(text: "ship 22:00")))
        let e2 = signed(zhangID, zc, .replyCreate(replyID: "r1", topicID: "t1",
                                                  body: ContentDocument(text: "coming")))
        let e3 = signed(dongID, dc, .reactionSet(targetID: "t1", targetType: .topic,
                                                 emojiID: "u_thumbsup", removed: false))
        let e4 = signed(zhangID, zc, .reactionSet(targetID: "t1", targetType: .topic,
                                                  emojiID: "u_thumbsup", removed: false))
        // Dong toggles his reaction off later (higher HLC) — LWW must win.
        let e5 = signed(dongID, dc, .reactionSet(targetID: "t1", targetType: .topic,
                                                 emojiID: "u_thumbsup", removed: true))

        let pA = MergeReducer.build(from: [e1, e2, e3, e4, e5])
        let pB = MergeReducer.build(from: [e5, e4, e3, e2, e1]) // reverse
        let pC = MergeReducer.build(from: [e3, e1, e5, e2, e4]) // shuffled

        for p in [pA, pB, pC] {
            XCTAssertEqual(p.topics["t1"]?.body.plainText, "ship 22:00")
            XCTAssertEqual(p.topics["t1"]?.replyCount, 1)
            XCTAssertEqual(p.replies(forTopic: "t1").map(\.id), ["r1"])
            let tally = p.tallies(forTarget: "t1").first { $0.emojiID == "u_thumbsup" }
            // zhang still reacted (1); dong removed his → count 1
            XCTAssertEqual(tally?.count, 1)
            XCTAssertEqual(tally?.authorIDs, [zhangID.authorID])
            XCTAssertFalse(p.hasReacted(author: dongID.authorID, target: "t1", emoji: "u_thumbsup"))
        }
        XCTAssertEqual(pA.topics.count, pB.topics.count)
    }

    /// `reduceTrusted` skips verification but must produce the exact same
    /// projection as `reduce` for authentic input, and stay idempotent.
    func testReduceTrustedEqualsReduceAndIdempotent() {
        let id = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: id.authorID)
        let e1 = signed(id, clock, .topicCreate(topicID: "t1",
                                                body: ContentDocument(text: "hello")))
        let e2 = signed(id, clock, .replyCreate(replyID: "r1", topicID: "t1",
                                                body: ContentDocument(text: "hi")))
        let e3 = signed(id, clock, .reactionSet(targetID: "t1", targetType: .topic,
                                                emojiID: "u_thumbsup", removed: false))

        var pVerified = Projection()
        MergeReducer.reduce(&pVerified, events: [e1, e2, e3])

        var pTrusted = Projection()
        MergeReducer.reduceTrusted(&pTrusted, events: [e1, e2, e3])
        MergeReducer.reduceTrusted(&pTrusted, events: [e1, e2, e3])   // re-delivery

        XCTAssertEqual(pTrusted.topics, pVerified.topics)
        XCTAssertEqual(pTrusted.topicRowsByRecency, pVerified.topicRowsByRecency)
        XCTAssertEqual(pTrusted.replies(forTopic: "t1").map(\.id),
                       pVerified.replies(forTopic: "t1").map(\.id))
        XCTAssertEqual(pTrusted.topics["t1"]?.replyCount, 1)
        XCTAssertEqual(pTrusted.tallies(forTarget: "t1"), pVerified.tallies(forTarget: "t1"))
    }

    /// The new indices (topicRowsByRecency, reply buckets) must be a pure
    /// function of the event set — identical regardless of apply order.
    func testIndicesAreOrderIndependent() {
        let a = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: a.authorID, now: { 5_000 })
        let t1 = signed(a, clock, .topicCreate(topicID: "t1",
                                               body: ContentDocument(text: "x")))
        let t2 = signed(a, clock, .topicCreate(topicID: "t2",
                                               body: ContentDocument(text: "y")))
        let r1 = signed(a, clock, .replyCreate(replyID: "r1", topicID: "t1",
                                               body: ContentDocument(text: "a")))
        let r2 = signed(a, clock, .replyCreate(replyID: "r2", topicID: "t1",
                                               body: ContentDocument(text: "b")))
        let r3 = signed(a, clock, .replyCreate(replyID: "r3", topicID: "t2",
                                               body: ContentDocument(text: "c")))

        let fwd = MergeReducer.build(from: [t1, t2, r1, r2, r3])
        let rev = MergeReducer.build(from: [r3, r2, r1, t2, t1])
        let shuf = MergeReducer.build(from: [r2, t2, r3, t1, r1])

        for p in [fwd, rev, shuf] {
            // t1 last reply r2 → t1 most recent; ordering deterministic.
            XCTAssertEqual(p.topicRowsByRecency.map(\.id), fwd.topicRowsByRecency.map(\.id))
            XCTAssertEqual(p.replies(forTopic: "t1").map(\.id), ["r1", "r2"])
            XCTAssertEqual(p.replies(forTopic: "t2").map(\.id), ["r3"])
            XCTAssertEqual(p.topics["t1"]?.replyCount, 2)
            XCTAssertEqual(p.topics["t2"]?.replyCount, 1)
        }
    }

    /// PR5 windowing folds newer replies BEFORE the older topic-create. The
    /// reducer derives aggregates from the bucket, so it must still converge.
    func testRepliesFoldedBeforeTopicStillConverge() {
        let a = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: a.authorID)
        let topic = signed(a, clock, .topicCreate(topicID: "t1",
                                                  body: ContentDocument(text: "x")))
        let rep1 = signed(a, clock, .replyCreate(replyID: "r1", topicID: "t1",
                                                 body: ContentDocument(text: "1")))
        let rep2 = signed(a, clock, .replyCreate(replyID: "r2", topicID: "t1",
                                                 body: ContentDocument(text: "2")))
        // Window 1: only the two (newer) replies. Window 2: the (older) topic.
        var p = Projection()
        MergeReducer.reduceTrusted(&p, events: [rep1, rep2])
        XCTAssertNil(p.topics["t1"])                        // topic not folded yet
        MergeReducer.reduceTrusted(&p, events: [topic])
        XCTAssertEqual(p.topics["t1"]?.replyCount, 2)        // derived, not missed
        XCTAssertEqual(p.replies(forTopic: "t1").map(\.id), ["r1", "r2"])
        XCTAssertEqual(p.topicRowsByRecency.first?.id, "t1")
    }

    func testIdempotentReapply() {
        let id = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: id.authorID)
        let e = signed(id, clock, .topicCreate(topicID: "t1",
                                               body: ContentDocument(text: "x")))
        var p = Projection()
        MergeReducer.reduce(&p, events: [e])
        MergeReducer.reduce(&p, events: [e, e]) // duplicates / re-delivery
        XCTAssertEqual(p.topics.count, 1)
    }
}
