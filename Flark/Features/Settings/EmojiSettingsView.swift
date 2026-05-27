import SwiftUI
import FlarkKit

/// Global appearance / behavior settings for the emoji system: which
/// pack the glyphs render from, and whether the picker→editor and
/// reaction-add arc fly-in animations play. The "彩蛋" sparkles button
/// in topic detail is intentionally not gated by this — it's the
/// effect's discoverable entry point and stays on.
struct EmojiSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettingsKeys.emojiPack) private var emojiPack: String = EmojiPack.lark.rawValue
    @AppStorage(AppSettingsKeys.emojiFlightEnabled) private var flightEnabled: Bool = true

    /// Six representative emoji for the preview row — uses the catalog's
    /// "最常使用" seeds so the picked pack's visual style is obvious at a
    /// glance without scanning the full grid.
    private var previewItems: [EmojiItem] {
        let ids = model.emoji.seedMostUsedIDs.prefix(6)
        return ids.compactMap { model.emoji.item($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(EmojiPack.allCases) { pack in
                        Button {
                            emojiPack = pack.rawValue
                        } label: {
                            HStack {
                                Text(pack.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if emojiPack == pack.rawValue {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("表情包")
                } footer: {
                    Text("切换全局表情图片样式。所有消息中的表情会立即换新。")
                }

                if !previewItems.isEmpty {
                    Section("预览") {
                        HStack(spacing: 12) {
                            ForEach(previewItems) { item in
                                EmojiGlyph(item: item, size: 36)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Toggle("启用表情飞行动效", isOn: $flightEnabled)
                } footer: {
                    Text("控制选表情飞入编辑器、表情反应飞入气泡的动画。关闭后选表情会即时落位；详情页右上角的彩蛋按钮不受影响。")
                }
            }
            .navigationTitle("表情设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
