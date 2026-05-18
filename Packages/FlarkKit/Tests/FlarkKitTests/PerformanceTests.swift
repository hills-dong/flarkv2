import XCTest
@testable import FlarkKit

/// Sanity-scale benchmarks. Not wall-clock assertions (CI varies) — they exist
/// to catch O(n)→O(n²) regressions and to compare the trusted vs verified fold
/// and snapshot-restore vs rebuild. XCTest allows one `measure` per method, so
/// each comparison is its own test; read the logged averages side by side.
/// Times are Debug builds (no optimization) — Release is far faster.
final class PerformanceTests: XCTestCase {

    private static func corpus(topics: Int, repliesPer: Int) -> [Event] {
        let a = DeviceIdentity.generate()
        var ms: Int64 = 1_000
        let clock = HLCClock(nodeID: a.authorID, now: { ms })
        var events: [Event] = []
        events.reserveCapacity(topics * (1 + repliesPer))
        func sign(_ p: Event.Payload) -> Event {
            ms += 1
            var e = Event(hlc: clock.send(), authorID: a.authorID,
                          publicKey: a.publicKeyData, spaceID: "s1", payload: p)
            try? e.sign(with: a)
            return e
        }
        for t in 0..<topics {
            events.append(sign(.topicCreate(topicID: "t\(t)",
                                            body: ContentDocument(text: "body \(t)"))))
            for r in 0..<repliesPer {
                events.append(sign(.replyCreate(replyID: "t\(t)-r\(r)", topicID: "t\(t)",
                                                body: ContentDocument(text: "reply \(r)"))))
            }
        }
        return events
    }

    /// 5k topics + 5k replies. Compare against `testPerfTrustedFold` — the
    /// only difference is one vs two Ed25519 verifications per event.
    func testPerfVerifiedFold() {
        let events = Self.corpus(topics: 5_000, repliesPer: 1)
        measure {
            var p = Projection()
            MergeReducer.reduce(&p, events: events)
        }
    }

    func testPerfTrustedFold() {
        let events = Self.corpus(topics: 5_000, repliesPer: 1)
        measure {
            var p = Projection()
            MergeReducer.reduceTrusted(&p, events: events)
        }
    }

    /// The list hot path: must be O(n) with no per-call sort / body copy.
    func testPerfTopicRowsAccess() {
        let p = MergeReducer.build(from: Self.corpus(topics: 10_000, repliesPer: 0))
        XCTAssertEqual(p.topicRowsByRecency.count, 10_000)
        measure {
            for _ in 0..<200 { _ = p.topicRowsByRecency }
        }
    }

    /// Restore-from-snapshot vs rebuild-from-events at 10k topics. Compare the
    /// logged average against `testPerfRebuildFromEvents`.
    func testPerfSnapshotDecode() throws {
        let p = MergeReducer.build(from: Self.corpus(topics: 10_000, repliesPer: 1))
        let data = try JSONEncoder().encode(p)
        measure { _ = try? JSONDecoder().decode(Projection.self, from: data) }
    }

    func testPerfRebuildFromEvents() {
        let events = Self.corpus(topics: 10_000, repliesPer: 1)
        measure {
            var p = Projection()
            MergeReducer.reduceTrusted(&p, events: events)
        }
    }
}
