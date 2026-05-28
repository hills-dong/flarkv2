import Foundation
import SwiftUI
import CryptoKit
import FlarkKit

/// Central app state. Owns the device identity, the open Space (repository +
/// sync engine) and the latest Projection snapshot the UI renders from.
@MainActor
@Observable
final class AppModel {
    enum Stage { case loading, onboarding, accountPicker, noSpace, ready }

    var stage: Stage = .loading
    var displayName: String = ""
    var spaces: [SpaceConfig] = []
    var currentSpace: SpaceConfig?
    var projection = Projection()
    /// Coarse background sync/compaction activity for the status indicator.
    var syncStatus: SyncActivity = .idle

    /// All local accounts (multi-user). `currentAccountID` is the active one.
    var accounts: [AccountRef] = []
    private(set) var currentAccountID: String?

    /// Set when an incoming `flark://invite/...` URL has been decrypted and
    /// is waiting for the user to confirm joining. Drives a global sheet
    /// mounted on `WindowGroup`.
    var pendingInvite: SpaceInvitePayload?
    /// One-shot error surfaced after a malformed/expired invite link.
    var inviteError: String?
    /// Holds an invite URL that arrived before any account was loaded (cold
    /// start landing on onboarding / account picker). Re-fired after login.
    private var deferredInviteURL: URL?

    let emoji = EmojiCatalog.load(
        manifestURL: Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Emoji")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json"))

    /// Per-account local tally that drives the picker's `最常使用` row. Starts
    /// empty and is rebuilt as the user reacts / inserts emoji. Rebound to a
    /// new account on login/switch/import/logout.
    private var emojiUsage = EmojiUsageStore(accountID: "")
    /// Bumped on every `recordEmojiUsage` so SwiftUI views observing
    /// `mostUsedEmoji` (Observable tracks reads of this property) re-render
    /// without us needing to expose the store itself as observable state.
    private var emojiUsageVersion: Int = 0

    private var identity: DeviceIdentity?
    private var clock: HLCClock?
    private var engine: SyncEngine?
    private var repo: SpaceRepository?
    /// Bumped on every space open/switch. Captured by `openSpace`'s async
    /// callbacks and post-await writes so that a slow sync from a previously
    /// selected Space cannot overwrite the projection of the current one when
    /// the user switches mid-sync.
    private var openEpoch: UInt64 = 0

    // Legacy single-identity accounts (pre multi-user) — migrated on first run.
    private let legacyKey = "device.ed25519.private"
    private let legacyName = "device.displayName"
    private let legacySpaces = "flark.spaces.v1"

    var authorID: String { identity?.authorID ?? "" }

    private func spacePwAccount(_ localID: String) -> String {
        AccountStore.spacePassword(currentAccountID ?? "", localID)
    }

    // MARK: - Bootstrap

    func bootstrap() {
        migrateLegacyIfNeeded()
        accounts = AccountStore.accounts()

        if let cur = AccountStore.currentID, accounts.contains(where: { $0.id == cur }),
           loadAccount(cur) {
            if let resume = preferredInitialSpace(forAccount: cur) {
                Task { await openSpace(resume) }
            } else { stage = .noSpace }
        } else if !accounts.isEmpty {
            stage = .accountPicker          // pick / add a user (no data destroyed)
        } else {
            stage = .onboarding             // no accounts yet → create the first
        }
    }

    /// Resume the Space the user last had open on this device for `account`,
    /// falling back to the first one in their list if the saved choice no
    /// longer exists (e.g. deleted on another device, or never recorded).
    private func preferredInitialSpace(forAccount account: String) -> SpaceConfig? {
        if let saved = AccountStore.lastSpaceLocalID(account: account),
           let hit = spaces.first(where: { $0.localID == saved }) {
            return hit
        }
        return spaces.first
    }

    /// One-time import of a pre-multi-user identity into the account model.
    private func migrateLegacyIfNeeded() {
        guard AccountStore.accounts().isEmpty,
              let keyData = Keychain.get(legacyKey),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { return }
        let did = DeviceIdentity(privateKey: pk)
        let id = did.authorID
        let name = Keychain.getString(legacyName)
            ?? UserDefaults.standard.string(forKey: "flark.displayName")
            ?? String(localized: "我", comment: "Default display name for migrated single-user identity")
        Keychain.set(keyData, account: AccountStore.keyAccount(id), sync: true)
        Keychain.setString(name, account: AccountStore.nameAccount(id), sync: true)
        if let old = Keychain.get(legacySpaces),
           let list = try? JSONDecoder().decode([SpaceConfig].self, from: old) {
            SpaceStore.save(list, account: id)
            for s in list where s.kind == .webdav {
                if let pw = Keychain.getString("space.\(s.id).password") {
                    // Legacy SpaceConfig has localID == id (see the Decodable
                    // fallback in SpaceConfig), so this routes to the same
                    // keychain entry the new code reads via cfg.localID.
                    Keychain.setString(pw, account: AccountStore.spacePassword(id, s.localID), sync: true)
                }
            }
        }
        AccountStore.upsert(id: id, name: name)
        AccountStore.currentID = id
    }

    @discardableResult
    private func loadAccount(_ id: String) -> Bool {
        guard let keyData = Keychain.get(AccountStore.keyAccount(id)),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { return false }
        identity = DeviceIdentity(privateKey: pk)
        displayName = Keychain.getString(AccountStore.nameAccount(id)) ?? ""
        currentAccountID = id
        AccountStore.currentID = id
        spaces = SpaceStore.load(account: id)
        rebindEmojiUsage(to: id)
        replayDeferredInviteIfAny()
        return true
    }

    /// The `最常使用` shortcut is per-account, so swap the store whenever the
    /// active account changes — login, switch, import, logout.
    private func rebindEmojiUsage(to accountID: String) {
        emojiUsage = EmojiUsageStore(accountID: accountID)
        emojiUsageVersion &+= 1
    }

    // MARK: - Identity / accounts

    /// Create a brand-new identity as a new local account and switch to it.
    func createIdentity(name: String) {
        let did = DeviceIdentity.generate()
        let id = did.authorID
        Keychain.set(did.privateKey.rawRepresentation, account: AccountStore.keyAccount(id), sync: true)
        Keychain.setString(name, account: AccountStore.nameAccount(id), sync: true)
        AccountStore.upsert(id: id, name: name)
        AccountStore.currentID = id
        identity = did
        displayName = name
        currentAccountID = id
        spaces = []
        accounts = AccountStore.accounts()
        currentSpace = nil
        projection = Projection()
        rebindEmojiUsage(to: id)
        stage = .noSpace
        replayDeferredInviteIfAny()
    }

    /// Switch to another local account (data preserved for all accounts).
    func switchAccount(_ id: String) {
        Task {
            await engine?.shutdown()
            engine = nil; repo = nil; clock = nil
            projection = Projection()
            currentSpace = nil
            guard loadAccount(id) else { stage = .accountPicker; return }
            if let resume = preferredInitialSpace(forAccount: id) {
                await openSpace(resume)
            } else { stage = .noSpace }
        }
    }

    /// Explicit, destructive: erase one account's identity + Spaces on this
    /// device (and, being iCloud-synced, other devices). Distinct from logout.
    func removeAccount(_ id: String) {
        if let list = try? JSONDecoder().decode(
            [SpaceConfig].self, from: Keychain.get(AccountStore.spacesAccount(id)) ?? Data()) {
            for s in list { Keychain.delete(AccountStore.spacePassword(id, s.localID)) }
        }
        Keychain.delete(AccountStore.keyAccount(id))
        Keychain.delete(AccountStore.nameAccount(id))
        Keychain.delete(AccountStore.spacesAccount(id))
        AccountStore.remove(id: id)
        accounts = AccountStore.accounts()
        if currentAccountID == id { logout() }
    }

    // MARK: - Spaces

    private func persistSpaces() {
        if let acct = currentAccountID { SpaceStore.save(spaces, account: acct) }
    }

    func addLocalSpace(name: String) {
        let cfg = SpaceConfig(id: UUID().uuidString, name: name, kind: .local)
        spaces.append(cfg); persistSpaces()
        Task { await openSpace(cfg) }
    }

    /// `spaceID` lets a user join an existing shared Space (it is the WebDAV
    /// directory name). Blank → a fresh random Space. A fresh per-install
    /// `localID` is always generated so the same spaceID can be safely bound
    /// to a second WebDAV server without colliding with the first binding's
    /// outbox / snapshot / blob caches.
    func addWebDAVSpace(name: String, url: String, user: String, password: String,
                        spaceID: String = "") {
        let trimmed = spaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.isEmpty ? UUID().uuidString : trimmed
        let cfg = SpaceConfig(id: id, name: name, kind: .webdav,
                              webdavURL: url, webdavUser: user)
        Keychain.setString(password, account: spacePwAccount(cfg.localID), sync: true)
        spaces.append(cfg); persistSpaces()
        Task { await openSpace(cfg) }
    }

    // MARK: - Invite links

    /// Build a `flark://invite/<token>` URL for a WebDAV space. Token is
    /// AES-GCM ciphertext keyed by a per-invite random 256-bit key embedded in
    /// the URL itself; `exp` (7 days) is authenticated, so the recipient can't
    /// extend it by editing the link.
    func exportInviteURL(for cfg: SpaceConfig) throws -> URL {
        guard cfg.kind == .webdav,
              let urlStr = cfg.webdavURL, let user = cfg.webdavUser else {
            throw SpaceInviteError.malformed
        }
        let pw = Keychain.getString(spacePwAccount(cfg.localID)) ?? ""
        return try SpaceInviteCodec.makeURL(
            spaceID: cfg.id, name: cfg.name, url: urlStr, user: user, pw: pw)
    }

    /// Entry point from `WindowGroup.onOpenURL`. Defers parsing until an
    /// account is loaded; otherwise parses and queues a confirmation sheet
    /// via `pendingInvite`.
    func handleInviteURL(_ url: URL) {
        guard SpaceInviteCodec.isInviteURL(url) else { return }
        guard currentAccountID != nil else {
            deferredInviteURL = url
            return
        }
        do {
            pendingInvite = try SpaceInviteCodec.parse(url)
            inviteError = nil
        } catch {
            pendingInvite = nil
            inviteError = (error as? SpaceInviteError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Replay an invite URL that arrived before login was complete. Called
    /// from every code path that successfully establishes `currentAccountID`.
    private func replayDeferredInviteIfAny() {
        guard let u = deferredInviteURL else { return }
        deferredInviteURL = nil
        handleInviteURL(u)
    }

    /// Accept the pending invite by joining as a fresh WebDAV binding. Reuses
    /// the existing `addWebDAVSpace` path (which generates a new `localID`),
    /// so binding the same shared spaceID twice on this device is safe.
    func acceptPendingInvite() {
        guard let inv = pendingInvite else { return }
        pendingInvite = nil
        addWebDAVSpace(name: inv.name, url: inv.url, user: inv.user,
                       password: inv.pw, spaceID: inv.id)
    }

    func dismissPendingInvite() {
        pendingInvite = nil
    }

    func clearInviteError() {
        inviteError = nil
    }

    func openSpace(_ cfg: SpaceConfig) async {
        guard let identity else { return }
        openEpoch &+= 1
        let epoch = openEpoch
        let backend: StorageBackend
        // Local backends already keep blobs on disk; only the network-backed
        // (WebDAV) Space benefits from a read/write-through blob cache.
        var blobCache: BlobCache?
        switch cfg.kind {
        case .local:
            backend = LocalFileBackend(root: SpaceStore.localRoot(for: cfg.localID))
        case .webdav:
            guard let u = URL(string: cfg.webdavURL ?? "") else { return }
            let pw = Keychain.getString(spacePwAccount(cfg.localID)) ?? ""
            backend = WebDAVBackend(baseURL: u, username: cfg.webdavUser ?? "", password: pw)
            blobCache = BlobCache(directory: SpaceStore.blobCacheRoot(for: cfg.localID))
        }
        let clock = HLCClock(nodeID: identity.authorID)
        let repo = SpaceRepository(backend: backend, identity: identity,
                                   spaceID: cfg.id, deviceID: DeviceID.current,
                                   outboxRoot: SpaceStore.outboxRoot(for: cfg.localID),
                                   blobCache: blobCache)
        let snapshots = SnapshotStore(url: SpaceStore.snapshotURL(for: cfg.localID))
        let engine = SyncEngine(repo: repo, clock: clock, identity: identity,
                                snapshotStore: snapshots)
        self.clock = clock; self.repo = repo; self.engine = engine
        self.currentSpace = cfg
        if let acct = currentAccountID {
            AccountStore.setLastSpaceLocalID(cfg.localID, account: acct)
        }

        await engine.setOnChange { [weak self] snap in
            Task { @MainActor in
                guard let self, self.openEpoch == epoch else { return }
                self.projection = snap
            }
        }
        await engine.setOnActivity { [weak self] a in
            Task { @MainActor in
                guard let self, self.openEpoch == epoch else { return }
                self.syncStatus = a
            }
        }
        // Paint instantly from the local cache and show the UI right away;
        // the network bootstrap + initial sync below then run in the
        // background (surfaced only by the slim top status bar) instead of
        // blocking the whole screen on a centered spinner.
        await engine.restoreSnapshot()
        guard openEpoch == epoch else { return }
        self.projection = await engine.projection
        self.stage = .ready
        try? await repo.bootstrap(spaceName: cfg.name)
        if !displayName.isEmpty {                       // never clobber with empty
            try? await repo.writeProfile(displayName: displayName, avatarBlobID: nil)
            await engine.setLocalProfile(authorID: identity.authorID,
                                         displayName: displayName, avatarBlobID: nil)
        }
        // Windowed: newest files first so a new member isn't blocked on the
        // whole log. After this opening pull, the engine is idle — fresh
        // remote events arrive only when the user pull-to-refreshes on the
        // topic list. Local writes still push automatically via `submit()`.
        await engine.sync(maxNewFiles: 4)
        guard openEpoch == epoch else { return }
        self.projection = await engine.projection
    }

    /// Manual fetch — triggered by pull-to-refresh on the topic list. No
    /// `maxNewFiles` cap: an explicit refresh should converge fully, not
    /// trickle in over multiple pulls.
    func refresh() async {
        await engine?.sync(maxNewFiles: nil)
    }

    /// Backgrounding the app: drain any locally-queued writes up to WebDAV
    /// (last chance before suspension, since fetch is manual now) and persist
    /// the projection cache so the next cold start paints instantly.
    func persistOnBackground() {
        Task { await engine?.shutdown() }
    }

    /// Update an existing Space's mutable fields (name + WebDAV connection
    /// details). `id`, `localID` and `kind` are immutable — changing those
    /// is semantically a new join, not an edit. Pass a non-nil `password` to
    /// overwrite the stored credential; nil keeps it. If the edited Space is
    /// currently open, reconnect so connection changes take effect — local
    /// caches survive because they're keyed by `localID`, which doesn't move.
    func updateSpace(_ cfg: SpaceConfig, password: String? = nil) {
        guard let idx = spaces.firstIndex(where: { $0.localID == cfg.localID }) else { return }
        spaces[idx] = cfg
        persistSpaces()
        if let pw = password, cfg.kind == .webdav {
            Keychain.setString(pw, account: spacePwAccount(cfg.localID), sync: true)
        }
        if currentSpace?.localID == cfg.localID {
            Task {
                await engine?.shutdown()
                engine = nil; repo = nil; clock = nil
                projection = Projection()
                syncStatus = .idle
                await openSpace(cfg)
            }
        }
    }

    func switchSpace(_ cfg: SpaceConfig) {
        Task {
            await engine?.shutdown()
            projection = Projection()
            syncStatus = .idle
            await openSpace(cfg)
        }
    }

    /// Remove a Space. A **local** Space is destroyed completely — its whole
    /// event log, blobs and projection cache are wiped from this device. A
    /// **WebDAV** Space is only detached locally (config + saved credential +
    /// cache); the shared remote directory is left untouched for other
    /// members. If the deleted Space was open, fall back to another one (or
    /// the no-Space screen).
    func deleteSpace(_ cfg: SpaceConfig) {
        Task {
            let wasCurrent = currentSpace?.id == cfg.id
            if wasCurrent {
                await engine?.shutdown()
                engine = nil; repo = nil; clock = nil
                projection = Projection()
                currentSpace = nil
                syncStatus = .idle
            }

            spaces.removeAll { $0.id == cfg.id }
            persistSpaces()

            switch cfg.kind {
            case .local:
                try? FileManager.default.removeItem(at: SpaceStore.localRoot(for: cfg.localID))
            case .webdav:
                Keychain.delete(spacePwAccount(cfg.localID))
            }
            // The projection + blob + thumbnail caches + outbox mirror are
            // per-Space regardless of backend kind.
            try? FileManager.default.removeItem(at: SpaceStore.snapshotURL(for: cfg.localID))
            try? FileManager.default.removeItem(at: SpaceStore.blobCacheRoot(for: cfg.localID))
            try? FileManager.default.removeItem(at: SpaceStore.thumbCacheRoot(for: cfg.localID))
            try? FileManager.default.removeItem(at: SpaceStore.outboxRoot(for: cfg.localID))

            if wasCurrent {
                if let next = spaces.first {
                    await openSpace(next)
                } else {
                    stage = .noSpace
                }
            }
        }
    }

    // MARK: - Mutations

    private func emit(_ payload: Event.Payload) {
        guard let identity, let engine else { return }
        Task {
            let ev = await engine.makeEvent(payload, authorID: identity.authorID,
                                            publicKey: identity.publicKeyData)
            await engine.submit(ev)
        }
    }

    func createTopic(body: ContentDocument) {
        emit(.topicCreate(topicID: UUID().uuidString, body: body))
    }

    /// A topic can be deleted only by its own author and only while it has
    /// had no interaction at all (no replies, no reactions).
    func canDeleteTopic(_ topicID: String) -> Bool {
        guard let topic = projection.topics[topicID] else { return false }
        return topic.authorID == authorID
            && topic.replyCount == 0
            && projection.tallies(forTarget: topic.id).isEmpty
    }

    func deleteTopic(_ topicID: String) {
        emit(.topicDelete(topicID: topicID))
    }

    /// A topic can be edited only by its own author. Unlike delete, edits are
    /// allowed regardless of replies/reactions — that's the normal expectation.
    func canEditTopic(_ topicID: String) -> Bool {
        guard let topic = projection.topics[topicID] else { return false }
        return topic.authorID == authorID
    }

    func editTopic(_ topicID: String, body: ContentDocument) {
        emit(.topicEdit(topicID: topicID, body: body))
    }

    func createReply(topicID: String, body: ContentDocument) {
        emit(.replyCreate(replyID: UUID().uuidString, topicID: topicID, body: body))
    }

    /// A reply can be deleted only by its own author.
    func canDeleteReply(_ replyID: String) -> Bool {
        guard let reply = projection.replies[replyID] else { return false }
        return reply.authorID == authorID
    }

    func deleteReply(_ replyID: String) {
        emit(.replyDelete(replyID: replyID))
    }

    func canEditReply(_ replyID: String) -> Bool {
        guard let reply = projection.replies[replyID] else { return false }
        return reply.authorID == authorID
    }

    func editReply(_ replyID: String, body: ContentDocument) {
        emit(.replyEdit(replyID: replyID, body: body))
    }

    func toggleReaction(targetID: String, type: TargetType, emojiID: String) {
        let active = projection.hasReacted(author: authorID, target: targetID, emoji: emojiID)
        emit(.reactionSet(targetID: targetID, targetType: type, emojiID: emojiID, removed: active))
    }

    // MARK: - Emoji usage (drives `最常使用`)

    /// Top emoji the user has actually reached for, frequency × recency-decay,
    /// resolved into catalog items. The manifest's `defaultMostUsed` seeds pad
    /// the tail so first-launch isn't empty; user picks always rank ahead and
    /// push the seeds off as real usage accumulates.
    var mostUsedEmoji: [EmojiItem] {
        _ = emojiUsageVersion          // observe for SwiftUI invalidation
        let dynamic = emojiUsage.topIDs(limit: 24)
        var seen = Set(dynamic)
        var merged = dynamic
        for id in emoji.seedMostUsedIDs where !seen.contains(id) {
            merged.append(id); seen.insert(id)
        }
        return merged.prefix(24).compactMap { emoji.item($0) }
    }

    /// Call from picker / quick-row / composer insertion — anywhere the user
    /// explicitly chose an emoji. Toggling off a reaction shouldn't count.
    func recordEmojiUsage(_ emojiID: String) {
        emojiUsage.record(emojiID)
        emojiUsageVersion &+= 1
    }

    func uploadImage(_ data: Data) async -> (id: String, w: Int, h: Int)? {
        guard let repo else { return nil }
        #if canImport(UIKit)
        // Camera-roll photos are often 2–30 MB (HEIC / PNG screenshots /
        // ProRAW). In a serverless WebDAV Space every member re-downloads
        // each blob on poll, so always downscale + re-encode as JPEG before
        // it enters the (immutable, content-addressed) blob store.
        let (out, w, h) = Self.compressForUpload(data)
        guard let id = try? await repo.putBlob(out) else { return nil }
        return (id, w, h)
        #else
        guard let id = try? await repo.putBlob(data) else { return nil }
        return (id, 0, 0)
        #endif
    }

    #if canImport(UIKit)
    /// Downscale to a max long edge and JPEG-encode. Returns the encoded
    /// bytes and the *output* pixel size (used for layout aspect ratio).
    /// Falls back to the original bytes if the image can't be decoded.
    static func compressForUpload(_ data: Data,
                                  maxEdge: CGFloat = 2048,
                                  quality: CGFloat = 0.8) -> (Data, Int, Int) {
        guard let img = UIImage(data: data) else { return (data, 0, 0) }
        let px = CGSize(width: img.size.width * img.scale,
                        height: img.size.height * img.scale)
        let scale = min(1, maxEdge / max(px.width, px.height))
        let target = CGSize(width: (px.width * scale).rounded(),
                            height: (px.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1                       // target is already in pixels
        fmt.opaque = true                   // JPEG has no alpha anyway
        let resized = UIGraphicsImageRenderer(size: target, format: fmt)
            .image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: quality) else {
            return (data, Int(px.width), Int(px.height))
        }
        // If re-encoding somehow grew it (tiny image), keep the original.
        if jpeg.count >= data.count, scale == 1 {
            return (data, Int(px.width), Int(px.height))
        }
        return (jpeg, Int(target.width), Int(target.height))
    }
    #endif

    func loadImage(_ id: String) async -> Data? {
        try? await repo?.getBlob(id)
    }

    /// Like `loadImage`, but returns a downscaled JPEG sized for list rows and
    /// memoizes it on disk. The list shows many images at ≤180pt; decoding the
    /// full ~2048px blob for each is needless CPU + memory. The full blob is
    /// still fetched once (and cached by `BlobCache`); the thumbnail is then
    /// derived, cached, and reused on every subsequent appearance.
    ///
    /// The fetch hops to the repo actor; decode/resize/IO run off the main
    /// actor (the helpers below are `nonisolated`) so scrolling stays smooth.
    func loadThumbnail(_ id: String, maxEdge: Int = 900) async -> Data? {
        guard let localID = currentSpace?.localID else { return await loadImage(id) }
        let url = SpaceStore.thumbCacheRoot(for: localID)
            .appendingPathComponent("\(id)@\(maxEdge)")
        if let cached = await Self.readFile(url) { return cached }
        guard let full = await loadImage(id) else { return nil }
        return await Self.makeThumbnail(full, maxEdge: CGFloat(maxEdge), cacheTo: url)
    }

    private nonisolated static func readFile(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }

    /// Decode + downscale to `maxEdge` and JPEG-encode, writing the result to
    /// `url`. Runs off the main actor. Falls back to the original bytes if the
    /// image can't be decoded or is already smaller than the target.
    private nonisolated static func makeThumbnail(
        _ data: Data, maxEdge: CGFloat, cacheTo url: URL) async -> Data? {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return data }
        let px = CGSize(width: img.size.width * img.scale,
                        height: img.size.height * img.scale)
        // Already small enough — cache the original so we don't re-decode it.
        if max(px.width, px.height) <= maxEdge {
            try? data.write(to: url, options: .atomic)
            return data
        }
        let scale = maxEdge / max(px.width, px.height)
        let target = CGSize(width: (px.width * scale).rounded(),
                            height: (px.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: fmt)
            .image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7) else { return data }
        try? jpeg.write(to: url, options: .atomic)
        return jpeg
        #else
        try? data.write(to: url, options: .atomic)
        return data
        #endif
    }

    func displayName(for authorID: String) -> String {
        projection.displayName(authorID)
    }

    var authorIDShort: String { String(authorID.prefix(10)) }
    var hasIdentity: Bool { identity != nil }

    // MARK: - Logout

    /// Non-destructive: just deactivate the current account on this device.
    /// All accounts' identities & Spaces are kept (in the iCloud Keychain),
    /// so you can switch back, sign in again, or add another user.
    func logout() {
        Task { await engine?.shutdown() }
        engine = nil; repo = nil; clock = nil
        AccountStore.currentID = nil
        currentAccountID = nil
        identity = nil
        displayName = ""
        spaces = []
        currentSpace = nil
        projection = Projection()
        accounts = AccountStore.accounts()
        rebindEmojiUsage(to: "")
        stage = accounts.isEmpty ? .onboarding : .accountPicker
    }

    // MARK: - Identity export / import (B)

    /// Build a passphrase-encrypted recovery code carrying key + name + Spaces.
    func exportIdentity(passphrase: String) -> String? {
        guard let identity, !passphrase.isEmpty else { return nil }
        var pw: [String: String] = [:]
        for s in spaces where s.kind == .webdav {
            // Keyed by localID — matches `spacePwAccount` and lets the same
            // spaceID appear twice (one per WebDAV binding) without one
            // password overwriting the other.
            pw[s.localID] = Keychain.getString(spacePwAccount(s.localID)) ?? ""
        }
        let portable = PortableIdentity(
            key: identity.privateKey.rawRepresentation.base64EncodedString(),
            name: displayName, spaces: spaces, passwords: pw)
        return IdentityKit.export(portable, passphrase: passphrase)
    }

    /// Restore an identity from a recovery code: become the same author and
    /// recover all Spaces. Replaces the current device identity.
    @discardableResult
    func importIdentity(code: String, passphrase: String) -> Bool {
        guard let p = IdentityKit.import(code, passphrase: passphrase),
              let keyData = Data(base64Encoded: p.key),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        else { return false }

        let did = DeviceIdentity(privateKey: pk)
        let acctID = did.authorID        // account id == imported identity's author id
        identity = did
        displayName = p.name
        currentAccountID = acctID
        Keychain.set(keyData, account: AccountStore.keyAccount(acctID), sync: true)
        Keychain.setString(p.name, account: AccountStore.nameAccount(acctID), sync: true)
        AccountStore.upsert(id: acctID, name: p.name)
        AccountStore.currentID = acctID

        // Keys in `p.passwords` are localIDs (new exports) or spaceIDs (legacy
        // exports where SpaceConfig had no localID). For legacy data the
        // SpaceConfig decoder falls back to localID == id, so either form ends
        // up at the right keychain account.
        for (key, password) in p.passwords {
            Keychain.setString(password, account: AccountStore.spacePassword(acctID, key), sync: true)
        }
        spaces = p.spaces
        SpaceStore.save(spaces, account: acctID)
        accounts = AccountStore.accounts()
        rebindEmojiUsage(to: acctID)

        Task {
            await engine?.shutdown()
            projection = Projection()
            if let first = spaces.first { await openSpace(first) }
            else { stage = .noSpace }
        }
        return true
    }
}
