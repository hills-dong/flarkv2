import SwiftUI

/// Settings hub for the AI personas: the configurable model registry (Gemini,
/// Claude, xAI, and OpenAI-compatible providers), the default model, and the
/// editable list of personas the user can summon into topics.
struct AISettingsView: View {
    @State private var models = AIConfig.loadModels()
    @State private var defaultModelID = AIConfig.defaultModelOption()?.id ?? ""
    @State private var personas = AIConfig.loadPersonas()
    /// Non-nil while adding a new item: drives a pushed editor for the draft,
    /// which is only committed to the list on save (cancel/back discards it).
    @State private var addingModel: ModelOption?
    @State private var addingPersona: Persona?

    var body: some View {
        Form {
            Section {
                ForEach($models) { $model in
                    NavigationLink {
                        EditModelView(model: $model) {
                            models.removeAll { $0.id == model.id }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .foregroundStyle(.primary)
                            Text("\(model.kind.label) · \(model.modelID.isEmpty ? String(localized: "未设置模型名") : model.modelID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Button {
                    addingModel = ModelOption(name: "", kind: .openAI)
                } label: {
                    Label("添加模型", systemImage: "plus.circle")
                }
            } header: {
                Text("模型")
            } footer: {
                Text("支持 Gemini、Claude、xAI 与各种 OpenAI 兼容服务。")
            }

            if !models.isEmpty {
                Section {
                    Picker("默认模型", selection: $defaultModelID) {
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                } footer: {
                    Text("角色未单独指定模型时使用。")
                }
            }

            Section {
                ForEach($personas) { $persona in
                    NavigationLink {
                        PersonaEditView(persona: $persona, models: models) {
                            personas.removeAll { $0.id == persona.id }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(authorID: persona.name, name: persona.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(persona.name.isEmpty ? String(localized: "未命名角色") : persona.name)
                                    .foregroundStyle(.primary)
                                Text(persona.systemPrompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Button {
                    addingPersona = Persona(name: "", systemPrompt: "")
                } label: {
                    Label("添加角色", systemImage: "plus.circle")
                }
            } header: {
                Text("角色")
            } footer: {
                Text("在话题详情底部点 ✨ 按钮即可召唤这些角色回复。回复会以你的身份发出，并标注角色名。")
            }
        }
        .navigationDestination(item: $addingModel) { initial in
            AddModelView(initial) { saved in
                models.append(saved)
                addingModel = nil
            }
        }
        .navigationDestination(item: $addingPersona) { initial in
            AddPersonaView(initial, models: models) { saved in
                personas.append(saved)
                addingPersona = nil
            }
        }
        .navigationTitle("AI 角色")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Persist on every change so leaving the screen always saves.
        .onChange(of: models) { _, new in
            AIConfig.saveModels(new)
            // Keep the default pointer valid after edits / deletes.
            if !new.contains(where: { $0.id == defaultModelID }) {
                defaultModelID = new.first?.id ?? ""
            }
        }
        .onChange(of: defaultModelID) { _, new in
            AIConfig.defaultModelOptionID = new.isEmpty ? nil : new
        }
        .onChange(of: personas) { _, new in AIConfig.savePersonas(new) }
    }
}

/// Hosts a brand-new model in local state so the editor binds to something
/// stable; the draft is committed to the parent list only on 保存 (the back
/// button / cancel just discards it).
private struct AddModelView: View {
    @State private var draft: ModelOption
    let onSave: (ModelOption) -> Void

    init(_ initial: ModelOption, onSave: @escaping (ModelOption) -> Void) {
        _draft = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        ModelEditView(model: $draft, isNew: true, onSave: { onSave(draft) })
    }
}

/// Edits an existing model on a local draft so changes aren't persisted until
/// 保存 — tapping back discards them. Delete removes it from the parent list.
private struct EditModelView: View {
    @Binding var model: ModelOption
    let onDelete: () -> Void

    @State private var draft: ModelOption
    @Environment(\.dismiss) private var dismiss

    init(model: Binding<ModelOption>, onDelete: @escaping () -> Void) {
        _model = model
        self.onDelete = onDelete
        _draft = State(initialValue: model.wrappedValue)
    }

    var body: some View {
        ModelEditView(model: $draft, isNew: false,
                      onSave: { model = draft; dismiss() },
                      onDelete: onDelete)
    }
}

/// Same as `AddModelView`, for a brand-new persona.
private struct AddPersonaView: View {
    @State private var draft: Persona
    let models: [ModelOption]
    let onSave: (Persona) -> Void

    init(_ initial: Persona, models: [ModelOption], onSave: @escaping (Persona) -> Void) {
        _draft = State(initialValue: initial)
        self.models = models
        self.onSave = onSave
    }

    var body: some View {
        PersonaEditView(persona: $draft, models: models, isNew: true, onCommit: { onSave(draft) })
    }
}

/// Editor for a single model option — name, provider kind, model id, and (for
/// non-Gemini providers) a base URL plus the provider's API key.
private struct ModelEditView: View {
    @Binding var model: ModelOption
    var isNew: Bool = false
    let onSave: () -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showModelPicker = false

    var body: some View {
        Form {
            Section {
                TextField("可选，留空则用模型名", text: $model.name)
            } header: {
                Text("名称")
            }

            Section("提供商") {
                Picker("提供商", selection: $model.kind) {
                    ForEach(ModelOption.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
            }

            if !model.kind.isGemini {
                Section {
                    TextField(baseURLPlaceholder, text: $model.baseURL)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Base URL（可选）")
                } footer: {
                    Text(baseURLFooter)
                }
            }

            Section {
                SecureField("粘贴该提供商的 API Key", text: $model.apiKey)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("API Key")
            } footer: {
                Text("仅保存在本机钥匙串并随 iCloud 同步，不会上传到话题群。")
            }

            // Placed after Base URL + API Key so the fetch has everything it
            // needs to call the provider's model list.
            Section {
                TextField("如 \(model.kind.modelIDHint)", text: $model.modelID)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    showModelPicker = true
                } label: {
                    Label("从服务器获取并选择", systemImage: "arrow.down.circle")
                }
                .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("模型名")
            } footer: {
                Text("可手动填写，或填好上面的 API Key 后从服务器拉取可用模型再选择。")
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("删除模型").frame(maxWidth: .infinity)
                    }
                    // Anchor the confirmation to the button itself so the iPad /
                    // macOS popover points at it rather than the whole form.
                    .confirmationDialog("确定删除「\(model.displayName)」吗？",
                                        isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("删除模型", role: .destructive) {
                            // Pop first so the element binding is torn down before
                            // the parent mutates the array it indexes into.
                            dismiss()
                            onDelete?()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("删除后无法恢复。引用了它的角色会回退到默认模型。")
                    }
                }
            }
        }
        .navigationTitle(isNew ? String(localized: "新模型") : model.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { onSave() }
            }
        }
        // Switching to a named provider fills in its endpoint; OpenAI / custom /
        // local clear it so the user supplies (or omits) their own.
        .onChange(of: model.kind) { _, newKind in
            model.baseURL = newKind.usesCustomBaseURL ? "" : (newKind.presetBaseURL ?? "")
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(option: model) { picked in
                model.modelID = picked
            }
        }
    }

    /// Placeholder for the Base URL field: the provider's preset, or a
    /// local/custom example when the user supplies their own.
    private var baseURLPlaceholder: String {
        switch model.kind {
        case .openAI: return String(localized: "留空＝OpenAI 默认端点")
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return "https://…/v1"
        default:      return model.kind.presetBaseURL ?? "https://…/v1"
        }
    }

    private var baseURLFooter: String {
        switch model.kind {
        case .openAI:
            return String(localized: "OpenAI 留空即可。")
        case .ollama, .custom:
            return String(localized: "填写该服务的 OpenAI 兼容端点（到 /v1 为止，无需 /chat/completions）。")
        default:
            return String(localized: "已填入 \(model.kind.label) 的默认端点，一般无需改动；该服务若调整了地址可在此更正。")
        }
    }
}

/// Editor for a single persona — name, system prompt, and which model it uses.
/// The avatar is derived from the name (see `AvatarView`). Edits flow back
/// through the binding into the settings list, which persists them.
private struct PersonaEditView: View {
    @Binding var persona: Persona
    let models: [ModelOption]
    var isNew: Bool = false
    var onCommit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section("名字") {
                TextField("角色名字", text: $persona.name)
            }

            Section {
                TextField("人设 / system prompt", text: $persona.systemPrompt, axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("人设")
            } footer: {
                Text("描述这个角色的身份、说话风格和回答方式。它会作为 system prompt 交给模型。")
            }

            Section {
                Picker("模型", selection: modelSelection) {
                    Text("默认模型").tag("")
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            } header: {
                Text("模型")
            } footer: {
                Text("选择该角色使用的模型；「默认模型」跟随上方的全局设置。")
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("删除角色").frame(maxWidth: .infinity)
                    }
                    // Anchor the confirmation to the button itself so the iPad /
                    // macOS popover points at it rather than the whole form.
                    .confirmationDialog("确定删除「\(persona.name.isEmpty ? String(localized: "未命名角色") : persona.name)」吗？",
                                        isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("删除角色", role: .destructive) {
                            // Pop first so the element binding is torn down before
                            // the parent mutates the array it indexes into.
                            dismiss()
                            onDelete?()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("删除后无法恢复。")
                    }
                }
            }
        }
        .navigationTitle(isNew ? String(localized: "新角色") : (persona.name.isEmpty ? String(localized: "角色") : persona.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCommit?() }
                }
            }
        }
    }

    /// Bridges the optional `modelOptionID` to the Picker's non-optional tag
    /// ("" ⇒ follow the global default).
    private var modelSelection: Binding<String> {
        Binding(
            get: { persona.modelOptionID ?? "" },
            set: { persona.modelOptionID = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Fetches the provider's model list (using the editor's current key + base URL)
/// and lets the user pick one. Each row carries small capability icons —
/// inferred from the model id (see `ModelCapability`) — flagging which models
/// can read images (eye) and which generate images (photo). Picking writes the
/// id back through `onPick`.
private struct ModelPickerSheet: View {
    let option: ModelOption
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var models: [RemoteModel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var filtered: [RemoteModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(q)
                || ($0.displayName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView { Text("正在获取模型…") }
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(error)
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(filtered) { model in
                                Button { onPick(model.id); dismiss() } label: { row(model) }
                                    .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("图标含义：眼睛＝可识别图片，照片＝可生成图片。能力按模型名推断，仅供参考。")
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: Text("搜索模型"))
        }
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ model: RemoteModel) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id).foregroundStyle(.primary)
                if let name = model.displayName, name != model.id {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.recognizesImages {
                Image(systemName: "eye")
                    .foregroundStyle(.blue)
                    .accessibilityLabel(String(localized: "支持识别图片"))
            }
            if model.generatesImages {
                Image(systemName: "photo")
                    .foregroundStyle(.purple)
                    .accessibilityLabel(String(localized: "支持生成图片"))
            }
            if model.id == option.modelID {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        error = nil
        do {
            models = try await ModelCatalogFetcher.fetch(option: option)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}
