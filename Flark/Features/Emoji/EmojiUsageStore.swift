import Foundation

/// Per-account local tally of how often (and how recently) each emoji ID has
/// been chosen by the user. Drives the picker's `最常使用` shortcut row — it
/// starts empty and grows as the user reacts / inserts emoji.
///
/// Ranking blends frequency with recency via exponential decay so an emoji
/// the user spammed a year ago doesn't outweigh one they reach for daily.
@MainActor
struct EmojiUsageStore {
    private struct Entry: Codable {
        var count: Int
        var lastUsedAt: TimeInterval
    }

    private let accountID: String
    /// 14-day half-life: a tap is worth half as much two weeks later.
    private let halfLife: TimeInterval = 14 * 24 * 3600

    init(accountID: String) { self.accountID = accountID }

    private var key: String { "flark.emoji.usage.\(accountID)" }

    private func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func record(_ id: String) {
        var entries = load()
        var e = entries[id] ?? Entry(count: 0, lastUsedAt: 0)
        e.count += 1
        e.lastUsedAt = Date().timeIntervalSince1970
        entries[id] = e
        save(entries)
    }

    /// IDs sorted by `count × recency-decay`, capped at `limit`.
    func topIDs(limit: Int) -> [String] {
        let now = Date().timeIntervalSince1970
        return load()
            .map { (id, e) -> (String, Double) in
                let age = max(0, now - e.lastUsedAt)
                let weight = pow(0.5, age / halfLife)
                return (id, Double(e.count) * weight)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
