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
        let t = await engineA.makeEvent(.topicCreate(topicID: "t1", title: "Release", body: doc),
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
        XCTAssertEqual(pA.topics["t1"]?.title, "Release")
        XCTAssertEqual(pA.topics["t1"]?.replyCount, 1)
        XCTAssertEqual(pA.replies(forTopic: "t1").first?.id, "r1")
        XCTAssertEqual(pA.tallies(forTarget: "t1").first?.emojiID, "u_fire")
        XCTAssertEqual(pA.topics["t1"]?.title, pB.topics["t1"]?.title)
        XCTAssertEqual(pA.replies(forTopic: "t1").count, pB.replies(forTopic: "t1").count)

        // The content-addressed blob is retrievable by the other device.
        let fetched = try await repoB.getBlob(blob)
        XCTAssertEqual(String(data: fetched, encoding: .utf8), "png-bytes")
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
