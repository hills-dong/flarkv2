import SwiftUI
import FlarkKit

/// Slim, auto-hiding banner that surfaces what the sync engine is doing —
/// actively pulling, throttled by the server, or offline. Pulls only happen
/// when the user explicitly refreshes, so there is no retry countdown; a
/// failed pull just sits in the throttled/offline state until the user pulls
/// again.
struct SyncStatusBar: View {
    let status: SyncActivity

    var body: some View {
        Group {
            if let d = descriptor {
                HStack(spacing: 8) {
                    if d.showsSpinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: d.icon)
                    }
                    Text(d.text).font(.caption).fontWeight(.medium)
                }
                .foregroundStyle(d.tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: status)
    }

    private struct Descriptor {
        var text: String
        var icon: String
        var tint: Color
        var showsSpinner: Bool
    }

    private func progress(_ done: Int, _ total: Int) -> String {
        total > 0 ? "\(done.formatted()) / \(total.formatted()) 条" : "…"
    }

    private var descriptor: Descriptor? {
        switch status {
        case .idle:
            return nil
        case let .syncing(done, total):
            return Descriptor(text: "正在同步 \(progress(done, total))",
                              icon: "arrow.triangle.2.circlepath",
                              tint: .secondary, showsSpinner: true)
        case let .throttled(done, total):
            return Descriptor(text: "已限流 · \(progress(done, total))",
                              icon: "hourglass", tint: .orange, showsSpinner: false)
        case let .offline(done, total):
            return Descriptor(text: "离线 · \(progress(done, total))",
                              icon: "wifi.slash", tint: .orange, showsSpinner: false)
        }
    }
}
