import SwiftUI

/// Multi-device identity. Explains the automatic iCloud Keychain path (A)
/// and provides the passphrase-encrypted export/import code + QR (B).
struct IdentitySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var exportPass = ""
    @State private var exportCode: String?
    @State private var importCode = ""
    @State private var importPass = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if model.hasIdentity {
                    Section("我的身份") {
                        LabeledContent("ID", value: model.authorIDShort + "…")
                        LabeledContent("昵称", value: model.displayName)
                    }
                    Section {
                        Label("已开启 iCloud 钥匙串同步", systemImage: "checkmark.icloud")
                            .foregroundStyle(.green)
                        Text("登录同一 Apple ID 且开启了「iCloud 钥匙串」的其他设备，会自动成为同一身份并看到相同的话题群，无需手动操作。跨 Apple ID 或换平台时，用下面的恢复码。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("自动多设备 (A)") }
                }

                if model.hasIdentity {
                    Section {
                        SecureField("设置一个口令（恢复时需要）", text: $exportPass)
                        Button("生成恢复码") {
                            exportCode = model.exportIdentity(passphrase: exportPass)
                            message = exportCode == nil ? "请先输入口令" : nil
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
                                message = "已复制恢复码"
                            } label: { Label("复制恢复码", systemImage: "doc.on.doc") }
                        }
                    } header: { Text("导出身份 (B)") }
                    footer: { Text("恢复码含私钥与 WebDAV 密码，已用口令加密。请用安全渠道保存，勿公开分享。") }
                }

                Section {
                    TextField("粘贴恢复码（FLARK1.…）", text: $importCode, axis: .vertical)
                        .font(.system(.caption, design: .monospaced)).lineLimit(3)
                    SecureField("导出时设置的口令", text: $importPass)
                    Button("导入并成为该身份") {
                        if model.importIdentity(code: importCode, passphrase: importPass) {
                            message = "导入成功"
                            dismiss()
                        } else {
                            message = "导入失败：恢复码或口令不正确"
                        }
                    }
                    .disabled(importCode.isEmpty || importPass.isEmpty)
                } header: { Text("在本设备导入身份 (B)") }
                footer: { Text("将用恢复码里的身份替换本设备当前身份，并恢复其全部话题群。") }

                if let message {
                    Text(message).font(.footnote)
                        .foregroundStyle(message.contains("失败") ? .red : .green)
                }
            }
            .navigationTitle("账号与多设备")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
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
