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
                Button {
                    model.toggleReaction(targetID: targetID, type: targetType, emojiID: tally.emojiID)
                } label: {
                    HStack(spacing: 6) {
                        EmojiGlyph(item: model.emoji.item(tally.emojiID), size: Self.glyphSize)
                        Text("\(tally.count)")
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Match the inline-content emoji size (see `inlineEmojiScale` in
    /// RichTextEditor.swift): body line height × 1.44. Scales with Dynamic
    /// Type so reaction chips stay visually identical to the same emoji
    /// embedded in topic/reply text.
    private static var glyphSize: CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body).lineHeight * 1.44
        #else
        20.32 * 1.44
        #endif
    }
}
