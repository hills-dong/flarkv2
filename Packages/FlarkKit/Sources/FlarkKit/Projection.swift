import Foundation

/// Materialized, read-optimized state derived purely from the event log.
/// Deterministic: applying the same set of events in any order yields the
/// same Projection (the reducer sorts by total order).

public struct TopicState: Identifiable, Equatable, Sendable {
    public let id: String
    public var authorID: String
    public var title: String
    public var body: ContentDocument
    public var createdAt: Int64        // hlc.wallMillis of creating event
    public var replyCount: Int
    public var lastActivity: Int64
}

public struct ReplyState: Identifiable, Equatable, Sendable {
    public let id: String
    public var topicID: String
    public var authorID: String
    public var body: ContentDocument
    public var createdAt: Int64
}

public struct ReactionKey: Hashable, Sendable {
    public let targetID: String
    public let authorID: String
    public let emojiID: String
}

struct ReactionState: Sendable {
    var removed: Bool
    var hlc: HLC          // last-writer-wins guard
    var targetID: String
    var emojiID: String
}

public struct ProfileState: Equatable, Sendable {
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

    public init() {}

    public var topicsByRecency: [TopicState] {
        topics.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    public func replies(forTopic topicID: String) -> [ReplyState] {
        replies.values
            .filter { $0.topicID == topicID }
            .sorted { $0.createdAt < $1.createdAt }
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
        case .topicCreate(let topicID, let title, let body):
            if topics[topicID] == nil {
                topics[topicID] = TopicState(
                    id: topicID, authorID: event.authorID, title: title, body: body,
                    createdAt: event.hlc.wallMillis, replyCount: 0,
                    lastActivity: event.hlc.wallMillis)
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
            }

        case .replyCreate(let replyID, let topicID, let body):
            if replies[replyID] == nil {
                replies[replyID] = ReplyState(
                    id: replyID, topicID: topicID, authorID: event.authorID,
                    body: body, createdAt: event.hlc.wallMillis)
                if var t = topics[topicID] {
                    t.replyCount += 1
                    t.lastActivity = max(t.lastActivity, event.hlc.wallMillis)
                    topics[topicID] = t
                }
            }

        case .reactionSet(let targetID, _, let emojiID, let removed):
            let key = ReactionKey(targetID: targetID, authorID: event.authorID, emojiID: emojiID)
            if let existing = reactions[key], !(event.hlc > existing.hlc) {
                break // older than what we have — LWW keeps newer
            }
            reactions[key] = ReactionState(removed: removed, hlc: event.hlc,
                                           targetID: targetID, emojiID: emojiID)

        case .profileUpdate(let name, let avatar):
            if let existing = profiles[event.authorID], !(event.hlc > existing.hlc) {
                break
            }
            profiles[event.authorID] = ProfileState(displayName: name, avatarBlobID: avatar, hlc: event.hlc)
        }
        return true
    }
}

public enum MergeReducer {
    /// Fold a batch of events into a projection. Unauthentic events are
    /// dropped. Order-independent: events are globally sorted first.
    public static func reduce(_ projection: inout Projection, events: [Event]) {
        let valid = events.filter { $0.isAuthentic() }.sorted(by: Event.order)
        for e in valid { projection.apply(e) }
    }

    public static func build(from events: [Event]) -> Projection {
        var p = Projection()
        reduce(&p, events: events)
        return p
    }
}
