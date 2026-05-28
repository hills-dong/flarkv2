import SwiftUI

struct SpaceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called after a Space is connected so a presenting sheet can dismiss
    /// and drop the user straight into the new Space.
    var onConnected: () -> Void = {}
    @State private var kind: SpaceConfig.Kind = .webdav
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var spaceId = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("连接话题群").font(.title.weight(.bold))
                Text("一个目录就是一个群。同目录的成员共享话题，无需服务器。")
                    .foregroundStyle(.secondary)

                Picker("", selection: $kind) {
                    Text("WebDAV").tag(SpaceConfig.Kind.webdav)
                    Text("本地").tag(SpaceConfig.Kind.local)
                }
                .pickerStyle(.segmented)

                field("名称", text: $name, prompt: Text("如：日常 / 想法 / 小组"))

                if kind == .webdav {
                    // `Text(verbatim:)` so the URL-shaped placeholder isn't
                    // auto-linkified by LocalizedStringKey markdown parsing
                    // (which would render it blue instead of placeholder gray).
                    field("WebDAV 地址", text: $url,
                          prompt: Text(verbatim: "https://dav.example.com/flark/"))
                    field("账号", text: $user, prompt: Text("用户名"))
                    secureField("密码", text: $password)
                    field("群 ID（可选）", text: $spaceId,
                          prompt: Text("加入已有群填群 ID；留空则新建"))
                    Text("凭据仅存本机钥匙串。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("将在本机创建群目录，之后可在设置里改为 WebDAV。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                connectButton
                    .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 560)
            #if os(macOS)
            .frame(maxWidth: .infinity)  // center the 560pt form in the window
            #endif
        }
        .background(Color.platformGrouped)
    }

    @ViewBuilder private var connectButton: some View {
        #if os(macOS)
        // Native macOS prominent button: ~32pt tall, system tinted, looks at
        // home in a window instead of the chunky iOS pill.
        Button("连接并进入", action: connect)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect)
            .frame(maxWidth: .infinity, alignment: .trailing)
        #else
        Button(action: connect) {
            Text("连接并进入").font(.headline)
                .frame(maxWidth: .infinity).padding(16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
        .disabled(!canConnect)
        #endif
    }

    private var canConnect: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .webdav { return !url.isEmpty && !user.isEmpty }
        return true
    }

    private func connect() {
        if kind == .webdav {
            model.addWebDAVSpace(name: name, url: url, user: user, password: password,
                                  spaceID: spaceId)
        } else {
            model.addLocalSpace(name: name)
        }
        dismiss()
        onConnected()
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>,
                       prompt: Text) -> some View {
        spaceFormField(label, text: text, prompt: prompt)
    }

    private func secureField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        spaceFormSecureField(label, text: text)
    }
}

/// Shared text field styling for `SpaceSetupView` / `SpaceEditView`.
///
/// The prompt is taken as a `Text` (not `LocalizedStringKey`) so callers can
/// pass `Text(verbatim:)` for URL-shaped placeholders — `LocalizedStringKey`
/// runs markdown parsing and would auto-linkify URLs into blue links.
fileprivate func spaceFormField(_ label: LocalizedStringKey, text: Binding<String>,
                                prompt: Text) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        TextField("", text: text, prompt: prompt)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .padding(15)
            .background(Color.platformBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(FieldOutlineMac())
    }
}

fileprivate func spaceFormSecureField(_ label: LocalizedStringKey,
                                      text: Binding<String>,
                                      prompt: Text = Text(verbatim: "••••••••")) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        SecureField("", text: text, prompt: prompt)
            .textFieldStyle(.plain)
            .padding(15)
            .background(Color.platformBackground,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(FieldOutlineMac())
    }
}

/// Edit name + WebDAV connection for an existing Space. The space's `id`
/// (shared spaceID), `localID` and `kind` are intentionally immutable —
/// changing those is semantically a new join, not an edit.
struct SpaceEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: SpaceConfig
    @State private var name: String
    @State private var url: String
    @State private var user: String
    @State private var password: String = ""

    init(space: SpaceConfig) {
        self.original = space
        _name = State(initialValue: space.name)
        _url = State(initialValue: space.webdavURL ?? "")
        _user = State(initialValue: space.webdavUser ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("编辑话题群").font(.title.weight(.bold))
                Text("可改名称与连接信息；群 ID 与类型不可改。")
                    .foregroundStyle(.secondary)

                spaceFormField("名称", text: $name, prompt: Text("如：日常 / 想法 / 小组"))

                if original.kind == .webdav {
                    spaceFormField("WebDAV 地址", text: $url,
                                   prompt: Text(verbatim: "https://dav.example.com/flark/"))
                    spaceFormField("账号", text: $user, prompt: Text("用户名"))
                    spaceFormSecureField("密码", text: $password,
                                         prompt: Text("留空则保持不变"))
                    HStack(spacing: 8) {
                        Text("群 ID")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(original.id)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                saveButton.padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 560)
            #if os(macOS)
            .frame(maxWidth: .infinity)
            #endif
        }
        .background(Color.platformGrouped)
    }

    @ViewBuilder private var saveButton: some View {
        #if os(macOS)
        Button("保存", action: save)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .frame(maxWidth: .infinity, alignment: .trailing)
        #else
        Button(action: save) {
            Text("保存").font(.headline)
                .frame(maxWidth: .infinity).padding(16)
                .background(Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
        .disabled(!canSave)
        #endif
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if original.kind == .webdav { return !url.isEmpty && !user.isEmpty }
        return true
    }

    private func save() {
        var updated = original
        updated.name = name.trimmingCharacters(in: .whitespaces)
        if original.kind == .webdav {
            updated.webdavURL = url.trimmingCharacters(in: .whitespaces)
            updated.webdavUser = user.trimmingCharacters(in: .whitespaces)
        }
        model.updateSpace(updated, password: password.isEmpty ? nil : password)
        dismiss()
    }
}

/// macOS-only hairline outline around the otherwise borderless field, since
/// `controlBackgroundColor` and `windowBackgroundColor` are both white in
/// light mode — without a stroke the field is indistinguishable from the
/// page. No-op on iOS where `platformBackground` is already darker than
/// `platformGrouped`.
private struct FieldOutlineMac: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        #else
        content
        #endif
    }
}

/// Switch between / add Spaces.
struct SpaceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: SpaceConfig?
    @State private var pendingDelete: SpaceConfig?
    /// Drives the "邀请链接已复制" alert. Holds the result message (success or
    /// failure) so the same alert sheet can render either outcome.
    @State private var inviteAlert: InviteAlert?

    private struct InviteAlert: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let message: LocalizedStringKey
    }

    var body: some View {
        NavigationStack {
            List {
                Section("我的话题群") {
                    ForEach(model.spaces) { space in
                        row(for: space)
                    }
                }
            }
            .navigationTitle("话题群")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) {
                SpaceSetupView { adding = false; dismiss() }
            }
            .sheet(item: $editing) { space in
                SpaceEditView(space: space)
            }
            .confirmationDialog("删除话题群",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { space in
                Button("删除「\(space.name)」", role: .destructive) {
                    model.deleteSpace(space)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { space in
                Text(space.kind == .local
                     ? "本地话题群将被永久删除，其中的全部话题、回复与图片都会从本机移除，无法恢复。"
                     : "将从本机移除该话题群与已保存的凭据；WebDAV 服务器上的共享数据不受影响。")
            }
            .alert(item: $inviteAlert) { alert in
                Alert(title: Text(alert.title),
                      message: Text(alert.message),
                      dismissButton: .default(Text("好的")))
            }
        }
    }

    /// Row = main tap area (switch to that space) + trailing `…` menu. The
    /// menu lives as a sibling button so its taps don't get eaten by the row
    /// button's hit area. Swipe + long-press actions are gone — everything
    /// goes through the explicit menu now.
    @ViewBuilder private func row(for space: SpaceConfig) -> some View {
        HStack(spacing: 0) {
            Button {
                model.switchSpace(space); dismiss()
            } label: {
                HStack {
                    Image(systemName: space.kind == .webdav ? "cloud" : "folder")
                    VStack(alignment: .leading) {
                        Text(space.name)
                        Group {
                            if space.kind == .webdav {
                                Text(verbatim: space.webdavURL ?? "")
                            } else {
                                Text("本地")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if space.id == model.currentSpace?.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if space.kind == .webdav {
                    Button {
                        copyInvite(for: space)
                    } label: {
                        Label("邀请", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Button {
                    editing = space
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = space
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
        }
    }

    private func copyInvite(for space: SpaceConfig) {
        do {
            let url = try model.exportInviteURL(for: space)
            copyInviteToClipboard(url.absoluteString)
            inviteAlert = InviteAlert(
                title: "邀请链接已复制",
                message: "链接已复制到剪贴板，有效期 7 天。\n请只发给信任的人——链接含 WebDAV 凭据。")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            inviteAlert = InviteAlert(
                title: "无法生成邀请链接",
                message: LocalizedStringKey(msg))
        }
    }
}

/// Shared platform pasteboard helper for invite links. Kept file-private so
/// it doesn't collide with the identical helper inside `IdentitySettingsView`.
fileprivate func copyInviteToClipboard(_ s: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = s
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}

/// Confirmation sheet that pops when an incoming `flark://invite/...` link
/// has been successfully decrypted. Globally mounted on `RootView`.
struct InviteConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let payload: SpaceInvitePayload

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("群名", value: payload.name)
                    LabeledContent("群 ID", value: shortID)
                    LabeledContent("WebDAV", value: payload.url)
                    LabeledContent("账号", value: payload.user)
                } header: { Text("收到一个话题群邀请") }
                footer: {
                    Text("加入后会在本机新建一个 WebDAV 绑定；可在「我的话题群」里管理。链接有效期至 \(expiryString)。")
                }

                Section {
                    Button {
                        model.acceptPendingInvite()
                        dismiss()
                    } label: {
                        Label("加入此话题群", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.currentAccountID == nil)
                }
            }
            .navigationTitle("加入话题群")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.dismissPendingInvite()
                        dismiss()
                    }
                }
            }
        }
    }

    private var shortID: String {
        let s = payload.id
        return s.count > 12 ? String(s.prefix(8)) + "…" : s
    }

    private var expiryString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: payload.expiresAt)
    }
}
