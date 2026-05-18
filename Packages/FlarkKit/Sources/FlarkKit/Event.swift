import Foundation

public enum TargetType: String, Codable, Sendable { case topic, reply }

/// The append-only, signed unit of replication. Every change in a Space is an
/// Event. Events are immutable; conflicts are resolved by the reducer, not by
/// mutating files — which is what lets WebDAV work with no server arbiter.
public struct Event: Codable, Equatable, Sendable {
    public enum Payload: Codable, Equatable, Sendable {
        case topicCreate(topicID: String, body: ContentDocument)
        /// Delete a topic. Honored by the reducer only when the deleting author
        /// is the topic's author; the UI further restricts this to topics with
        /// no interactions (no replies, no reactions).
        case topicDelete(topicID: String)
        case replyCreate(replyID: String, topicID: String, body: ContentDocument)
        /// Delete a reply. Honored by the reducer only when the deleting
        /// author is the reply's own author.
        case replyDelete(replyID: String)
        /// Set (add/remove unified) — one author toggling one emoji on one target.
        case reactionSet(targetID: String, targetType: TargetType, emojiID: String, removed: Bool)
        case profileUpdate(displayName: String, avatarBlobID: String?)

        private enum Kind: String, Codable { case topicCreate, topicDelete, replyCreate, replyDelete, reactionSet, profileUpdate }
        private enum K: String, CodingKey {
            case kind, topicID, replyID, body, targetID, targetType, emojiID, removed, displayName, avatarBlobID
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .topicCreate:
                self = .topicCreate(topicID: try c.decode(String.self, forKey: .topicID),
                                    body: try c.decode(ContentDocument.self, forKey: .body))
            case .topicDelete:
                self = .topicDelete(topicID: try c.decode(String.self, forKey: .topicID))
            case .replyCreate:
                self = .replyCreate(replyID: try c.decode(String.self, forKey: .replyID),
                                    topicID: try c.decode(String.self, forKey: .topicID),
                                    body: try c.decode(ContentDocument.self, forKey: .body))
            case .replyDelete:
                self = .replyDelete(replyID: try c.decode(String.self, forKey: .replyID))
            case .reactionSet:
                self = .reactionSet(targetID: try c.decode(String.self, forKey: .targetID),
                                    targetType: try c.decode(TargetType.self, forKey: .targetType),
                                    emojiID: try c.decode(String.self, forKey: .emojiID),
                                    removed: try c.decode(Bool.self, forKey: .removed))
            case .profileUpdate:
                self = .profileUpdate(displayName: try c.decode(String.self, forKey: .displayName),
                                      avatarBlobID: try c.decodeIfPresent(String.self, forKey: .avatarBlobID))
            }
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: K.self)
            switch self {
            case .topicCreate(let id, let body):
                try c.encode(Kind.topicCreate, forKey: .kind)
                try c.encode(id, forKey: .topicID)
                try c.encode(body, forKey: .body)
            case .topicDelete(let id):
                try c.encode(Kind.topicDelete, forKey: .kind)
                try c.encode(id, forKey: .topicID)
            case .replyCreate(let rid, let tid, let body):
                try c.encode(Kind.replyCreate, forKey: .kind)
                try c.encode(rid, forKey: .replyID)
                try c.encode(tid, forKey: .topicID)
                try c.encode(body, forKey: .body)
            case .replyDelete(let rid):
                try c.encode(Kind.replyDelete, forKey: .kind)
                try c.encode(rid, forKey: .replyID)
            case .reactionSet(let tid, let tt, let emoji, let removed):
                try c.encode(Kind.reactionSet, forKey: .kind)
                try c.encode(tid, forKey: .targetID)
                try c.encode(tt, forKey: .targetType)
                try c.encode(emoji, forKey: .emojiID)
                try c.encode(removed, forKey: .removed)
            case .profileUpdate(let name, let avatar):
                try c.encode(Kind.profileUpdate, forKey: .kind)
                try c.encode(name, forKey: .displayName)
                try c.encodeIfPresent(avatar, forKey: .avatarBlobID)
            }
        }
    }

    public let eventID: String        // uuid
    public let hlc: HLC
    public let authorID: String       // == base32(sha256(publicKey))
    public let publicKey: Data        // raw Ed25519 public key
    public let spaceID: String
    public let payload: Payload
    public var signature: Data

    public init(eventID: String = UUID().uuidString,
                hlc: HLC,
                authorID: String,
                publicKey: Data,
                spaceID: String,
                payload: Payload,
                signature: Data = Data()) {
        self.eventID = eventID
        self.hlc = hlc
        self.authorID = authorID
        self.publicKey = publicKey
        self.spaceID = spaceID
        self.payload = payload
        self.signature = signature
    }

    /// Stable bytes that the signature covers (everything except the signature).
    func signingData() throws -> Data {
        var copy = self
        copy.signature = Data()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(copy)
    }

    public mutating func sign(with identity: DeviceIdentity) throws {
        signature = identity.sign(try signingData())
    }

    /// True only if the signature is valid AND the author id is the hash of
    /// the embedded public key (prevents impersonation).
    public func isAuthentic() -> Bool {
        guard authorID == DeviceIdentity.authorID(forPublicKey: publicKey),
              let data = try? signingData() else { return false }
        return DeviceIdentity.verify(signature, of: data, publicKey: publicKey)
    }

    /// Total order across the whole Space.
    public static func order(_ a: Event, _ b: Event) -> Bool {
        if a.hlc != b.hlc { return a.hlc < b.hlc }
        return a.eventID < b.eventID
    }
}
