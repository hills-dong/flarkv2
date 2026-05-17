import Foundation

/// One entry in the Lark-style emoji/sticker library. `file` is optional:
/// until the user drops real Lark images into Resources/Emoji, `unicode`
/// renders a tasteful fallback so the whole app still works.
public struct EmojiItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var file: String?
    public var unicode: String?
    public var category: String        // e.g. "most_used", "default"
    public var keywords: [String]

    public init(id: String, file: String? = nil, unicode: String? = nil,
                category: String, keywords: [String] = []) {
        self.id = id; self.file = file; self.unicode = unicode
        self.category = category; self.keywords = keywords
    }
}

public struct EmojiManifest: Codable, Sendable {
    public var items: [EmojiItem]
}

public final class EmojiCatalog: @unchecked Sendable {
    public private(set) var items: [EmojiItem]
    private var byID: [String: EmojiItem]

    public init(items: [EmojiItem]) {
        self.items = items
        self.byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Load from a manifest.json URL; falls back to the built-in set on failure.
    public static func load(manifestURL: URL?) -> EmojiCatalog {
        guard let url = manifestURL,
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(EmojiManifest.self, from: data),
              !manifest.items.isEmpty else {
            return EmojiCatalog(items: builtIn)
        }
        return EmojiCatalog(items: manifest.items)
    }

    public func item(_ id: String) -> EmojiItem? { byID[id] }

    public func category(_ name: String) -> [EmojiItem] {
        items.filter { $0.category == name }
    }

    public var categories: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.category) { seen.append(i.category) }
        return seen
    }

    /// Built-in Unicode fallback, grouped to mirror Lark's picker sections.
    public static let builtIn: [EmojiItem] = {
        func mk(_ list: [(String, String)], _ cat: String) -> [EmojiItem] {
            list.map { EmojiItem(id: $0.0, unicode: $0.1, category: cat, keywords: [$0.0]) }
        }
        return mk([("u_thumbsup","👍"),("u_pray","🙏"),("u_check","✅"),
                   ("u_fire","🔥"),("u_joy","😂"),("u_party","🎉")], "most_used")
        + mk([("u_grin","😀"),("u_smile","😊"),("u_sweat","😅"),("u_handshake","🤝"),
               ("u_eyes","👀"),("u_bulb","💡"),("u_rocket","🚀"),("u_warn","⚠️"),
               ("u_heart","❤️"),("u_cry","😭"),("u_think","🤔"),("u_clap","👏"),
               ("u_raise","🙌"),("u_muscle","💪"),("u_spark","✨"),("u_celebrate","🥳"),
               ("u_cool","😎"),("u_salute","🫡")], "default")
        + mk([("lark_ok","🆗"),("lark_plus1","💯"),("lark_yes","✔️"),
               ("lark_done","✅"),("lark_no","❌"),("lark_get","📥")], "lark")
    }()
}
