import SwiftUI

/// Multi-user sign-in. Lists local accounts (data preserved on logout) and
/// lets you switch, add a new identity, or import one from another device.
struct AccountPickerView: View {
    @Environment(AppModel.self) private var model
    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Cards sit immediately under the title (content-sized). The
            // empty space lives between the list and the footer so the
            // primary action stays anchored to the bottom thumb area.
            accountList
                .padding(.top, 22)
                .padding(.horizontal, 2)

            Spacer(minLength: 24)

            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformGrouped)
        .sheet(isPresented: $showImport) { IdentitySettingsView() }
    }

    /// Plain stack when ≤ 5 accounts (no scrolling needed, layout shrinks
    /// to content so the footer hugs the bottom). Above that we wrap in a
    /// ScrollView so the picker stays usable.
    @ViewBuilder private var accountList: some View {
        let rows = VStack(spacing: 10) {
            ForEach(model.accounts) { acct in
                AccountRow(account: acct) { model.switchAccount(acct.id) }
            }
        }
        if model.accounts.count > 5 {
            ScrollView { rows }
                .scrollIndicators(.hidden)
        } else {
            rows
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 64, height: 64)
                .overlay(
                    Text("F").font(.system(size: 32, weight: .black))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.accentColor.opacity(0.25), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("选择身份").font(.largeTitle.weight(.bold))
                Text("点按以切换身份。登出不会删除任何数据。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button { model.stage = .onboarding } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("新建身份")
                }
                .font(.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button("从其他设备导入身份") { showImport = true }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.top, 18)
    }
}

/// A single account row in the picker. Card-like surface with an avatar,
/// display name, and a truncated authorID — no chevron (the whole card is
/// the tap target).
private struct AccountRow: View {
    let account: AccountRef
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AvatarView(authorID: account.id, name: account.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(account.id.prefix(12) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.platformBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
