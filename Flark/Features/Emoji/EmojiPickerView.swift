import SwiftUI
import FlarkKit

/// The Lark-style picker. Sections mirror the catalog categories
/// (最常使用 / 默认表情 / Lark 贴纸). Tracks recents locally.
struct EmojiPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title: LocalizedStringKey = "选择表情"
    /// `sourceFrame` is the tapped emoji button's frame in global (window)
    /// coordinates. Callers that want to animate the emoji flying into
    /// place (e.g. the composer's arc fly-in) use this as the start
    /// position; callers that don't care can ignore it.
    var onPick: (EmojiItem, CGRect) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    /// Per-emoji global frames captured by a background `GeometryReader`
    /// on each cell so the tap callback can hand the button's window
    /// coordinates back to `onPick`.
    @State private var cellFrames: [String: CGRect] = [:]

    private func label(_ cat: String) -> LocalizedStringKey {
        switch cat {
        case "most_used": return "最常使用"
        case "default":   return "默认表情"
        default:          return LocalizedStringKey(cat)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let sections: [(String, [EmojiItem])] = [
                        ("most_used", model.mostUsedEmoji),
                        ("default", model.emoji.category("default")),
                    ].filter { !$1.isEmpty }
                    ForEach(sections, id: \.0) { cat, sectionItems in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(label(cat))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(sectionItems) { item in
                                    Button {
                                        model.recordEmojiUsage(item.id)
                                        onPick(item, cellFrames[item.id] ?? .zero)
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
