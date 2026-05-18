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

    let emoji = EmojiCatalog.load(
        manifestURL: Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Emoji")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json"))

    private var identity: DeviceIdentity?
    private var clock: HLCClock?
    private var engine: SyncEngine?
    private var repo: SpaceRepository?

    // Legacy single-identity accounts (pre multi-user) — migrated on first run.
    private let legacyKey = "device.ed25519.private"
    private let legacyName = "device.displayName"
    private let legacySpaces = "flark.spaces.v1"

    var authorID: String { identity?.authorID ?? "" }

    private func spacePwAccount(_ spaceID: String) -> String {
        AccountStore.spacePassword(currentAccountID ?? "", spaceID)
    }

    // MARK: - Bootstrap

    func bootstrap() {
        migrateLegacyIfNeeded()
        accounts = AccountStore.accounts()

        if let cur = AccountStore.currentID, accounts.contains(where: { $0.id == cur }),
           loadAccount(cur) {
            if let first = spaces.first { Task { await openSpace(first) } }
            else { stage = .noSpace }
        } else if !accounts.isEmpty {
            stage = .accountPicker          // pick / add a user (no data destroyed)
        } else {
            stage = .onboarding             // no accounts yet → create the first
        }
    }

    /// One-time import of a pre-multi-user identity into the account model.
    private func migrateLegacyIfNeeded() {
        guard AccountStore.accounts().isEmpty,
              let keyData = Keychain.get(legacyKey),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else { return }
        let did = DeviceIdentity(privateKey: pk)
        let id = did.authorID
        let name = Keychain.getString(legacyName)
            ?? UserDefaults.standard.string(forKey: "flark.displayName") ?? "我"
        Keychain.set(keyData, account: AccountStore.keyAccount(id), sync: true)
        Keychain.setString(name, account: AccountStore.nameAccount(id), sync: true)
        if let old = Keychain.get(legacySpaces),
           let list = try? JSONDecoder().decode([SpaceConfig].self, from: old) {
            SpaceStore.save(list, account: id)
            for s in list where s.kind == .webdav {
                if let pw = Keychain.getString("space.\(s.id).password") {
                    Keychain.setString(pw, account: AccountStore.spacePassword(id, s.id), sync: true)
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
        return true
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
        stage = .noSpace
    }

    /// Switch to another local account (data preserved for all accounts).
    func switchAccount(_ id: String) {
        Task {
            await engine?.stopPolling()
            engine = nil; repo = nil; clock = nil
            projection = Projection()
            currentSpace = nil
            guard loadAccount(id) else { stage = .accountPicker; return }
            if let first = spaces.first { await openSpace(first) }
            else { stage = .noSpace }
        }
    }

    /// Explicit, destructive: erase one account's identity + Spaces on this
    /// device (and, being iCloud-synced, other devices). Distinct from logout.
    func removeAccount(_ id: String) {
        if let list = try? JSONDecoder().decode(
            [SpaceConfig].self, from: Keychain.get(AccountStore.spacesAccount(id)) ?? Data()) {
            for s in list { Keychain.delete(AccountStore.spacePassword(id, s.id)) }
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
    /// directory name). Blank → a fresh random Space.
    func addWebDAVSpace(name: String, url: String, user: String, password: String,
                        spaceID: String = "") {
        let trimmed = spaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.isEmpty ? UUID().uuidString : trimmed
        let cfg = SpaceConfig(id: id, name: name, kind: .webdav,
                              webdavURL: url, webdavUser: user)
        Keychain.setString(password, account: spacePwAccount(cfg.id), sync: true)
        spaces.append(cfg); persistSpaces()
        Task { await openSpace(cfg) }
    }

    func openSpace(_ cfg: SpaceConfig) async {
        guard let identity else { return }
        let backend: StorageBackend
        switch cfg.kind {
        case .local:
            backend = LocalFileBackend(root: SpaceStore.localRoot(for: cfg.id))
        case .webdav:
            guard let u = URL(string: cfg.webdavURL ?? "") else { return }
            let pw = Keychain.getString(spacePwAccount(cfg.id)) ?? ""
            backend = WebDAVBackend(baseURL: u, username: cfg.webdavUser ?? "", password: pw)
        }
        let clock = HLCClock(nodeID: identity.authorID)
        let repo = SpaceRepository(backend: backend, identity: identity, spaceID: cfg.id)
        let snapshots = SnapshotStore(url: SpaceStore.snapshotURL(for: cfg.id))
        let engine = SyncEngine(repo: repo, clock: clock, identity: identity,
                                snapshotStore: snapshots)
        self.clock = clock; self.repo = repo; self.engine = engine
        self.currentSpace = cfg

        await engine.setOnChange { [weak self] snap in
            Task { @MainActor in self?.projection = snap }
        }
        await engine.setOnActivity { [weak self] a in
            Task { @MainActor in self?.syncStatus = a }
        }
        // Paint instantly from the local cache and show the UI right away;
        // the network bootstrap + initial sync below then run in the
        // background (surfaced only by the slim top status bar) instead of
        // blocking the whole screen on a centered spinner.
        await engine.restoreSnapshot()
        self.projection = await engine.projection
        self.stage = .ready
        try? await repo.bootstrap(spaceName: cfg.name)
        if !displayName.isEmpty {                       // never clobber with empty
            try? await repo.writeProfile(displayName: displayName, avatarBlobID: nil)
            await engine.setLocalProfile(authorID: identity.authorID,
                                         displayName: displayName, avatarBlobID: nil)
        }
        // Windowed: newest topics first so a new member isn't blocked on the
        // whole log; polling backfills the rest newest→oldest in the bg.
        await engine.sync(maxNewEvents: 20)
        await engine.startPolling(interval: cfg.kind == .webdav ? 15 : 3, window: 20)
        self.projection = await engine.projection
    }

    /// Flush the local projection cache (call when the app backgrounds) so the
    /// next cold start restores instantly instead of re-folding the log.
    func persistSnapshot() {
        Task { await engine?.persistSnapshot() }
    }

    func switchSpace(_ cfg: SpaceConfig) {
        Task {
            await engine?.stopPolling()
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
                await engine?.stopPolling()
                engine = nil; repo = nil; clock = nil
                projection = Projection()
                currentSpace = nil
                syncStatus = .idle
            }

            spaces.removeAll { $0.id == cfg.id }
            persistSpaces()

            switch cfg.kind {
            case .local:
                try? FileManager.default.removeItem(at: SpaceStore.localRoot(for: cfg.id))
            case .webdav:
                Keychain.delete(spacePwAccount(cfg.id))
            }
            // The projection cache is per-Space regardless of backend kind.
            try? FileManager.default.removeItem(at: SpaceStore.snapshotURL(for: cfg.id))

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

    func toggleReaction(targetID: String, type: TargetType, emojiID: String) {
        let active = projection.hasReacted(author: authorID, target: targetID, emoji: emojiID)
        emit(.reactionSet(targetID: targetID, targetType: type, emojiID: emojiID, removed: active))
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
        Task { await engine?.stopPolling() }
        engine = nil; repo = nil; clock = nil
        AccountStore.currentID = nil
        currentAccountID = nil
        identity = nil
        displayName = ""
        spaces = []
        currentSpace = nil
        projection = Projection()
        accounts = AccountStore.accounts()
        stage = accounts.isEmpty ? .onboarding : .accountPicker
    }

    // MARK: - Identity export / import (B)

    /// Build a passphrase-encrypted recovery code carrying key + name + Spaces.
    func exportIdentity(passphrase: String) -> String? {
        guard let identity, !passphrase.isEmpty else { return nil }
        var pw: [String: String] = [:]
        for s in spaces where s.kind == .webdav {
            pw[s.id] = Keychain.getString(spacePwAccount(s.id)) ?? ""
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

        for (spaceID, password) in p.passwords {
            Keychain.setString(password, account: AccountStore.spacePassword(acctID, spaceID), sync: true)
        }
        spaces = p.spaces
        SpaceStore.save(spaces, account: acctID)
        accounts = AccountStore.accounts()

        Task {
            await engine?.stopPolling()
            projection = Projection()
            if let first = spaces.first { await openSpace(first) }
            else { stage = .noSpace }
        }
        return true
    }
}
