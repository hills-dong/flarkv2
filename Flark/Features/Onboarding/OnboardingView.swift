import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var showImport = false

    /// iPad and Mac get a vertically-centered card; iPhone keeps the
    /// edge-to-edge layout with the primary action anchored to the
    /// bottom thumb area.
    private var isWide: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        true
        #endif
    }

    var body: some View {
        Group {
            if isWide {
                wideLayout
            } else {
                compactLayout
            }
        }
        .background(Color.platformGrouped.ignoresSafeArea())
        .sheet(isPresented: $showImport) {
            NavigationStack {
                IdentityRecoveryView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showImport = false }
                        }
                    }
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            nicknameField.padding(.top, 28)
            Spacer()
            actionButtons
        }
        .padding(28)
        .frame(maxWidth: 520)
    }

    private var wideLayout: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    nicknameField.padding(.top, 28)
                    actionButtons.padding(.top, 32)
                }
                .padding(36)
                .frame(maxWidth: 480, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.platformBackground)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                // Center the card vertically when there's room; fall back
                // to top-aligned scrolling on tight heights.
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("欢迎使用 Flark").font(.largeTitle.weight(.bold))
            Text("无服务器的话题群。先在本机创建一个身份，无需注册。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nicknameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("昵称").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField("你的昵称", text: $name)
                .textFieldStyle(.plain)
                .padding(15)
                .background(isWide ? Color.platformGrouped : Color.platformBackground,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 0) {
            Button {
                model.createIdentity(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("创建身份并继续")
                    .font(.headline).frame(maxWidth: .infinity).padding(16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("已有身份？从其他设备导入") { showImport = true }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

            if !model.accounts.isEmpty {
                Button("返回选择已有身份") { model.stage = .accountPicker }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }
}
