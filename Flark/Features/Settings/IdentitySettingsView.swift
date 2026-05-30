import SwiftUI

/// Account hub: shows the current identity inline, then routes everything else
/// — multi-device recovery, app settings, logs — into second-level pages. Only
/// the destructive account actions (logout / delete) stay on this top level.
struct IdentitySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showLogout = false
    @State private var showDeleteAccount = false

    var body: some View {
        NavigationStack {
            Form {
                if model.hasIdentity {
                    Section("我的身份") {
                        LabeledContent("ID", value: model.authorIDShort + "…")
                        NavigationLink {
                            IdentityNameEditorView(initialName: model.displayName)
                        } label: {
                            LabeledContent("昵称", value: model.displayName)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        IdentityRecoveryView()
                    } label: {
                        Label("多设备与恢复", systemImage: "checkmark.icloud")
                    }
                    NavigationLink {
                        EmojiSettingsView()
                    } label: {
                        Label("表情设置", systemImage: "face.smiling")
                    }
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 角色", systemImage: "wand.and.stars")
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("操作日志", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("设置")
                }

                if model.hasIdentity {
                    Section {
                        Button { showLogout = true } label: {
                            Label("登出 / 切换身份", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .confirmationDialog("登出当前身份？", isPresented: $showLogout, titleVisibility: .visible) {
                            Button("登出") {
                                model.logout()
                                dismiss()
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("数据保留，可随时再登录。")
                        }
                    } footer: {
                        Text("仅切换身份，**不会删除任何数据**。")
                    }
                    Section {
                        Button(role: .destructive) { showDeleteAccount = true } label: {
                            Label("彻底删除此身份", systemImage: "trash")
                        }
                        .confirmationDialog("彻底删除此身份？", isPresented: $showDeleteAccount,
                                            titleVisibility: .visible) {
                            Button("永久删除", role: .destructive) {
                                if let id = model.currentAccountID { model.removeAccount(id) }
                                dismiss()
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("不可恢复，且会同步从其他设备删除。无恢复码将无法找回。")
                        }
                    } footer: {
                        Text("不可恢复：抹除此身份及其全部话题群。开启钥匙串同步的其他设备也会一并删除。请先导出恢复码。")
                    }
                }
            }
            .navigationTitle("账号与设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct IdentityNameEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isSaving = false

    init(initialName: String) {
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField("你的昵称", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
            } header: {
                Text("昵称")
            } footer: {
                Text("保存后会立即更新当前身份；其他话题群会在下次连接时使用新昵称。")
            }
        }
        .navigationTitle("修改昵称")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存", action: save)
                        .disabled(trimmedName.isEmpty || trimmedName == model.displayName)
                }
            }
        }
    }

    private func save() {
        let next = trimmedName
        guard !next.isEmpty else { return }
        if next == model.displayName {
            dismiss()
            return
        }
        isSaving = true
        Task { @MainActor in
            let ok = await model.updateDisplayName(next)
            isSaving = false
            if ok { dismiss() }
        }
    }
}

/// Second-level page: the automatic iCloud Keychain sync explainer plus the
/// passphrase-encrypted recovery export/import (the manual cross-Apple-ID path).
struct IdentityRecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var exportPass = ""
    @State private var exportCode: String?
    @State private var importCode = ""
    @State private var importPass = ""
    @State private var message: Message?

    /// Footer status line. Held as a `LocalizedStringKey` so the Chinese key
    /// runs through `Localizable.xcstrings`; `isError` drives the red tint
    /// without resorting to substring matching on the rendered text.
    private struct Message {
        var text: LocalizedStringKey
        var isError: Bool
    }

    var body: some View {
        Form {
            if model.hasIdentity {
                Section {
                    // Match the other rows' appearance: accent-tinted icon +
                    // primary text.
                    Label {
                        Text("已开启 iCloud 钥匙串同步")
                    } icon: {
                        Image(systemName: "checkmark.icloud")
                            .foregroundStyle(.tint)
                    }
                    Text("同 Apple ID 且开启钥匙串同步的设备自动共享身份。跨 Apple ID 或换平台时改用下方恢复码。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("自动同步") }

                Section {
                    SecureField("设置一个口令（恢复时需要）", text: $exportPass)
                    Button("生成恢复码") {
                        exportCode = model.exportIdentity(passphrase: exportPass)
                        message = exportCode == nil
                            ? Message(text: "请先输入口令", isError: true)
                            : nil
                    }
                    .disabled(exportPass.isEmpty)
                    if let code = exportCode {
                        if let qr = IdentityKit.qrImage(code) {
                            qr.resizable().interpolation(.none).scaledToFit()
                                .frame(maxWidth: 220).frame(maxWidth: .infinity)
                        }
                        Text(code).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).lineLimit(4)
                        Button {
                            copyToClipboard(code)
                            message = Message(text: "已复制恢复码", isError: false)
                        } label: { Label("复制恢复码", systemImage: "doc.on.doc") }
                    }
                } header: { Text("导出恢复码") }
                footer: { Text("含私钥与 WebDAV 密码，已用口令加密。请安全保存。") }
            }

            Section {
                TextField("粘贴恢复码（FLARK1.…）", text: $importCode, axis: .vertical)
                    .font(.system(.caption, design: .monospaced)).lineLimit(3)
                SecureField("导出时设置的口令", text: $importPass)
                Button("导入并成为该身份") {
                    if model.importIdentity(code: importCode, passphrase: importPass) {
                        message = Message(text: "导入成功", isError: false)
                        dismiss()
                    } else {
                        message = Message(text: "导入失败：恢复码或口令不正确",
                                          isError: true)
                    }
                }
                .disabled(importCode.isEmpty || importPass.isEmpty)
            } header: { Text("导入恢复码") }
            footer: { Text("将替换本机当前身份，并恢复其全部话题群。") }

            if let message {
                Text(message.text).font(.footnote)
                    .foregroundStyle(message.isError ? .red : .green)
            }
        }
        .navigationTitle("多设备与恢复")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func copyToClipboard(_ s: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
