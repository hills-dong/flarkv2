import Foundation

/// Materialized, read-optimized state derived purely from the event log.
/// Deterministic: applying the same set of events in any order yields the
/// same Projection (the reducer sorts by total order).

public struct TopicState: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var authorID: String
    public var body: ContentDocument
    public var createdAt: Int64        // hlc.wallMillis of creating event
    public var replyCount: Int
    public var lastActivity: Int64
    /// HLC of the most recent edit (nil if never edited). Stored for LWW so
    /// out-of-order edit events resolve deterministically.
    public var editHLC: HLC?
    /// wallMillis of the most recent edit (mirrors `editHLC` for display).
    public var editedAt: Int64?
}

/// Lightweight row for the topic list — excludes the heavy `ContentDocument`
/// body so the list array is cheap to build, copy and diff at 10k+ topics.
/// `preview` is a truncated plain-text rendering of the body.
public struct TopicRow: Identifiable, Equatable, Sendable, Codable {
    /// Just the blob ids of a topic's images, in document order. Dimensions
    /// are intentionally omitted — the list renders fixed-size thumbnails.
    public struct Image: Equatable, Sendable, Codable {
        public let blobID: String
    }

    public let id: String
    public let authorID: String
    /// Inline preview segments (text, emoji, styledText) for the list row.
    /// Image segments are excluded — they render as real thumbnails via `images`.
    /// Carries styling info so the list can render bold/italic/links the same
    /// way the topic detail does.
    public let previewSegments: [ContentDocument.Segment]
    public let createdAt: Int64
    public let replyCount: Int
    public let lastActivity: Int64
    /// Non-nil when the topic body has been edited at least once. Used by the
    /// list cell to show a "已编辑" suffix next to the timestamp.
    public let editedAt: Int64?
    /// Topic images for the list thumbnails. Capped so a single huge gallery
    /// can't bloat the snapshotted row map at 10k+ topics.
    public let images: [Image]

    /// Max image thumbnails carried into the list row.
    static let maxRowImages = 9
    /// Soft character cap for the preview run. Keeps the row map cheap on
    /// huge topics while still showing 3-4 lines of body.
    static let previewCharLimit = 200

    static func make(from t: TopicState) -> TopicRow {
        var imgs: [Image] = []
        var segs: [ContentDocument.Segment] = []
        var charCount = 0
        // The editor wraps each inline image with `\n[image]\n` so it lands
        // on its own paragraph. When we hoist images out to the thumbnail
        // row, those wrapping newlines would otherwise survive as a stray
        // blank line in the preview text — strip them on both sides.
        var stripNextLeadingNL = false

        for seg in t.body.segments {
            switch seg {
            case .image(let blobID, _, _):
                imgs.append(Image(blobID: blobID))
                if !segs.isEmpty {
                    switch segs[segs.count - 1] {
                    case .text(let s) where s.hasSuffix("\n"):
                        let t = String(s.dropLast())
                        if t.isEmpty { segs.removeLast() }
                        else { segs[segs.count - 1] = .text(t) }
                        charCount -= 1
                    case .styledText(let s, let style) where s.hasSuffix("\n"):
                        let t = String(s.dropLast())
                        if t.isEmpty { segs.removeLast() }
                        else { segs[segs.count - 1] = .styledText(text: t, style: style) }
                        charCount -= 1
                    default:
                        break
                    }
                }
                stripNextLeadingNL = true
            case .text(let raw):
                var s = raw
                if stripNextLeadingNL, s.hasPrefix("\n") {
                    s = String(s.dropFirst())
                }
                stripNextLeadingNL = false
                if !s.isEmpty, let trimmed = clip(s, used: &charCount) {
                    segs.append(.text(trimmed))
                }
            case .styledText(let raw, let style):
                var s = raw
                if stripNextLeadingNL, s.hasPrefix("\n") {
                    s = String(s.dropFirst())
                }
                stripNextLeadingNL = false
                if !s.isEmpty, let trimmed = clip(s, used: &charCount) {
                    segs.append(.styledText(text: trimmed, style: style))
                }
            case .emoji(let id):
                stripNextLeadingNL = false
                if charCount < previewCharLimit {
                    segs.append(.emoji(id: id)); charCount += 1
                }
            }
        }
        return TopicRow(id: t.id, authorID: t.authorID,
                        previewSegments: segs,
                        createdAt: t.createdAt, replyCount: t.replyCount,
                        lastActivity: t.lastActivity,
                        editedAt: t.editedAt,
                        images: Array(imgs.prefix(maxRowImages)))
    }

    private static func clip(_ s: String, used: inout Int) -> String? {
        let remaining = previewCharLimit - used
        guard remaining > 0 else { return nil }
        if s.count <= remaining {
            used += s.count
            return s
        }
        let cut = s.index(s.startIndex, offsetBy: remaining)
        used += remaining
        return String(s[..<cut])
    }
}

public struct ReplyState: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var topicID: String
    public var authorID: String
    public var body: ContentDocument
    public var createdAt: Int64
    public var editHLC: HLC?
    public var editedAt: Int64?
}

public struct ReactionKey: Hashable, Sendable {
    public let targetID: String
    public let authorID: String
    public let emojiID: String
}

struct ReactionState: Sendable, Codable {
    var removed: Bool
    var hlc: HLC          // last-writer-wins guard
    var targetID: String
    var emojiID: String
    var authorID: String  // kept so the ReactionKey is rebuildable from a snapshot
}

public struct ProfileState: Equatable, Sendable, Codable {
    public var displayName: String
    public var avatarBlobID: String?
    var hlc: HLC
}

/// One emoji bucket on a target, e.g. "👍 ×3 (董, 张, 邵)".
public struct EmojiTally: Identifiable, Equatable, Sendable {
    public var id: String { emojiID }
    public let emojiID: String
    public let authorIDs: [String]
    public var count: Int { authorIDs.count }
}

public struct Projection: Sendable {
    public private(set) var topics: [String: TopicState] = [:]
    public private(set) var replies: [String: ReplyState] = [:]
    public private(set) var profiles: [String: ProfileState] = [:]
    private var reactions: [ReactionKey: ReactionState] = [:]
    /// Event ids already folded in — makes apply idempotent.
    public private(set) var appliedEventIDs: Set<String> = []

    // Incrementally-maintained indices (pure functions of the applied event
    // set → still order-independent and snapshot-friendly). They turn the
    // per-render O(n log n) sort + heavy deep-copy into an O(n) lookup.
    private var topicRowsMap: [String: TopicRow] = [:]
    /// Topic ids ordered by recency: lastActivity desc, id asc tie-break.
    private var topicOrder: [String] = []
    /// reply ids per topic, kept ordered by (createdAt, id).
    private var replyIDsByTopic: [String: [String]] = [:]

    public init() {}

    /// Recency-ordered lightweight rows for the list. No sort, no body copy.
    public var topicRowsByRecency: [TopicRow] {
        topicOrder.compactMap { topicRowsMap[$0] }
    }

    public var topicsByRecency: [TopicState] {
        topicOrder.compactMap { topics[$0] }
    }

    public func replies(forTopic topicID: String) -> [ReplyState] {
        (replyIDsByTopic[topicID] ?? []).compactMap { replies[$0] }
    }

    // MARK: - Index maintenance

    private static func rowOrdered(_ a: TopicRow, before b: TopicRow) -> Bool {
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.id < b.id
    }

    private mutating func setRow(_ row: TopicRow) {
        if topicRowsMap[row.id] != nil { removeRowFromOrder(row.id) }
        topicRowsMap[row.id] = row
        var lo = 0, hi = topicOrder.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if let m = topicRowsMap[topicOrder[mid]], Self.rowOrdered(m, before: row) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        topicOrder.insert(row.id, at: lo)
    }

    private mutating func removeRowFromOrder(_ id: String) {
        if let i = topicOrder.firstIndex(of: id) { topicOrder.remove(at: i) }
    }

    private mutating func removeTopicIndex(_ id: String) {
        topicRowsMap.removeValue(forKey: id)
        removeRowFromOrder(id)
        replyIDsByTopic.removeValue(forKey: id)
    }

    private mutating func indexReply(_ reply: ReplyState) {
        var ids = replyIDsByTopic[reply.topicID] ?? []
        var lo = 0, hi = ids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let m = replies[ids[mid]]
            let before = m.map { $0.createdAt < reply.createdAt
                || ($0.createdAt == reply.createdAt && $0.id < reply.id) } ?? true
            if before { lo = mid + 1 } else { hi = mid }
        }
        ids.insert(reply.id, at: lo)
        replyIDsByTopic[reply.topicID] = ids
    }

    /// Drop a reply and everything derived from it: its slot in the topic
    /// bucket, any reactions targeting it, and the topic's aggregates.
    private mutating func removeReply(_ replyID: String) {
        guard let r = replies.removeValue(forKey: replyID) else { return }
        if var ids = replyIDsByTopic[r.topicID],
           let i = ids.firstIndex(of: replyID) {
            ids.remove(at: i)
            replyIDsByTopic[r.topicID] = ids
        }
        for k in reactions.filter({ $0.value.targetID == replyID }).map(\.key) {
            reactions.removeValue(forKey: k)
        }
        refreshTopic(r.topicID)
    }

    /// Recompute a topic's reply-derived aggregates from the bucket and
    /// refresh its row. Deriving (not incrementing) keeps the fold correct
    /// even when a topic's create event is folded AFTER its replies — which
    /// happens with windowed newest-first loading (PR5).
    private mutating func refreshTopic(_ id: String) {
        guard var t = topics[id] else { return }
        let bucket = replyIDsByTopic[id] ?? []
        t.replyCount = bucket.count
        var last = t.createdAt
        for rid in bucket { if let r = replies[rid] { last = max(last, r.createdAt) } }
        t.lastActivity = last
        topics[id] = t
        setRow(.make(from: t))
    }

    public func displayName(_ authorID: String) -> String {
        profiles[authorID]?.displayName ?? String(authorID.prefix(6))
    }

    /// Active (non-removed) emoji tallies on a target, stable order.
    public func tallies(forTarget targetID: String) -> [EmojiTally] {
        var byEmoji: [String: [String]] = [:]
        for (key, st) in reactions where st.targetID == targetID && !st.removed {
            byEmoji[key.emojiID, default: []].append(key.authorID)
        }
        return byEmoji
            .map { EmojiTally(emojiID: $0.key, authorIDs: $0.value.sorted()) }
            .sorted { $0.emojiID < $1.emojiID }
    }

    public func hasReacted(author: String, target: String, emoji: String) -> Bool {
        let k = ReactionKey(targetID: target, authorID: author, emojiID: emoji)
        return reactions[k].map { !$0.removed } ?? false
    }

    // MARK: - Reduction

    /// Profiles live in per-author files (the file path is the trust
    /// boundary), so they bypass the event signature gate. LWW by file mtime.
    public mutating func applyProfile(authorID: String, displayName: String,
                                      avatarBlobID: String?, stampMillis: Int64) {
        let hlc = HLC(wallMillis: stampMillis, counter: 0, nodeID: authorID)
        if let existing = profiles[authorID], !(hlc > existing.hlc) { return }
        profiles[authorID] = ProfileState(displayName: displayName,
                                          avatarBlobID: avatarBlobID, hlc: hlc)
    }

    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        guard !appliedEventIDs.contains(event.eventID) else { return false }
        appliedEventIDs.insert(event.eventID)

        switch event.payload {
        case .topicCreate(let topicID, let body):
            if topics[topicID] == nil {
                topics[topicID] = TopicState(
                    id: topicID, authorID: event.authorID, body: body,
                    createdAt: event.hlc.wallMillis, replyCount: 0,
                    lastActivity: event.hlc.wallMillis)
                // Replies may already be folded (windowed newest-first) — derive.
                refreshTopic(topicID)
            }

        case .topicDelete(let topicID):
            // Only the topic's own author may delete it. The UI additionally
            // restricts this to topics with no interactions; here we still
            // sweep any replies/reactions defensively in case a reply event
            // is totally-ordered after the delete.
            if let t = topics[topicID], t.authorID == event.authorID {
                topics.removeValue(forKey: topicID)
                for rid in replies.filter({ $0.value.topicID == topicID }).map(\.key) {
                    replies.removeValue(forKey: rid)
                }
                for k in reactions.filter({ $0.value.targetID == topicID }).map(\.key) {
                    reactions.removeValue(forKey: k)
                }
                removeTopicIndex(topicID)
            }

        case .replyCreate(let replyID, let topicID, let body):
            if replies[replyID] == nil {
                let r = ReplyState(
                    id: replyID, topicID: topicID, authorID: event.authorID,
                    body: body, createdAt: event.hlc.wallMillis)
                replies[replyID] = r
                indexReply(r)
                refreshTopic(topicID)   // no-op if the topic isn't folded yet
            }

        case .replyDelete(let replyID):
            // Only the reply's own author may delete it.
            if let r = replies[replyID], r.authorID == event.authorID {
                removeReply(replyID)
            }

        case .topicEdit(let topicID, let body):
            // Author-only. LWW by HLC so out-of-order edits resolve the same
            // on every device.
            if var t = topics[topicID], t.authorID == event.authorID {
                if let prev = t.editHLC, !(event.hlc > prev) { break }
                t.body = body
                t.editHLC = event.hlc
                t.editedAt = event.hlc.wallMillis
                topics[topicID] = t
                setRow(.make(from: t))
            }

        case .replyEdit(let replyID, let body):
            if var r = replies[replyID], r.authorID == event.authorID {
                if let prev = r.editHLC, !(event.hlc > prev) { break }
                r.body = body
                r.editHLC = event.hlc
                r.editedAt = event.hlc.wallMillis
                replies[replyID] = r
            }

        case .reactionSet(let targetID, _, let emojiID, let removed):
            let key = ReactionKey(targetID: targetID, authorID: event.authorID, emojiID: emojiID)
            if let existing = reactions[key], !(event.hlc > existing.hlc) {
                break // older than what we have — LWW keeps newer
            }
            reactions[key] = ReactionState(removed: removed, hlc: event.hlc,
                                           targetID: targetID, emojiID: emojiID,
                                           authorID: event.authorID)

        case .profileUpdate(let name, let avatar):
            if let existing = profiles[event.authorID], !(event.hlc > existing.hlc) {
                break
            }
            profiles[event.authorID] = ProfileState(displayName: name, avatarBlobID: avatar, hlc: event.hlc)
        }
        return true
    }
}

// MARK: - Snapshot serialization

/// `Projection` is a pure fold of the event log, so it can be cached as a
/// local snapshot to skip rebuilding from scratch on every launch. Reactions
/// are stored as an array (the dict key is rebuilt from `ReactionState`); all
/// other state — including the incrementally-maintained indices — round-trips
/// directly, so a restored projection equals one freshly built from events.
extension Projection: Codable {
    enum CodingKeys: String, CodingKey {
        case topics, replies, profiles, reactions, appliedEventIDs
        case topicRowsMap, topicOrder, replyIDsByTopic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        topics = try c.decode([String: TopicState].self, forKey: .topics)
        replies = try c.decode([String: ReplyState].self, forKey: .replies)
        profiles = try c.decode([String: ProfileState].self, forKey: .profiles)
        appliedEventIDs = try c.decode(Set<String>.self, forKey: .appliedEventIDs)
        topicRowsMap = try c.decode([String: TopicRow].self, forKey: .topicRowsMap)
        topicOrder = try c.decode([String].self, forKey: .topicOrder)
        replyIDsByTopic = try c.decode([String: [String]].self, forKey: .replyIDsByTopic)
        let states = try c.decode([ReactionState].self, forKey: .reactions)
        for st in states {
            reactions[ReactionKey(targetID: st.targetID, authorID: st.authorID,
                                  emojiID: st.emojiID)] = st
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(topics, forKey: .topics)
        try c.encode(replies, forKey: .replies)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(appliedEventIDs, forKey: .appliedEventIDs)
        try c.encode(topicRowsMap, forKey: .topicRowsMap)
        try c.encode(topicOrder, forKey: .topicOrder)
        try c.encode(replyIDsByTopic, forKey: .replyIDsByTopic)
        try c.encode(Array(reactions.values), forKey: .reactions)
    }
}

public enum MergeReducer {
    /// Bumped whenever reducer semantics or projected state shape change.
    /// Persisted in a snapshot; a mismatch forces a full rebuild from the
    /// (immutable, always-authoritative) event log.
    public static let reducerFingerprint = "v7-strip-image-gutter-newlines"

    /// Fold a batch of events into a projection. Unauthentic events are
    /// dropped. Order-independent: events are globally sorted first.
    public static func reduce(_ projection: inout Projection, events: [Event]) {
        let valid = events.filter { $0.isAuthentic() }.sorted(by: Event.order)
        for e in valid { projection.apply(e) }
    }

    /// Same as `reduce` but skips Ed25519 verification. The caller MUST have
    /// already verified authenticity — `SyncEngine.sync` verifies on pull and
    /// local events are signed at creation. Avoids verifying every event
    /// twice (the dominant cold-start CPU cost at 10k+ events). `apply` stays
    /// idempotent via `appliedEventIDs`, so re-delivery is still safe.
    public static func reduceTrusted(_ projection: inout Projection, events: [Event]) {
        for e in events.sorted(by: Event.order) { projection.apply(e) }
    }

    public static func build(from events: [Event]) -> Projection {
        var p = Projection()
        reduce(&p, events: events)
        return p
    }
}
