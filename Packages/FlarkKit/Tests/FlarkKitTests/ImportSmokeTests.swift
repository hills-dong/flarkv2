import XCTest
@testable import FlarkKit

/// Env-gated smoke test for a converted v1 → current Space dump. Skipped in
/// normal CI; set `FLARK_IMPORT_ROOT=/absolute/path/to/converted/space` to
/// point at a directory matching the on-disk layout this codebase writes
/// (events/<authorID>/<deviceID>/<seq>.json arrays). Verifies that every
/// event decodes, the signatures still authenticate, and the projection
/// folds into something non-empty.
final class ImportSmokeTests: XCTestCase {

    func testConvertedSpaceFoldsAndAuthenticates() async throws {
        let backend: StorageBackend
        let spaceID: String
        let env = ProcessInfo.processInfo.environment
        if let davURL = env["FLARK_IMPORT_DAV_URL"], let url = URL(string: davURL),
           let user = env["FLARK_IMPORT_DAV_USER"],
           let pass = env["FLARK_IMPORT_DAV_PASS"],
           let space = env["FLARK_IMPORT_DAV_SPACE"] {
            backend = WebDAVBackend(baseURL: url, username: user, password: pass)
            spaceID = space
        } else if let root = env["FLARK_IMPORT_ROOT"] {
            backend = LocalFileBackend(root: URL(fileURLWithPath: root, isDirectory: true))
            spaceID = ""
        } else {
            throw XCTSkip("Set FLARK_IMPORT_ROOT or FLARK_IMPORT_DAV_* env vars")
        }

        // For the local form the dump has no enclosing space-id directory (the
        // WebDAV root IS the space root), so spaceID = "" skips the P() prefix.
        let reader = DeviceIdentity.generate()
        let outbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outbox) }
        let repo = SpaceRepository(backend: backend, identity: reader, spaceID: spaceID,
                                   deviceID: "smoke-reader", outboxRoot: outbox)
        let engine = SyncEngine(repo: repo, clock: HLCClock(nodeID: reader.authorID),
                                identity: reader)

        let entries = try await repo.listEventEntries()
        print("listed \(entries.count) event files")
        XCTAssertGreaterThan(entries.count, 0, "no event files found")

        var totalEvents = 0
        var authentic = 0
        for entry in entries {
            let events = try await repo.loadEvents(at: entry.path)
            totalEvents += events.count
            for e in events where e.isAuthentic() { authentic += 1 }
        }
        print("decoded \(totalEvents) events; \(authentic) authentic")
        XCTAssertGreaterThan(totalEvents, 0)
        XCTAssertEqual(authentic, totalEvents,
                       "\(totalEvents - authentic) events failed signature check")

        await engine.sync()
        let p = await engine.projection
        print("projection: \(p.topics.count) topics, "
              + "\(p.profiles.count) profiles, "
              + "\(p.appliedEventIDs.count) applied events")
        XCTAssertGreaterThan(p.topics.count, 0)
        XCTAssertGreaterThan(p.profiles.count, 0)
    }
}
