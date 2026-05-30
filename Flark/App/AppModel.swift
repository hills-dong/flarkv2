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
        // Restore iCloud-synced settings into UserDefaults before any view or
        // helper reads them, then keep mirroring local changes up.
        SettingsSync.start()
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

    /// Rename the active identity locally and, when a Space is open, update
    /// that Space's profile file so the new name is visible immediately.
    @discardableResult
    func updateDisplayName(_ rawName: String) async -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let identity,
              let accountID = currentAccountID else { return false }
        guard trimmed != displayName else { return true }

        displayName = trimmed
        Keychain.setString(trimmed, account: AccountStore.nameAccount(accountID), sync: true)
        AccountStore.upsert(id: accountID, name: trimmed)
        if let i = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[i].name = trimmed
        } else {
            accounts = AccountStore.accounts()
        }

        let avatarBlobID = projection.profiles[identity.authorID]?.avatarBlobID
        await engine?.setLocalProfile(authorID: identity.authorID,
                                      displayName: trimmed,
                                      avatarBlobID: avatarBlobID)
        try? await repo?.writeProfile(displayName: trimmed, avatarBlobID: avatarBlobID)
        return true
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
            let avatarBlobID = self.projection.profiles[identity.authorID]?.avatarBlobID
            try? await repo.writeProfile(displayName: displayName, avatarBlobID: avatarBlobID)
            await engine.setLocalProfile(authorID: identity.authorID,
                                         displayName: displayName, avatarBlobID: avatarBlobID)
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
        // Preserve the hidden persona label across edits. The composer edits
        // only the visible content (the marker is stripped before editing), so
        // when the original reply was a summon, re-wrap with the same name.
        var newBody = body
        if let existing = projection.replies[replyID],
           let persona = PersonaTag.unwrap(existing.body.body) {
            newBody = ContentDocument(body: PersonaTag.wrap(name: persona.name, content: body.body))
        }
        emit(.replyEdit(replyID: replyID, body: newBody))
    }

    func toggleReaction(targetID: String, type: TargetType, emojiID: String) {
        let active = projection.hasReacted(author: authorID, target: targetID, emoji: emojiID)
        emit(.reactionSet(targetID: targetID, targetType: type, emojiID: emojiID, removed: active))
    }

    // MARK: - AI personas

    /// True while a Gemini request is in flight — drives the summon button's
    /// spinner so the user can't fire a second request mid-generation.
    var aiGenerating = false
    /// Last AI failure, surfaced as an alert in the topic detail view.
    var aiError: String?

    /// Summon `persona` to reply in `topicID`: flatten the topic + its replies
    /// into a prompt, call the persona's selected model (Gemini or any
    /// OpenAI-compatible provider via `LLMRunner`), and post the response as a
    /// normal reply under the current user's identity, labelled with the
    /// persona's name. Posting as the user needs no synthetic author identity
    /// and no change to the signing path.
    func summonPersona(_ persona: Persona, inTopic topicID: String, guidance: String = "") async {
        guard !aiGenerating else { return }
        guard let option = AIConfig.modelOption(for: persona),
              !option.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiError = String(localized: "请先在「AI 角色」设置里配置一个带 API Key 的模型。")
            return
        }
        guard let topic = projection.topics[topicID] else { return }

        aiGenerating = true
        aiError = nil
        defer { aiGenerating = false }

        // Let the persona "see" pictures already in the thread (most recent
        // few), loaded as compact thumbnails so the request stays small. The
        // runner attaches them as vision input where the transport supports it.
        var inputImages: [Data] = []
        for id in recentImageBlobIDs(topicID: topicID, topic: topic) {
            if let data = await loadThumbnail(id, maxEdge: 1024) { inputImages.append(data) }
        }

        // Image-generation models get a picture-oriented prompt; chat models get
        // the usual conversational one. The runner picks the route from the
        // model id (`generatesImages`).
        let prompt = option.generatesImages
            ? buildImagePrompt(topicID: topicID, topic: topic, guidance: guidance)
            : buildConversationPrompt(topicID: topicID, topic: topic, guidance: guidance)
        do {
            let result = try await LLMRunner.generate(
                option: option, systemPrompt: persona.systemPrompt,
                userPrompt: prompt, inputImages: inputImages)

            // Upload any generated images into the (content-addressed) blob
            // store so they can be embedded in the reply body like any photo.
            var blobIDs: [String] = []
            for image in result.images {
                if let uploaded = await uploadImage(image) { blobIDs.append(uploaded.id) }
            }
            guard !result.text.isEmpty || !blobIDs.isEmpty else {
                aiError = String(localized: "模型没有返回任何内容。")
                return
            }
            createReply(topicID: topicID,
                        body: personaReplyBody(persona: persona, text: result.text, imageBlobIDs: blobIDs))
        } catch {
            aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The most recent image blobs referenced in a topic + its replies (capped),
    /// newest last. Fed to the model as vision input so a summoned persona can
    /// react to pictures in the thread.
    private func recentImageBlobIDs(topicID: String, topic: TopicState, limit: Int = 4) -> [String] {
        var ids = topic.body.blobIDs
        for reply in projection.replies(forTopic: topicID) {
            ids.append(contentsOf: reply.body.blobIDs)
        }
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids where seen.insert(id).inserted { unique.append(id) }
        return Array(unique.suffix(limit))
    }

    /// Picture-oriented prompt for image-generation models. Leads with an
    /// explicit image directive (and the user's guidance, which becomes the
    /// subject) so the model treats picture-making — not continuing the
    /// conversation — as the task; the thread follows only as light context.
    /// The persona's system prompt carries the style. Skips the emoji/markdown
    /// format guide (irrelevant for an image). The surrounding instructions use
    /// the app's language rather than the device locale.
    private func buildImagePrompt(topicID: String, topic: TopicState, guidance: String = "") -> String {
        let zh = appPrefersChinese
        let trimmedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []

        lines.append(zh
            ? "如果你可以同时生成文字和图片：除非用户明确要求生成图片，或当前场景特别适合用图片回复，否则请优先直接给出简洁的文字回复，不要生成图片。"
            : "If you can produce both text and images, prefer a concise text reply and do not generate an image unless the user explicitly asks for one or the situation is especially well suited to an image reply.")

        if !trimmedGuidance.isEmpty {
            lines.append(zh
                ? "如果你判断这次确实应该生成图片，请围绕以下方向来画：\(trimmedGuidance)"
                : "If you decide an image really is the right reply this time, generate it around this direction: \(trimmedGuidance)")
        } else {
            lines.append(zh
                ? "如果你判断这次确实应该生成图片，请生成一张与下面话题相关的图片。"
                : "If you decide an image really is the right reply this time, generate one that fits the topic below.")
        }

        let author = displayName(for: topic.authorID)
        lines.append(zh ? "\n（参考上下文）话题由「\(author)」发起：" : "\n(Context) Topic started by \"\(author)\":")
        lines.append(topic.body.plainText(catalog: emoji))

        let replies = projection.replies(forTopic: topicID)
        if !replies.isEmpty {
            lines.append(zh ? "讨论：" : "Discussion:")
            for reply in replies.suffix(8) {
                let who = displayName(for: reply.authorID)
                lines.append("\(who)\(zh ? "：" : ": ")\(reply.body.plainText(catalog: emoji))")
            }
        }

        lines.append(zh
            ? "\n如果你决定生成图片，请直接输出图片；否则只输出文字回复。"
            : "\nIf you decide to generate an image, output the image directly; otherwise output only a text reply.")
        return lines.joined(separator: "\n")
    }

    /// Flatten the topic + its replies into a plain-text transcript the model
    /// can reason over. Caps the reply tail so a long thread can't blow up the
    /// prompt. The reply language is left to the model: the prompt states the
    /// priority (this turn's guidance → persona → the thread's language → app
    /// language) and the model picks, rather than us pre-detecting it.
    private func buildConversationPrompt(topicID: String, topic: TopicState, guidance: String = "") -> String {
        let zh = appPrefersChinese
        let appLanguage = zh ? "中文" : "English"
        var lines: [String] = []

        let author = displayName(for: topic.authorID)
        lines.append(zh ? "话题由「\(author)」发起：" : "Topic started by \"\(author)\":")
        lines.append(topic.body.plainText(catalog: emoji))

        let replies = projection.replies(forTopic: topicID)
        if !replies.isEmpty {
            lines.append(zh ? "\n已有的讨论（按时间顺序）：" : "\nDiscussion so far (in order):")
            for reply in replies.suffix(20) {
                let who = displayName(for: reply.authorID)
                lines.append("\(who)\(zh ? "：" : ": ")\(reply.body.plainText(catalog: emoji))")
            }
        }

        lines.append(zh
            ? "\n请以你的角色身份，针对上面的话题和讨论，给出一条简洁、有观点的回复。直接说你的看法，不要复述题目，也不要在开头加「角色名：」之类的前缀。"
            : "\nReplying in character, give one concise, opinionated response to the topic and discussion above. State your view directly; don't restate the prompt and don't prefix your reply with a name like \"Name:\".")
        lines.append(zh
            ? "回复语言请自行判断，按以下优先级：① 若本次额外指示指定了语言，用它；② 否则若你的角色设定指定了语言，用它；③ 否则使用上面话题和讨论的主要语言；④ 实在无法判断（例如只有图片、几乎没有文字）时，用本应用的界面语言（\(appLanguage)）回复。不要因为这些说明本身是用中文写的，就改变你的回复语言。"
            : "Decide your reply language yourself, by this priority: (1) if this turn's extra guidance names a language, use it; (2) otherwise if your persona specifies a language, use it; (3) otherwise reply in the dominant language of the topic and discussion above; (4) only when none can be determined (e.g. image-only, almost no text), reply in this app's UI language (\(appLanguage)). Don't let the language these instructions happen to be written in change your reply language.")
        lines.append(zh
            ? "如果你可以同时生成文字和图片：除非用户明确要求生成图片，或当前场景特别适合用图片回复，否则只回复文字，不要生成图片。"
            : "If you can produce both text and images, reply with text only unless the user explicitly asks for an image or the situation is especially well suited to an image reply.")

        lines.append(replyFormatGuide(chinese: zh))

        let trimmedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGuidance.isEmpty {
            lines.append(zh
                ? "本次回复请特别按照以下方向来写（在不脱离角色设定的前提下优先遵循）：\(trimmedGuidance)"
                : "For this reply, prioritize the following direction (without breaking character): \(trimmedGuidance)")
        }
        return lines.joined(separator: "\n")
    }

    /// App-selected UI language (respects per-app language overrides), falling
    /// back to the user's language list when the bundle can't resolve one.
    private var appLanguageCode: String {
        if let preferred = Bundle.main.preferredLocalizations.first(where: { $0 != "Base" }),
           !preferred.isEmpty {
            return preferred
        }
        return Locale.preferredLanguages.first ?? (Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// True when the app itself is running in Chinese — used for prompt
    /// scaffolding and fallback behavior.
    private var appPrefersChinese: Bool {
        primaryLanguageCode(from: appLanguageCode) == "zh"
    }

    /// Normalizes a raw language code to the form used by the app-language
    /// fallback (collapsing the various zh-* variants).
    private func primaryLanguageCode(from rawCode: String) -> String {
        normalizedLanguageCode(rawCode).split(separator: "-").first.map(String.init) ?? "en"
    }

    private func normalizedLanguageCode(_ rawCode: String) -> String {
        let code = rawCode.replacingOccurrences(of: "_", with: "-")
        let lower = code.lowercased()
        switch lower {
        case "zh-cn", "zh-sg", "zh-hans":
            return "zh-Hans"
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant":
            return "zh-Hant"
        default:
            return code
        }
    }

    /// Tells the model which formatting markers our renderer understands and
    /// which emoji it may reach for. Mirrors `MarkdownCodec`'s grammar — images
    /// are deliberately omitted (the model has no blob ids to reference). The
    /// emoji list is the head of the catalog (ordered classics-first), capped to
    /// ~24 so the prompt stays lean rather than dumping all 178 stickers.
    private func replyFormatGuide(chinese: Bool) -> String {
        let tokens = Array(emojiPromptTokens(limit: 24))
        let example = tokens.first ?? "[赞]"
        if chinese {
            var s = "\n回复支持有限的格式标记，可按需适度使用（非必须）：\n"
            s += "- 粗体：**像这样**\n"
            s += "- 斜体：*像这样*\n"
            s += "- 粗斜体：***像这样***\n"
            s += "- 链接：[显示文字](https://example.com)\n"
            s += "- 表情：直接写出下面列表里的方括号标记，例如 \(example)\n"
            s += "标题、列表、代码块、图片等其它格式不支持（写了也会原样显示，不会生效）。"
            if !tokens.isEmpty {
                s += "\n可用表情（按需挑选，别硬凑）：\(tokens.joined(separator: " "))"
            }
            return s
        }
        var s = "\nReplies support a few formatting markers — use them sparingly when they help (optional):\n"
        s += "- Bold: **like this**\n"
        s += "- Italic: *like this*\n"
        s += "- Bold italic: ***like this***\n"
        s += "- Link: [shown text](https://example.com)\n"
        s += "- Emoji: write one of the bracket tokens from the list below, e.g. \(example)\n"
        s += "Headings, lists, code blocks, images and other markdown are NOT supported (they render literally)."
        if !tokens.isEmpty {
            s += "\nAvailable emoji (pick only what fits, don't force them): \(tokens.joined(separator: " "))"
        }
        return s
    }

    /// The classic emoji set we surface to the model, as the exact `[token]`
    /// the body parser resolves (same form the model already sees in context).
    private func emojiPromptTokens(limit: Int) -> [String] {
        emoji.items.prefix(limit).map(\.placeholder)
    }

    /// Build the reply body: the model's text prefixed with a hidden persona
    /// marker (see `PersonaTag`) so the reply renders with the persona's name +
    /// initial avatar in the header. The model output is treated as a markdown
    /// body (not escaped) so the bold/italic/link/emoji markers it was told it
    /// can use in `replyFormatGuide` actually render. Our parser degrades
    /// gracefully on anything outside that grammar — unmatched markers fall back
    /// to literal text rather than breaking the layout.
    private func personaReplyBody(persona: Persona, text: String,
                                  imageBlobIDs: [String] = []) -> ContentDocument {
        var body = text
        for id in imageBlobIDs {
            if !body.isEmpty { body += "\n" }
            body += "![](blob://\(id))"
        }
        return ContentDocument(body: PersonaTag.wrap(name: persona.name, content: body))
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
