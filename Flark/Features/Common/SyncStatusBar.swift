import SwiftUI
import FlarkKit

/// Slim, auto-hiding banner that surfaces what the sync engine is doing in
/// the background — pulling data, compacting, throttled or offline. While
/// stalled it keeps the live progress and counts down to the next retry.
/// Hidden only when fully caught up.
struct SyncStatusBar: View {
    let status: SyncActivity

    var body: some View {
        // Tick every second so the recovery countdown stays live without the
        // engine having to re-publish.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if let d = descriptor(now: ctx.date) {
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

    /// "5 秒后重试" / "正在重试…" once the countdown elapses.
    private func retry(_ at: Date, now: Date) -> String {
        let secs = Int(at.timeIntervalSince(now).rounded(.up))
        return secs > 0 ? "\(secs) 秒后重试" : "正在重试…"
    }

    private func descriptor(now: Date) -> Descriptor? {
        switch status {
        case .idle:
            return nil
        case let .syncing(done, total):
            return Descriptor(text: "正在同步 \(progress(done, total))",
                              icon: "arrow.triangle.2.circlepath",
                              tint: .secondary, showsSpinner: true)
        case let .throttled(done, total, retryAt):
            return Descriptor(
                text: "已限流 · \(progress(done, total)) · \(retry(retryAt, now: now))",
                icon: "hourglass", tint: .orange, showsSpinner: true)
        case let .offline(done, total, retryAt):
            return Descriptor(
                text: "离线 · \(progress(done, total)) · \(retry(retryAt, now: now))",
                icon: "wifi.slash", tint: .orange, showsSpinner: false)
        case .compacting:
            return Descriptor(text: "正在整理历史…", icon: "archivebox",
                              tint: .secondary, showsSpinner: true)
        }
    }
}
