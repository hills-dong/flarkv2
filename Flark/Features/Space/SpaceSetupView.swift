import SwiftUI

struct SpaceSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: SpaceConfig.Kind = .webdav
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""

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
                    Text("凭据仅保存在本机钥匙串。并发写入由「每设备独立追加 + 内容寻址」自动避免冲突。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("将在应用容器内创建本地群目录，可在「设置」里换成 WebDAV 或自建服务器，数据格式不变。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Button(action: connect) {
                    Text("连接并进入").font(.headline)
                        .frame(maxWidth: .infinity).padding(16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                }
                .disabled(!canConnect)
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        .background(Color.platformGrouped)
    }

    private var canConnect: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .webdav { return !url.isEmpty && !user.isEmpty }
        return true
    }

    private func connect() {
        if kind == .webdav {
            model.addWebDAVSpace(name: name, url: url, user: user, password: password)
        } else {
            model.addLocalSpace(name: name)
        }
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
        }
    }
}

/// Switch between / add Spaces.
struct SpaceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

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
                SpaceSetupView()
            }
        }
    }
}
