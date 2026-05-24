import SwiftUI
import FlarkKit

/// Emoji tally chips + an "add emoji" button. Used on topics and replies.
/// (Terminology is "表情" everywhere, per the confirmed design.)
struct ReactionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.optionalEmojiFlightHost) private var flightHost
    let targetID: String
    let targetType: TargetType
    /// Detail-page only: when set, each chip's emoji glyph attaches an
    /// `.emojiFlyInSource` that requests a giant-from-the-left fly-in the
    /// first time this emoji id is seen this launch. List rows leave it nil
    /// (no fly-in there).
    var emojiFlyInSpace: String? = nil

    /// Synthetic id used to register a "tail anchor" with the flight
    /// host — the picker arc fly-in for a brand-new reaction (no chip
    /// exists yet) uses this as its landing target so the giant glyph
    /// descends onto the spot where the new chip will appear.
    static func tailAnchorID(targetID: String,
                             targetType: TargetType) -> String {
        "__reaction_tail__:\(targetType):\(targetID)"
    }

    var body: some View {
        let tallies = model.projection.tallies(forTarget: targetID)
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(tallies) { tally in
                Button {
                    model.toggleReaction(targetID: targetID, type: targetType, emojiID: tally.emojiID)
                } label: {
                    HStack(spacing: 6) {
                        glyph(for: tally.emojiID)
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
        .background { tailAnchor }
    }

    /// Invisible GeometryReader on the whole bar — registers the bar's
    /// trailing edge as a "next chip" anchor with the flight host so
    /// the reaction picker can aim a flight at it before the new chip
    /// exists. No-op when the host isn't in environment (list page).
    @ViewBuilder
    private var tailAnchor: some View {
        if let host = flightHost {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { register(host: host, proxy: proxy) }
                    .onChange(of: proxy.frame(in: .global)) { _, _ in
                        register(host: host, proxy: proxy)
                    }
                    .onDisappear {
                        host.unregisterAnchor(id:
                            Self.tailAnchorID(targetID: targetID,
                                              targetType: targetType))
                    }
            }
        }
    }

    private func register(host: EmojiFlightHost, proxy: GeometryProxy) {
        // The bar's bottom-right corner approximates "where the next
        // chip will appear". Anchor a chip-sized rect there.
        let global = proxy.frame(in: .global)
        let s = Self.glyphSize
        let anchor = CGRect(x: global.maxX - s,
                            y: global.maxY - s,
                            width: s, height: s)
        host.registerAnchor(
            id: Self.tailAnchorID(targetID: targetID,
                                  targetType: targetType),
            globalFrame: anchor)
    }

    @ViewBuilder
    private func glyph(for emojiID: String) -> some View {
        let g = EmojiGlyph(item: model.emoji.item(emojiID), size: Self.glyphSize)
        // Chip anchor (window-coord, per-target scoped) is applied
        // regardless of `emojiFlyInSpace` — it's a no-op when no flight
        // host is in environment, but on both list and detail pages the
        // host IS present, so the reaction picker can find this chip.
        let withChipAnchor = g.emojiFlyInChipAnchor(
            emojiID: emojiID,
            targetID: targetID,
            targetType: targetType)
        // `emojiFlyInSource` (which feeds the detail-page easter egg
        // and the SwiftUI overlay) stays gated on `emojiFlyInSpace`.
        if let space = emojiFlyInSpace {
            withChipAnchor.emojiFlyInSource(id: emojiID, space: space)
        } else {
            withChipAnchor
        }
    }

    /// Match the inline-content emoji size (see `inlineEmojiScale` in
    /// RichTextEditor.swift): body line height × 1.44. Scales with Dynamic
    /// Type so reaction chips stay visually identical to the same emoji
    /// embedded in topic/reply text. `internal` so the reaction-picker
    /// arc fly-in can use the same landing size.
    static var glyphSize: CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .body).lineHeight * 1.44
        #else
        20.32 * 1.44
        #endif
    }
}
