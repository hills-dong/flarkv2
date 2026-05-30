import SwiftUI

/// Sheet listing the configured personas so the user can pick one to reply in
/// the current topic. Picking calls `onPick` with the chosen persona; the
/// caller is responsible for kicking off generation and dismissing.
struct PersonaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Persona, String) -> Void

    @State private var guidance: String = ""
    private let personas = AIConfig.loadPersonas()
    private var hasKey: Bool { AIConfig.hasUsableModel }

    var body: some View {
        NavigationStack {
            List {
                if !hasKey {
                    Section {
                        Label("还没有可用的模型，请先到「AI 角色」设置里配置一个带 API Key 的模型。",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("回复引导（可选）") {
                    TextField("给角色一点方向，比如「用反驳的语气」「聚焦性能问题」…",
                              text: $guidance, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(!hasKey)
                }

                Section("选择一个角色来回复") {
                    if personas.isEmpty {
                        Text("还没有任何角色。到「AI 角色」设置里添加。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(personas) { persona in
                        Button {
                            onPick(persona, guidance.trimmingCharacters(in: .whitespacesAndNewlines))
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(authorID: persona.name, name: persona.name, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name.isEmpty ? String(localized: "未命名角色") : persona.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(persona.systemPrompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasKey)
                    }
                }
            }
            .navigationTitle("召唤角色")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
