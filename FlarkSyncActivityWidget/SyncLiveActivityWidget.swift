import ActivityKit
import WidgetKit
import SwiftUI

/// Dynamic Island Live Activity for sync progress. The Compact rendering is
/// what shows by default on iPhone Pro models (spinner left, progress count
/// right). Expanded + Minimal + Lock Screen fall back to the same trio of
/// pieces — the user explicitly scoped this to a "Compact-only" feel.
struct SyncLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            // Lock screen / banner — only seen when the user looks at lock
            // screen or the banner pops on activity start.
            LockScreenView(attrs: context.attributes, state: context.state)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        statusIcon(state: context.state).foregroundStyle(phaseColor(for: context.state.phase))
                        Text(label(for: context.state.phase))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(phaseColor(for: context.state.phase))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(progressLabel(state: context.state))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progressFraction(state: context.state))
                        .tint(phaseColor(for: context.state.phase))
                }
            } compactLeading: {
                statusIcon(state: context.state)
                    .foregroundStyle(phaseColor(for: context.state.phase))
            } compactTrailing: {
                Text(progressLabel(state: context.state))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(phaseColor(for: context.state.phase))
            } minimal: {
                statusIcon(state: context.state)
                    .foregroundStyle(phaseColor(for: context.state.phase))
            }
        }
    }
}

private struct LockScreenView: View {
    let attrs: SyncActivityAttributes
    let state: SyncActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon(state: state).foregroundStyle(phaseColor(for: state.phase))
                Text(label(for: state.phase))
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(progressLabel(state: state))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressFraction(state: state))
                .tint(phaseColor(for: state.phase))
            Text(attrs.spaceName)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

@ViewBuilder
private func statusIcon(state: SyncActivityAttributes.ContentState) -> some View {
    switch state.phase {
    case .syncing: ProgressView().controlSize(.small)
    case .throttled: Image(systemName: "hourglass")
    case .offline: Image(systemName: "wifi.slash")
    }
}

private func label(for phase: SyncActivityAttributes.Phase) -> LocalizedStringKey {
    switch phase {
    case .syncing: return "正在同步"
    case .throttled: return "已限流"
    case .offline: return "离线"
    }
}

private func phaseColor(for phase: SyncActivityAttributes.Phase) -> Color {
    switch phase {
    case .syncing: return .secondary
    case .throttled, .offline: return .orange
    }
}

private func progressLabel(state: SyncActivityAttributes.ContentState) -> String {
    if state.total == 0 { return "…" }
    return "\(state.done)/\(state.total)"
}

private func progressFraction(state: SyncActivityAttributes.ContentState) -> Double {
    guard state.total > 0 else { return 0 }
    return min(1, Double(state.done) / Double(state.total))
}
