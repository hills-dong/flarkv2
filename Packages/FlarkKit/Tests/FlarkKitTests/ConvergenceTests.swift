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
        var e = signed(id, clock, .topicCreate(topicID: "t1", title: "Hi",
                                               body: ContentDocument(text: "yo")))
        XCTAssertTrue(e.isAuthentic())
        // tamper payload → signature invalid
        e.signature = Data(repeating: 0, count: e.signature.count)
        XCTAssertFalse(e.isAuthentic())
        // impersonation: claim someone else's id with our key
        var imp = Event(hlc: clock.send(), authorID: "someone-else",
                        publicKey: id.publicKeyData, spaceID: "s1",
                        payload: .topicCreate(topicID: "t2", title: "x",
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

        let e1 = signed(dongID, dc, .topicCreate(topicID: "t1", title: "Release",
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
            XCTAssertEqual(p.topics["t1"]?.title, "Release")
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

    func testIdempotentReapply() {
        let id = DeviceIdentity.generate()
        let clock = HLCClock(nodeID: id.authorID)
        let e = signed(id, clock, .topicCreate(topicID: "t1", title: "x",
                                               body: ContentDocument(text: "x")))
        var p = Projection()
        MergeReducer.reduce(&p, events: [e])
        MergeReducer.reduce(&p, events: [e, e]) // duplicates / re-delivery
        XCTAssertEqual(p.topics.count, 1)
    }
}
