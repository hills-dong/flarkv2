import Foundation

/// Rich-but-simple content model shared by the editor and renderers.
/// No complex styling — only inline text, emoji and images, in order.
public struct ContentDocument: Codable, Equatable, Sendable {
    public enum Segment: Codable, Equatable, Sendable {
        case text(String)
        /// An emoji from the Lark-style catalog, referenced by its manifest id.
        case emoji(id: String)
        /// An image stored as a content-addressed blob (sha256 hex).
        case image(blobID: String, width: Int, height: Int)

        private enum Kind: String, Codable { case text, emoji, image }
        private enum CodingKeys: String, CodingKey { case kind, text, id, blobID, width, height }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .text:
                self = .text(try c.decode(String.self, forKey: .text))
            case .emoji:
                self = .emoji(id: try c.decode(String.self, forKey: .id))
            case .image:
                self = .image(
                    blobID: try c.decode(String.self, forKey: .blobID),
                    width: try c.decodeIfPresent(Int.self, forKey: .width) ?? 0,
                    height: try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode(Kind.text, forKey: .kind)
                try c.encode(s, forKey: .text)
            case .emoji(let id):
                try c.encode(Kind.emoji, forKey: .kind)
                try c.encode(id, forKey: .id)
            case .image(let blobID, let w, let h):
                try c.encode(Kind.image, forKey: .kind)
                try c.encode(blobID, forKey: .blobID)
                try c.encode(w, forKey: .width)
                try c.encode(h, forKey: .height)
            }
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }

    public init(text: String) {
        self.segments = text.isEmpty ? [] : [.text(text)]
    }

    public var isEmpty: Bool {
        segments.allSatisfy {
            if case .text(let s) = $0 { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    /// Plain-text projection used for list previews and accessibility.
    public var plainText: String {
        segments.reduce(into: "") { acc, seg in
            switch seg {
            case .text(let s): acc += s
            case .emoji(let id): acc += "[\(id)]"
            case .image: acc += "[图片]"
            }
        }
    }

    /// Referenced blob ids (for upload/gc).
    public var blobIDs: [String] {
        segments.compactMap {
            if case .image(let id, _, _) = $0 { return id }
            return nil
        }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ContentDocument {
        try JSONDecoder().decode(ContentDocument.self, from: data)
    }
}
