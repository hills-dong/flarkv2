import Foundation

/// One entry in the Lark-style sticker library. The image at `file` is the
/// rendered glyph; `nameZh`/`nameEn` are display names; `aliases` is the set
/// of strings a placeholder parser will accept (e.g. ["笑哭", "LOL", "lol"]
/// all resolve to the same item).
public struct EmojiItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var file: String
    public var nameZh: String
    public var nameEn: String
    public var aliases: [String]
    public var category: String        // "most_used" / "default"
    public var keywords: [String]

    public init(id: String, file: String, nameZh: String = "", nameEn: String = "",
                aliases: [String] = [], category: String = "default",
                keywords: [String] = []) {
        self.id = id; self.file = file
        self.nameZh = nameZh; self.nameEn = nameEn
        self.aliases = aliases
        self.category = category; self.keywords = keywords
    }

    /// Canonical inline placeholder text for use in plain-text projections,
    /// e.g. `[笑哭]` if a zh-CN name exists, else `[LOL]`, else `[id]`.
    public var placeholder: String {
        let inner = !nameZh.isEmpty ? nameZh : (!nameEn.isEmpty ? nameEn : id)
        return "[\(inner)]"
    }
}

public struct EmojiManifest: Codable, Sendable {
    /// Seed IDs the picker shows in `最常使用` before the user has any local
    /// usage history — purely so the row isn't empty on first launch. Once the
    /// user picks anything, their own picks rank ahead of these.
    public var defaultMostUsed: [String] = []
    public var items: [EmojiItem]
}

public final class EmojiCatalog: @unchecked Sendable {
    public private(set) var items: [EmojiItem]
    public let seedMostUsedIDs: [String]
    private let byID: [String: EmojiItem]
    /// Lowercased alias → id, for case-insensitive placeholder lookup.
    private let aliasIndex: [String: String]

    public init(items: [EmojiItem], seedMostUsedIDs: [String] = []) {
        self.items = items
        self.seedMostUsedIDs = seedMostUsedIDs
        self.byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var idx: [String: String] = [:]
        for item in items {
            for alias in item.aliases + [item.id, item.nameZh, item.nameEn] where !alias.isEmpty {
                idx[alias.lowercased(), default: item.id] = item.id
            }
        }
        self.aliasIndex = idx
    }

    /// Load from a manifest.json URL; returns an empty catalog on failure
    /// (no built-in fallback — picker/glyph show a "missing" state instead).
    public static func load(manifestURL: URL?) -> EmojiCatalog {
        guard let url = manifestURL,
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(EmojiManifest.self, from: data) else {
            return EmojiCatalog(items: [])
        }
        return EmojiCatalog(items: manifest.items, seedMostUsedIDs: manifest.defaultMostUsed)
    }

    public func item(_ id: String) -> EmojiItem? { byID[id] }

    /// Resolve `[笑哭]`, `笑哭`, `LOL`, `lol` — anything in the alias set —
    /// to the canonical item. Brackets are stripped if present.
    public func item(alias raw: String) -> EmojiItem? {
        var s = raw
        if s.hasPrefix("["), s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        guard let id = aliasIndex[s.lowercased()] else { return nil }
        return byID[id]
    }

    public func category(_ name: String) -> [EmojiItem] {
        items.filter { $0.category == name }
    }

    public var categories: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.category) { seen.append(i.category) }
        return seen
    }
}
