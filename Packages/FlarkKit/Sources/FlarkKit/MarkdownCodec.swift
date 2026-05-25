import Foundation

/// Inline text styling. OptionSet so bold + italic can coexist on the same
/// run (`***bold-italic***`).
public struct Style: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = Style(rawValue: 1 << 0)
    public static let italic = Style(rawValue: 1 << 1)
}

/// Renderer-side intermediate produced by `MarkdownCodec.parse`. The
/// persisted form is `ContentDocument.body: String` — runs only exist in
/// memory while the renderer composes an attributed string or the editor
/// round-trips its NSAttributedString.
public enum Run: Equatable, Sendable {
    case text(String)
    case styled(String, Style)
    case emoji(id: String)
    /// Image referenced by content-addressed blob hash. Pixel dimensions are
    /// intentionally absent from the persisted form — renderers decode the
    /// blob bytes and use the intrinsic size.
    case image(blobID: String)
    case link(text: String, url: String)
}

/// Parser + serializer for our markdown-flavoured content body. See
/// `Doc/markdown-format.md` in spirit:
///
///     **bold**         *italic*         ***bold-italic***
///     [alias]                                  -- emoji
///     [text](url)                              -- link
///     ![](blob://<sha256-hex>)                 -- image
///     \\ \* \[ \] \( \)                        -- escape
///
/// Round-trip invariant: `parse(serialize(runs)) == runs` for any `runs`
/// produced by `parse`. The serializer escapes aggressively (always `\`, `*`,
/// `[`, `]` in text runs) so the round-trip is stable even when user content
/// contains markdown-significant characters.
public enum MarkdownCodec {

    // MARK: - Parse

    public static func parse(_ s: String, catalog: EmojiCatalog) -> [Run] {
        var p = Parser(chars: Array(s), catalog: catalog)
        return p.parse()
    }

    // MARK: - Serialize

    public static func serialize(_ runs: [Run]) -> String {
        var out = ""
        for run in runs {
            switch run {
            case .text(let s):
                out += escape(s)
            case .styled(let s, let style):
                let body = escape(s)
                if style.contains(.bold) && style.contains(.italic) { out += "***\(body)***" }
                else if style.contains(.bold) { out += "**\(body)**" }
                else if style.contains(.italic) { out += "*\(body)*" }
                else { out += body }
            case .emoji(let id):
                // Emoji ids are alphanumeric + underscore in the catalog, so
                // they don't need escaping inside `[...]`.
                out += "[\(id)]"
            case .image(let blob):
                out += "![](blob://\(blob))"
            case .link(let text, let url):
                out += "[\(escape(text))](\(escapeURL(url)))"
            }
        }
        return out
    }

    /// Escape user text so it survives parse → serialize unchanged.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\", "*", "[", "]":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    private static func escapeURL(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\", ")":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// Extract blob ids from a body without a full parse. Used by upload/GC
    /// bookkeeping so callers don't have to keep a catalog handy.
    public static func blobIDs(in body: String) -> [String] {
        // Match `![<alt>](blob://<hash>)` allowing escaped chars in alt.
        // Hash is sha256 hex (64 chars); accept any non-`)` chars and trust
        // the writer to have produced well-formed bodies.
        guard let re = try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(blob://([^)\n]+)\)"#) else { return [] }
        let ns = body as NSString
        let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }
}

private struct Parser {
    let chars: [Character]
    let catalog: EmojiCatalog
    var i: Int = 0
    var textBuf: String = ""
    var runs: [Run] = []

    mutating func parse() -> [Run] {
        while i < chars.count {
            let ch = chars[i]

            // Backslash escape: `\X` where X is one of the special chars
            // becomes literal X. Unknown escapes keep both bytes — that way
            // arbitrary user content doesn't silently lose backslashes.
            if ch == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if "\\*[]()!".contains(next) {
                    textBuf.append(next)
                    i += 2
                    continue
                }
            }

            // Emphasis: *, **, ***
            if ch == "*" {
                if let run = tryEmphasis() {
                    flushText()
                    runs.append(run)
                    continue
                }
            }

            // Image: ![alt](url)
            if ch == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                if let img = tryImage() {
                    flushText()
                    runs.append(img)
                    continue
                }
            }

            // Link or emoji: [text](url) or [alias]
            if ch == "[" {
                if let link = tryLink() {
                    flushText()
                    runs.append(link)
                    continue
                }
                if let emoji = tryEmoji() {
                    flushText()
                    runs.append(emoji)
                    continue
                }
            }

            // Plain literal character.
            textBuf.append(ch)
            i += 1
        }
        flushText()
        return runs
    }

    mutating func flushText() {
        if !textBuf.isEmpty {
            runs.append(.text(textBuf))
            textBuf = ""
        }
    }

    /// Attempt to parse a `*…*` / `**…**` / `***…***` run at `i`. On success
    /// advances `i` past the closing delimiter; on failure leaves `i` alone.
    mutating func tryEmphasis() -> Run? {
        let start = i
        var open = 0
        while i < chars.count, chars[i] == "*", open < 3 {
            open += 1
            i += 1
        }
        // Try the longest plausible delimiter first; if the close run doesn't
        // exist, fall back to a shorter one. Any leading "extra" stars become
        // literal text.
        let attempts: [Int] = (1...min(open, 3)).reversed()
        for delim in attempts {
            let leadingLiteral = open - delim
            let contentStart = start + leadingLiteral + delim
            var j = contentStart
            while j < chars.count {
                if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
                if chars[j] == "*" {
                    var k = j
                    while k < chars.count, chars[k] == "*" { k += 1 }
                    let closeCount = k - j
                    if closeCount >= delim, j > contentStart {
                        let content = String(chars[contentStart..<j])
                        // Empty content shouldn't happen (we required `j > contentStart`),
                        // but keep the guard explicit.
                        guard !content.isEmpty else { j = k; continue }
                        var style: Style = []
                        switch delim {
                        case 1: style = [.italic]
                        case 2: style = [.bold]
                        case 3: style = [.bold, .italic]
                        default: break
                        }
                        if leadingLiteral > 0 {
                            textBuf.append(String(repeating: "*", count: leadingLiteral))
                        }
                        i = j + delim
                        // Unescape backslash sequences inside the content
                        // (the user-typed body uses `\*` to mean a literal
                        // `*` even inside an emphasised run).
                        return .styled(unescape(content), style)
                    }
                    j = k
                    continue
                }
                j += 1
            }
        }
        i = start
        return nil
    }

    /// `![alt](blob://<hash>)`. Alt content is discarded — image dimensions
    /// are decoded from the blob bytes at render time, not stored in the body.
    mutating func tryImage() -> Run? {
        let start = i
        // Skip past "!["
        var j = start + 2
        while j < chars.count, chars[j] != "]" {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
            if chars[j] == "\n" { return nil }
            j += 1
        }
        guard j < chars.count, j + 1 < chars.count, chars[j + 1] == "(" else { return nil }
        let urlStart = j + 2
        var k = urlStart
        while k < chars.count, chars[k] != ")" {
            if chars[k] == "\\", k + 1 < chars.count { k += 2; continue }
            if chars[k] == "\n" { return nil }
            k += 1
        }
        guard k < chars.count else { return nil }
        let url = unescape(String(chars[urlStart..<k]))
        let prefix = "blob://"
        guard url.hasPrefix(prefix) else { return nil }
        let blob = String(url.dropFirst(prefix.count))
        guard !blob.isEmpty else { return nil }
        i = k + 1
        return .image(blobID: blob)
    }

    /// `[text](url)`. Empty text or url is rejected so emoji parsing gets a
    /// shot at the bracket pair next.
    mutating func tryLink() -> Run? {
        let start = i
        var j = start + 1
        while j < chars.count, chars[j] != "]" {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
            if chars[j] == "\n" || chars[j] == "[" { return nil }
            j += 1
        }
        guard j < chars.count, j + 1 < chars.count, chars[j + 1] == "(" else { return nil }
        let urlStart = j + 2
        var k = urlStart
        while k < chars.count, chars[k] != ")" {
            if chars[k] == "\\", k + 1 < chars.count { k += 2; continue }
            if chars[k] == "\n" { return nil }
            k += 1
        }
        guard k < chars.count else { return nil }
        let text = unescape(String(chars[(start + 1)..<j]))
        let url = unescape(String(chars[urlStart..<k]))
        guard !text.isEmpty, !url.isEmpty else { return nil }
        i = k + 1
        return .link(text: text, url: url)
    }

    /// `[alias]` — only accepted if `alias` resolves in the emoji catalog.
    /// Unknown aliases fall through to literal-text handling so user-typed
    /// `[anything]` is preserved verbatim.
    mutating func tryEmoji() -> Run? {
        let start = i
        var j = start + 1
        while j < chars.count, chars[j] != "]" {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
            if chars[j] == "\n" || chars[j] == "[" { return nil }
            // Cap the inner span so a long `[...]` block can't drag the
            // emoji probe across an entire paragraph.
            if j - start > 32 { return nil }
            j += 1
        }
        guard j < chars.count else { return nil }
        let raw = unescape(String(chars[(start + 1)..<j]))
        guard let item = catalog.item(alias: raw) else { return nil }
        i = j + 1
        return .emoji(id: item.id)
    }

    private func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch == "\\", let nxt = it.next() {
                out.append(nxt)
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
