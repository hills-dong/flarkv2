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
    /// Non-nil only when the viewer may delete this item.
    var onDelete: (() -> Void)?

    @State private var showPicker = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(model.emoji.category("most_used")) { item in
                    Button {
                        model.toggleReaction(targetID: targetID, type: targetType, emojiID: item.id)
                        dismiss()
                    } label: {
                        EmojiGlyph(item: item, size: 28)
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Button { showPicker = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            if onDelete != nil {
                Divider()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(20)
        .presentationDetents([.height(onDelete == nil ? 132 : 210)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPicker) {
            EmojiPickerView(title: "添加表情") { item in
                model.toggleReaction(targetID: targetID, type: targetType, emojiID: item.id)
                dismiss()
            }
        }
        .confirmationDialog("删除", isPresented: $confirmingDelete) {
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
}

extension View {
    /// Long-press a topic or reply to open the reaction / delete panel.
    /// Pass `onDelete` only when the viewer is permitted to delete.
    func reactionPanel(targetID: String, targetType: TargetType,
                       onDelete: (() -> Void)? = nil) -> some View {
        modifier(ReactionPanelModifier(targetID: targetID,
                                       targetType: targetType, onDelete: onDelete))
    }
}

private struct ReactionPanelModifier: ViewModifier {
    let targetID: String
    let targetType: TargetType
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
                                    targetType: targetType, onDelete: onDelete)
            }
    }
}
