import SwiftUI
import FlarkKit

/// Long-press control panel for a topic or reply: a quick row of the
/// most-used 表情 (tap to react immediately), a "更多" button to the full
/// picker, and — when the viewer is allowed — a destructive 删除 action.
struct ReactionActionPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let targetID: String
    let targetType: TargetType
    /// Non-nil only when the viewer may edit this item.
    var onEdit: (() -> Void)?
    /// Non-nil only when the viewer may delete this item.
    var onDelete: (() -> Void)?

    @State private var showPicker = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                // Top-5 frequency shortcuts; the "更多" button next to them
                // opens the full picker for everything else. Empty until the
                // user has actually picked emoji — in that case only "更多"
                // shows. Same flat / no-background look as the picker grid.
                ForEach(Array(model.mostUsedEmoji.prefix(5))) { item in
                    Button {
                        model.recordEmojiUsage(item.id)
                        model.toggleReaction(targetID: targetID, type: targetType, emojiID: item.id)
                        dismiss()
                    } label: {
                        EmojiGlyph(item: item, size: 44)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
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
            EmojiPickerView(title: "添加表情") { item in
                model.toggleReaction(targetID: targetID, type: targetType, emojiID: item.id)
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
