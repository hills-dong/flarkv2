import SwiftUI
import FlarkKit

/// Long-press control panel for a topic or reply: a quick row of the
/// most-used 表情 (tap to react immediately), a "更多" button to the full
/// picker, and — when the viewer is allowed — a destructive 删除 action.
struct ReactionActionPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.optionalEmojiFlightHost) private var flightHost
    let targetID: String
    let targetType: TargetType
    /// Non-nil only when the viewer may edit this item.
    var onEdit: (() -> Void)?
    /// Non-nil only when the viewer may delete this item.
    var onDelete: (() -> Void)?

    @State private var showPicker = false
    @State private var confirmingDelete = false
    /// Per-quick-row-cell global frames captured by a background
    /// `GeometryReader`, so the fly-in knows where the tapped glyph sat
    /// before the panel dismissed.
    @State private var cellFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                // Top-5 frequency shortcuts; the "更多" button next to them
                // opens the full picker for everything else. Empty until the
                // user has actually picked emoji — in that case only "更多"
                // shows. Same flat / no-background look as the picker grid.
                ForEach(Array(model.mostUsedEmoji.prefix(5))) { item in
                    Button {
                        let frame = cellFrames[item.id] ?? .zero
                        applyReaction(emojiID: item.id, fromSource: frame)
                        dismiss()
                    } label: {
                        EmojiGlyph(item: item, size: 44)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    cellFrames[item.id] =
                                        proxy.frame(in: .global)
                                }
                                .onChange(of: proxy.frame(in: .global)) { _, new in
                                    cellFrames[item.id] = new
                                }
                        }
                    }
                }
                Button { showPicker = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            if onEdit != nil || onDelete != nil {
                Divider()
            }
            if onEdit != nil {
                Button {
                    onEdit?()
                    dismiss()
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if onDelete != nil {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(20)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPicker) {
            // The picker itself already records the pick into the usage store,
            // so we just need to apply the reaction here.
            EmojiPickerView(title: "添加表情") { item, sourceFrame in
                applyReaction(emojiID: item.id, fromSource: sourceFrame)
                dismiss()
            }
        }
        .alert("删除？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(targetType == .topic
                 ? "删除后无法恢复。仅可删除没有任何互动的话题。"
                 : "删除后无法恢复。")
        }
    }

    /// Pick → arc fly → land → commit. The model change (toggleReaction)
    /// is deferred to the flight's `onLanded` callback so the new chip
    /// appears exactly when the giant glyph collapses onto its slot.
    ///
    /// Landing target is picked live each CADisplayLink tick:
    ///   - if a chip for this emoji already exists in the bar (user
    ///     re-reacting), aim at the chip itself,
    ///   - otherwise aim at the bar's "tail anchor" — the registered
    ///     bottom-right slot of the reaction bar — so the giant glyph
    ///     lands where the new chip will appear after `onLanded` runs.
    ///
    /// On the topic list (no flight host in environment), this falls
    /// straight through to the model update with no animation.
    private func applyReaction(emojiID: String,
                               fromSource sourceFrame: CGRect) {
        model.recordEmojiUsage(emojiID)

        guard let host = flightHost,
              let window = EmojiPickerFlight.keyWindow,
              let item = model.emoji.item(emojiID),
              sourceFrame.width > 0, sourceFrame.height > 0
        else {
            // No animation context — commit immediately.
            model.toggleReaction(targetID: targetID, type: targetType,
                                 emojiID: emojiID)
            return
        }

        let from = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let chipKey = EmojiFlightHost.chipAnchorKey(
            emojiID: emojiID,
            targetID: targetID, targetType: targetType)
        let tailKey = ReactionBar.tailAnchorID(targetID: targetID,
                                               targetType: targetType)
        let landingSize = ReactionBar.glyphSize

        let flight = EmojiPickerFlight.fly(
            item: item,
            fromCenter: from, toCenter: from,
            pickerGlyphSize: 44, landingGlyphSize: landingSize,
            in: window) {
            // Real commit at landing — chip pops into the bar exactly
            // when the giant glyph collapses onto its slot.
            model.toggleReaction(targetID: targetID, type: targetType,
                                 emojiID: emojiID)
        }
        flight?.targetProvider = { [weak host] in
            guard let host else { return nil }
            // Per-target chip first (re-reaction on THIS target);
            // then this target's bar tail (new reaction). Both are
            // scoped by targetID so we don't accidentally land on
            // another target's chip with the same emoji.
            let rect = host.liveGlobalSource(for: chipKey)
                ?? host.liveGlobalSource(for: tailKey)
            guard let rect, rect.width > 0 else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private var detentHeight: CGFloat {
        // 132 = reaction row only; each action row adds ~58.
        var h: CGFloat = 140
        if onEdit != nil { h += 58 }
        if onDelete != nil { h += 58 }
        return h
    }
}

extension View {
    /// Long-press a topic or reply to open the reaction / edit / delete panel.
    /// Pass `onEdit` / `onDelete` only when the viewer is permitted.
    func reactionPanel(targetID: String, targetType: TargetType,
                       onEdit: (() -> Void)? = nil,
                       onDelete: (() -> Void)? = nil) -> some View {
        modifier(ReactionPanelModifier(targetID: targetID,
                                       targetType: targetType,
                                       onEdit: onEdit, onDelete: onDelete))
    }
}

private struct ReactionPanelModifier: ViewModifier {
    let targetID: String
    let targetType: TargetType
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            // `.simultaneousGesture` keeps List row selection / navigation
            // taps working alongside the long press.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in presented = true }
            )
            .sheet(isPresented: $presented) {
                ReactionActionPanel(targetID: targetID,
                                    targetType: targetType,
                                    onEdit: onEdit, onDelete: onDelete)
            }
    }
}
