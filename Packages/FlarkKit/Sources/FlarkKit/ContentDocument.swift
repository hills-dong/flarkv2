import Foundation

/// Rich-but-simple content model shared by the editor and renderers.
/// No complex styling — only inline text, emoji and images, in order.
public struct ContentDocument: Codable, Equatable, Sendable {
    public enum TextStyle: String, Codable, Sendable, Equatable {
        case bold
        case italic
    }

    public enum Segment: Codable, Equatable, Sendable {
        case text(String)
        /// An emoji from the Lark-style catalog, referenced by its manifest id.
        case emoji(id: String)
        /// An image stored as a content-addressed blob (sha256 hex).
        case image(blobID: String, width: Int, height: Int)
        /// A run of text rendered with bold/italic emphasis.
        case styledText(text: String, style: TextStyle)

        private enum Kind: String, Codable { case text, emoji, image, styledText }
        private enum CodingKeys: String, CodingKey { case kind, text, id, blobID, width, height, style }

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
            case .styledText:
                self = .styledText(
                    text: try c.decode(String.self, forKey: .text),
                    style: try c.decode(TextStyle.self, forKey: .style)
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
            case .styledText(let t, let style):
                try c.encode(Kind.styledText, forKey: .kind)
                try c.encode(t, forKey: .text)
                try c.encode(style, forKey: .style)
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
            if case .styledText(let s, _) = $0 { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    /// Plain-text projection used for list previews and accessibility.
    /// Emoji segments render as `[id]` when no catalog is available; pass one
    /// to `plainText(catalog:)` for the human-friendly `[笑哭]` form.
    public var plainText: String {
        segments.reduce(into: "") { acc, seg in
            switch seg {
            case .text(let s): acc += s
            case .styledText(let s, _): acc += s
            case .emoji(let id): acc += "[\(id)]"
            case .image: acc += "[图片]"
            }
        }
    }

    /// Plain-text projection that renders emoji segments as their canonical
    /// human placeholder (`[笑哭]`) via the supplied catalog. Falls back to
    /// `[id]` when the catalog doesn't know the id.
    public func plainText(catalog: EmojiCatalog) -> String {
        segments.reduce(into: "") { acc, seg in
            switch seg {
            case .text(let s): acc += s
            case .styledText(let s, _): acc += s
            case .emoji(let id): acc += catalog.item(id)?.placeholder ?? "[\(id)]"
            case .image: acc += "[图片]"
            }
        }
    }

    /// Parse a plain string into segments, converting recognised `[xxx]`
    /// placeholders (zh-CN name, en-US name, or id) into `.emoji` segments via
    /// `catalog.item(alias:)`. Bracketed substrings the catalog doesn't
    /// recognise are kept verbatim as text.
    public static func parsing(_ text: String, catalog: EmojiCatalog) -> ContentDocument {
        guard !text.isEmpty else { return ContentDocument() }
        // Lark md exports escape both brackets (`\[笑哭\]`); consume optional
        // leading + trailing backslashes so the whole `\[…\]` run is replaced.
        let pattern = #"\\?\[([^\[\]\\\n]{1,30})\\?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ContentDocument(text: text)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var segments: [Segment] = []
        var cursor = 0
        for m in matches {
            let inner = ns.substring(with: m.range(at: 1))
            guard let item = catalog.item(alias: inner) else { continue }
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor,
                                                       length: m.range.location - cursor))
                if !chunk.isEmpty { segments.append(.text(chunk)) }
            }
            segments.append(.emoji(id: item.id))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !tail.isEmpty { segments.append(.text(tail)) }
        }
        return ContentDocument(segments: segments)
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
