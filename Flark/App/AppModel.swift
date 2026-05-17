import Foundation
import SwiftUI
import CryptoKit
import FlarkKit

/// Central app state. Owns the device identity, the open Space (repository +
/// sync engine) and the latest Projection snapshot the UI renders from.
@MainActor
@Observable
final class AppModel {
    enum Stage { case loading, onboarding, noSpace, ready }

    var stage: Stage = .loading
    var displayName: String = ""
    var spaces: [SpaceConfig] = []
    var currentSpace: SpaceConfig?
    var projection = Projection()

    let emoji = EmojiCatalog.load(
        manifestURL: Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Emoji")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json"))

    private var identity: DeviceIdentity?
    private var clock: HLCClock?
    private var engine: SyncEngine?
    private var repo: SpaceRepository?

    private let nameKey = "flark.displayName"
    private let keyAccount = "device.ed25519.private"
    private let nameAccount = "device.displayName"

    var authorID: String { identity?.authorID ?? "" }

    // MARK: - Bootstrap

    func bootstrap() {
        spaces = SpaceStore.load()
        if let keyData = Keychain.get(keyAccount),
           let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            identity = DeviceIdentity(privateKey: pk)
            // Name lives in Keychain alongside the key (UserDefaults is wiped
            // on uninstall while the Keychain survives, which would orphan it).
            displayName = Keychain.getString(nameAccount)
                ?? UserDefaults.standard.string(forKey: nameKey) ?? ""
            if displayName.isEmpty {
                stage = .onboarding          // identity exists but name lost — re-ask
            } else if let first = spaces.first {
                Task { await openSpace(first) }
            } else {
                stage = .noSpace
            }
        } else {
            stage = .onboarding
        }
    }

    // MARK: - Identity

    func createIdentity(name: String) {
        // Reuse the existing device key if one survived (e.g. after a
        // reinstall) so the author id — and thus past content — stays ours.
        let id: DeviceIdentity
        if let keyData = Keychain.get(keyAccount),
           let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            id = DeviceIdentity(privateKey: pk)
        } else {
            id = DeviceIdentity.generate()
            Keychain.set(id.privateKey.rawRepresentation, account: keyAccount, sync: true)
        }
        identity = id
        displayName = name
        Keychain.setString(name, account: nameAccount, sync: true)
        UserDefaults.standard.set(name, forKey: nameKey)
        if let first = spaces.first { Task { await openSpace(first) } }
        else { stage = .noSpace }
    }

    // MARK: - Spaces

    func addLocalSpace(name: String) {
        let cfg = SpaceConfig(id: UUID().uuidString, name: name, kind: .local)
        spaces.append(cfg); SpaceStore.save(spaces)
        Task { await openSpace(cfg) }
    }

    func addWebDAVSpace(name: String, url: String, user: String, password: String) {
        let cfg = SpaceConfig(id: UUID().uuidString, name: name, kind: .webdav,
                              webdavURL: url, webdavUser: user)
        Keychain.setString(password, account: cfg.passwordAccount, sync: true)
        spaces.append(cfg); SpaceStore.save(spaces)
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
            let pw = Keychain.getString(cfg.passwordAccount) ?? ""
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

    // MARK: - Identity export / import (B)

    /// Build a passphrase-encrypted recovery code carrying key + name + Spaces.
    func exportIdentity(passphrase: String) -> String? {
        guard let identity, !passphrase.isEmpty else { return nil }
        var pw: [String: String] = [:]
        for s in spaces where s.kind == .webdav {
            pw[s.id] = Keychain.getString(s.passwordAccount) ?? ""
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

        identity = DeviceIdentity(privateKey: pk)
        displayName = p.name
        Keychain.set(keyData, account: keyAccount, sync: true)
        Keychain.setString(p.name, account: nameAccount, sync: true)
        UserDefaults.standard.set(p.name, forKey: nameKey)

        for (id, password) in p.passwords {
            Keychain.setString(password, account: "space.\(id).password", sync: true)
        }
        spaces = p.spaces
        SpaceStore.save(spaces)

        Task {
            await engine?.stopPolling()
            projection = Projection()
            if let first = spaces.first { await openSpace(first) }
            else { stage = displayName.isEmpty ? .onboarding : .noSpace }
        }
        return true
    }
}
