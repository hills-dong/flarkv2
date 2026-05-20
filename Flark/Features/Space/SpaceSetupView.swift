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
                Text("连接一个话题群").font(.title.weight(.bold))
                Text("一个本地文件夹或 WebDAV 目录就是一个「群」。同一目录下的成员共享话题与回复，没有服务器。")
                    .foregroundStyle(.secondary)

                Picker("", selection: $kind) {
                    Text("WebDAV").tag(SpaceConfig.Kind.webdav)
                    Text("本地").tag(SpaceConfig.Kind.local)
                }
                .pickerStyle(.segmented)

                field("名称", text: $name, placeholder: "如：TikTok 账号变更")

                if kind == .webdav {
                    field("WebDAV 地址", text: $url, placeholder: "https://dav.example.com/flark/")
                    field("账号", text: $user, placeholder: "用户名")
                    secureField("密码", text: $password)
                    field("群 ID（可选）", text: $spaceId,
                          placeholder: "加入已有群时填写，如 lifememov2；留空则新建")
                    Text("凭据仅保存在本机钥匙串。并发写入由「每设备独立追加 + 内容寻址」自动避免冲突。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("将在应用容器内创建本地群目录，可在「设置」里换成 WebDAV 或自建服务器，数据格式不变。")
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

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
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

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            SecureField("••••••••", text: text)
                .textFieldStyle(.plain)
                .padding(15)
                .background(Color.platformBackground,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .modifier(FieldOutlineMac())
        }
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
    @State private var pendingDelete: SpaceConfig?

    var body: some View {
        NavigationStack {
            List {
                Section("我的话题群") {
                    ForEach(model.spaces) { space in
                        Button {
                            model.switchSpace(space); dismiss()
                        } label: {
                            HStack {
                                Image(systemName: space.kind == .webdav ? "cloud" : "folder")
                                VStack(alignment: .leading) {
                                    Text(space.name)
                                    Text(space.kind == .webdav ? (space.webdavURL ?? "") : "本地")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if space.id == model.currentSpace?.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = space
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
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
        }
    }
}
