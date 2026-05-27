import Foundation
import SwiftUI

/// User-selectable visual emoji pack. The catalog (ids, aliases, names,
/// most-used seeds) is shared across packs — the pack only swaps which
/// image file each `EmojiItem.file` resolves to on disk.
enum EmojiPack: String, CaseIterable, Identifiable {
    case lark
    case elfGirl = "elf_girl"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .lark: return "北欧精灵"
        case .elfGirl: return "北欧精灵女孩"
        }
    }

    /// Subdirectory inside `Resources/Emoji/` that holds this pack's images.
    /// Manifest items always store their `file` as `lark/<name>.png` (the
    /// canonical naming); other packs ship a same-named file under their
    /// own folder so a simple prefix swap retargets the load.
    var directory: String { rawValue }
}

enum AppSettingsKeys {
    static let emojiPack = "flark.emojiPack"
    static let emojiFlightEnabled = "flark.emojiFlightEnabled"
}

/// Resolves a manifest-declared emoji file path (e.g. `"lark/lol.png"`)
/// to the on-disk file path for the currently-selected pack. Reads the
/// pack from `UserDefaults` so it works inside non-view helpers
/// (`loadEmojiImage`, `emojiAttachmentString`, `EmojiPickerFlight`).
enum EmojiPackResolver {
    static var currentPack: EmojiPack {
        let raw = UserDefaults.standard.string(forKey: AppSettingsKeys.emojiPack)
            ?? EmojiPack.lark.rawValue
        return EmojiPack(rawValue: raw) ?? .lark
    }

    /// Swap the manifest's `lark/<name>.png` prefix for the active pack's
    /// directory. Anything that doesn't match the `lark/` prefix is returned
    /// unchanged (so custom non-pack assets still resolve).
    static func resolvedFile(_ file: String) -> String {
        let pack = currentPack
        guard pack != .lark, file.hasPrefix("lark/") else { return file }
        return pack.directory + file.dropFirst("lark".count)
    }

    static var flightEnabled: Bool {
        // Default true when no value has been written yet.
        if UserDefaults.standard.object(forKey: AppSettingsKeys.emojiFlightEnabled) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: AppSettingsKeys.emojiFlightEnabled)
    }
}
