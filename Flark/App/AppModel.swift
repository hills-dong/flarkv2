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

    func addWebDAVSpace(name: String, url: String, user: String, password: String) {
        let cfg = SpaceConfig(id: UUID().uuidString, name: name, kind: .webdav,
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
        let engine = SyncEngine(repo: repo, clock: clock, identity: identity)
        self.clock = clock; self.repo = repo; self.engine = engine
        self.currentSpace = cfg

        await engine.setOnChange { [weak self] snap in
            Task { @MainActor in self?.projection = snap }
        }
        try? await repo.bootstrap(spaceName: cfg.name)
        if !displayName.isEmpty {                       // never clobber with empty
            try? await repo.writeProfile(displayName: displayName, avatarBlobID: nil)
            await engine.setLocalProfile(authorID: identity.authorID,
                                         displayName: displayName, avatarBlobID: nil)
        }
        await engine.sync()
        await engine.startPolling(interval: cfg.kind == .webdav ? 15 : 3)
        self.projection = await engine.projection
        self.stage = .ready
    }

    func switchSpace(_ cfg: SpaceConfig) {
        Task {
            await engine?.stopPolling()
            projection = Projection()
            await openSpace(cfg)
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

    func createTopic(title: String, body: ContentDocument) {
        emit(.topicCreate(topicID: UUID().uuidString, title: title, body: body))
    }

    /// A topic can be deleted only by its own author and only while it has
    /// had no interaction at all (no replies, no reactions).
    func canDeleteTopic(_ topic: TopicState) -> Bool {
        topic.authorID == authorID
            && topic.replyCount == 0
            && projection.tallies(forTarget: topic.id).isEmpty
    }

    func deleteTopic(_ topicID: String) {
        emit(.topicDelete(topicID: topicID))
    }

    func createReply(topicID: String, body: ContentDocument) {
        emit(.replyCreate(replyID: UUID().uuidString, topicID: topicID, body: body))
    }

    func toggleReaction(targetID: String, type: TargetType, emojiID: String) {
        let active = projection.hasReacted(author: authorID, target: targetID, emoji: emojiID)
        emit(.reactionSet(targetID: targetID, targetType: type, emojiID: emojiID, removed: active))
    }

    func uploadImage(_ data: Data) async -> (id: String, w: Int, h: Int)? {
        guard let repo else { return nil }
        guard let id = try? await repo.putBlob(data) else { return nil }
        #if canImport(UIKit)
        let img = UIImage(data: data)
        return (id, Int(img?.size.width ?? 0), Int(img?.size.height ?? 0))
        #else
        return (id, 0, 0)
        #endif
    }

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
