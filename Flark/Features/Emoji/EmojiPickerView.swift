import SwiftUI
import FlarkKit

/// The Lark-style picker. Sections mirror the catalog categories
/// (最常使用 / 默认表情 / Lark 贴纸). Tracks recents locally.
struct EmojiPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title: String = "选择表情"
    var onPick: (EmojiItem) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    private func label(_ cat: String) -> String {
        switch cat {
        case "most_used": return "最常使用"
        case "default": return "默认表情"
        case "lark": return "Lark 贴纸"
        default: return cat
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.emoji.categories, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(label(cat))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(model.emoji.category(cat)) { item in
                                    Button {
                                        onPick(item); dismiss()
                                    } label: {
                                        EmojiGlyph(item: item, size: 30)
                                            .frame(width: 44, height: 44)
                                            .background(.quaternary,
                                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
