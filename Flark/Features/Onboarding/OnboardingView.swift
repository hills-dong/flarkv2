import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 74, height: 74)
                .overlay(Text("F").font(.system(size: 38, weight: .black)).foregroundStyle(.white))
                .padding(.bottom, 22)

            Text("欢迎使用 Flark").font(.largeTitle.weight(.bold))
            Text("无中央服务器的话题群。先创建一个本地身份——它属于你的设备，用密钥签名，无需密码注册。")
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 7) {
                Text("昵称").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                TextField("你的昵称", text: $name)
                    .textFieldStyle(.plain)
                    .padding(15)
                    .background(Color.platformBackground,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 28)

            Spacer()

            Button {
                model.createIdentity(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("创建身份并继续")
                    .font(.headline).frame(maxWidth: .infinity).padding(16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .background(Color.platformGrouped)
    }
}
