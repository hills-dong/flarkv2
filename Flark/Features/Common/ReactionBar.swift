import SwiftUI
import FlarkKit

/// Emoji tally chips + an "add emoji" button. Used on topics and replies.
/// (Terminology is "表情" everywhere, per the confirmed design.)
struct ReactionBar: View {
    @Environment(AppModel.self) private var model
    let targetID: String
    let targetType: TargetType

    var body: some View {
        let tallies = model.projection.tallies(forTarget: targetID)
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(tallies) { tally in
                let mine = model.projection.hasReacted(
                    author: model.authorID, target: targetID, emoji: tally.emojiID)
                Button {
                    model.toggleReaction(targetID: targetID, type: targetType, emojiID: tally.emojiID)
                } label: {
                    HStack(spacing: 5) {
                        EmojiGlyph(item: model.emoji.item(tally.emojiID), size: 16)
                        Text("\(tally.count)").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(mine ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                                in: Capsule())
                    .foregroundStyle(mine ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
