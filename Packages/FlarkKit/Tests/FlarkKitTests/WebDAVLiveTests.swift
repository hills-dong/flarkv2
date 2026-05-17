import XCTest
@testable import FlarkKit

/// Live WebDAV smoke. Skipped unless env vars are set so no credentials live
/// in the repo and normal CI never hits the network:
///   FLARK_DAV_URL  FLARK_DAV_USER  FLARK_DAV_PASS
final class WebDAVLiveTests: XCTestCase {

    private var creds: (URL, String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["FLARK_DAV_URL"], let url = URL(string: u),
              let user = e["FLARK_DAV_USER"], let pass = e["FLARK_DAV_PASS"]
        else { return nil }
        return (url, user, pass)
    }

    func testLiveWebDAVRoundTripAndConcurrency() async throws {
        guard let (url, user, pass) = creds else {
            throw XCTSkip("Set FLARK_DAV_* env vars to run the live WebDAV smoke")
        }
        let backend = WebDAVBackend(baseURL: url, username: user, password: pass)
        let dong = DeviceIdentity.generate()
        let zhang = DeviceIdentity.generate()
        // Unique sub-space per run so reruns don't collide.
        let spaceID = "smoke-\(Int(Date().timeIntervalSince1970))"
        let repoA = SpaceRepository(backend: backend, identity: dong, spaceID: spaceID)
        let repoB = SpaceRepository(backend: backend, identity: zhang, spaceID: spaceID)

        // NOTE: real Space root would be its own WebDAV dir; here we just
        // exercise the protocol against the configured test directory.
        try await repoA.bootstrap(spaceName: "Smoke")

        // Content-addressed blob: create-only, dedupe must not error on repeat.
        let blob = try await repoA.putBlob(Data("hello-webdav".utf8))
        let blobAgain = try await repoA.putBlob(Data("hello-webdav".utf8))
        XCTAssertEqual(blob, blobAgain)
        let fetched = try await repoB.getBlob(blob)
        XCTAssertEqual(String(data: fetched, encoding: .utf8), "hello-webdav")

        let engineA = SyncEngine(repo: repoA, clock: HLCClock(nodeID: dong.authorID),
                                 identity: dong)
        let engineB = SyncEngine(repo: repoB, clock: HLCClock(nodeID: zhang.authorID),
                                 identity: zhang)

        let t = await engineA.makeEvent(
            .topicCreate(topicID: "t1", title: "Live", body: ContentDocument(text: "via WebDAV")),
            authorID: dong.authorID, publicKey: dong.publicKeyData)
        await engineA.submit(t)
        await engineA.flush()

        // Second device pulls it back through PROPFIND + GET.
        await engineB.sync()
        let pB = await engineB.projection
        XCTAssertEqual(pB.topics["t1"]?.title, "Live")

        // Concurrent: both react to the same target from different author
        // dirs — unique filenames mean no write-write conflict.
        let rA = await engineA.makeEvent(.reactionSet(targetID: "t1", targetType: .topic,
                                                      emojiID: "u_fire", removed: false),
                                         authorID: dong.authorID, publicKey: dong.publicKeyData)
        let rB = await engineB.makeEvent(.reactionSet(targetID: "t1", targetType: .topic,
                                                      emojiID: "u_fire", removed: false),
                                         authorID: zhang.authorID, publicKey: zhang.publicKeyData)
        await engineA.submit(rA); await engineB.submit(rB)
        await engineA.flush(); await engineB.flush()
        await engineA.sync(); await engineB.sync()

        let finalA = await engineA.projection
        let finalB = await engineB.projection
        XCTAssertEqual(finalA.tallies(forTarget: "t1").first { $0.emojiID == "u_fire" }?.count, 2)
        XCTAssertEqual(finalA.tallies(forTarget: "t1").first?.count,
                       finalB.tallies(forTarget: "t1").first?.count) // converged
    }
}
