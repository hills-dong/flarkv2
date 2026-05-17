import SwiftUI

/// Multi-user sign-in. Lists local accounts (data preserved on logout) and
/// lets you switch, add a new identity, or import one from another device.
struct AccountPickerView: View {
    @Environment(AppModel.self) private var model
    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 64, height: 64)
                .overlay(Text("F").font(.system(size: 32, weight: .black)).foregroundStyle(.white))
                .padding(.bottom, 18)

            Text("选择身份").font(.largeTitle.weight(.bold))
            Text("本机已有以下身份，登出不会删除任何数据。点按即可登录。")
                .foregroundStyle(.secondary).padding(.top, 6)

            List {
                ForEach(model.accounts) { acct in
                    Button { model.switchAccount(acct.id) } label: {
                        HStack(spacing: 12) {
                            AvatarView(authorID: acct.id, name: acct.name, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(acct.name).font(.body.weight(.semibold))
                                Text(acct.id.prefix(10) + "…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.platformBackground)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 360)

            VStack(spacing: 10) {
                Button { model.stage = .onboarding } label: {
                    Text("＋ 新建身份").font(.headline)
                        .frame(maxWidth: .infinity).padding(14)
                        .background(Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                Button("从其他设备导入身份") { showImport = true }
                    .font(.subheadline)
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformGrouped)
        .sheet(isPresented: $showImport) { IdentitySettingsView() }
    }
}
