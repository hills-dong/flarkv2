import Foundation

/// Rich-but-simple content document. The persisted form is a single markdown
/// body — see `MarkdownCodec` for the grammar (bold/italic/emoji/image/link
/// plus backslash escapes). Renderers parse the body into `[Run]` on demand;
/// nothing else about the doc lives on disk.
public struct ContentDocument: Codable, Equatable, Sendable {
    /// Markdown-flavoured body. May be empty.
    public var body: String

    /// Construct a doc directly from a markdown body. Callers that already
    /// hold serialized markdown (e.g. the editor after `MarkdownCodec.serialize`)
    /// use this.
    public init(body: String = "") {
        self.body = body
    }

    /// Construct a doc from a plain (un-escaped) string. Special markdown
    /// characters get escaped so `ContentDocument(text: "a*b")` round-trips
    /// to a literal `a*b`, not an italic run.
    public init(text: String) {
        self.body = MarkdownCodec.escape(text)
    }

    public var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Referenced blob ids (for upload/GC). Cheap regex scan — no catalog
    /// needed.
    public var blobIDs: [String] {
        MarkdownCodec.blobIDs(in: body)
    }

    /// Plain-text projection used for accessibility / debug logs. Strips
    /// markdown markers; emojis render as their `[id]` placeholder, images
    /// as `[图片]`. Pass a catalog via `plainText(catalog:)` for the
    /// human-friendly `[笑哭]` form.
    public var plainText: String {
        // Trivial scan: drop markdown tokens. For now we keep it simple and
        // route through a catalog-less parse using an empty catalog so emoji
        // tokens fall back to literal text.
        plainText(catalog: EmojiCatalog(items: []))
    }

    public func plainText(catalog: EmojiCatalog) -> String {
        let runs = MarkdownCodec.parse(body, catalog: catalog)
        var out = ""
        for run in runs {
            switch run {
            case .text(let s): out += s
            case .styled(let s, _): out += s
            case .emoji(let id):
                if let item = catalog.item(id) { out += item.placeholder }
                else { out += "[\(id)]" }
            case .image: out += "[图片]"
            case .link(let text, _): out += text
            }
        }
        return out
    }

    /// Convenience for callers that want the parsed runs.
    public func runs(catalog: EmojiCatalog) -> [Run] {
        MarkdownCodec.parse(body, catalog: catalog)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ContentDocument {
        try JSONDecoder().decode(ContentDocument.self, from: data)
    }
}
