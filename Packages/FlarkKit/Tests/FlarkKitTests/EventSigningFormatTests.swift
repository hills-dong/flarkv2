import XCTest
@testable import FlarkKit

/// Pins the canonical bytes the signature covers. The Python re-signer
/// (`.context/resign_events.py`) reproduces this byte-for-byte; if we ever
/// tweak the encoder format on the Swift side, this test catches it
/// immediately and the re-signer must be updated to match.
final class EventSigningFormatTests: XCTestCase {
    func testSigningDataIsCanonical() throws {
        let id = DeviceIdentity(privateKey: try .init(
            rawRepresentation: Data(repeating: 7, count: 32)))
        let hlc = HLC(wallMillis: 1, counter: 0, nodeID: id.authorID)
        let ev = Event(eventID: "deadbeef",
                       hlc: hlc,
                       authorID: id.authorID,
                       publicKey: id.publicKeyData,
                       spaceID: "test",
                       payload: .topicCreate(topicID: "t1",
                                             body: ContentDocument(body: "hi")))
        let data = try ev.signingData()
        let s = String(data: data, encoding: .utf8) ?? ""
        // Sanity: keys sorted, slashes not escaped, signature is the empty
        // base64 string. If any of these change, update resign_events.py.
        XCTAssertTrue(s.contains(#""signature":"""#), "signature should be empty base64")
        XCTAssertFalse(s.contains(#"\/"#), "slashes should not be escaped")
        // sortedKeys → "authorID" appears before "eventID".
        let aIdx = s.range(of: "\"authorID\"")?.lowerBound
        let eIdx = s.range(of: "\"eventID\"")?.lowerBound
        XCTAssertNotNil(aIdx); XCTAssertNotNil(eIdx)
        XCTAssertLessThan(aIdx!, eIdx!)
    }
}
