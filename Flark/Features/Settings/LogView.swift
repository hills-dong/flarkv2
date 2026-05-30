import SwiftUI
import FlarkKit

/// In-app diagnostics log. Subscribes to `FlarkLog` and renders every storage,
/// sync, repository, and AI transport event newest-first, with filters for
/// category and severity so you can audit both data movement and model
/// requests without leaving the app.
struct LogView: View {
    @State private var events: [LogEvent] = []
    @State private var subscriptionID: UUID?
    @State private var refreshTick = 0
    @State private var filterCategory: LogEvent.Category? = nil
    @State private var filterLevel: LogEvent.Level? = nil
    @State private var expandedID: UUID? = nil
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "暂无记录",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("操作发生后会立刻出现在这里"))
            } else {
                List {
                    Section {
                        HStack {
                            Text("\(filtered.count) / \(events.count)")
                            Spacer()
                            Text("最多保留 \(FlarkLog.shared.capacity) 条")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { event in
                        LogRow(event: event, expanded: expandedID == event.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                expandedID = expandedID == event.id ? nil : event.id
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("操作日志")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "按路径或动作筛选")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("分类") {
                        Picker("分类", selection: $filterCategory) {
                            Text("全部").tag(Optional<LogEvent.Category>.none)
                            Text("存储 (storage)").tag(Optional(LogEvent.Category.storage))
                            Text("仓库 (repo)").tag(Optional(LogEvent.Category.repo))
                            Text("同步 (sync)").tag(Optional(LogEvent.Category.sync))
                            Text("AI").tag(Optional(LogEvent.Category.ai))
                        }
                    }
                    Section("级别") {
                        Picker("级别", selection: $filterLevel) {
                            Text("全部").tag(Optional<LogEvent.Level>.none)
                            Text("Info").tag(Optional(LogEvent.Level.info))
                            Text("Warn").tag(Optional(LogEvent.Level.warn))
                            Text("Error").tag(Optional(LogEvent.Level.error))
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            FlarkLog.shared.clear()
                            events = []
                        } label: { Label("清空", systemImage: "trash") }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .onAppear {
            events = FlarkLog.shared.snapshot()
            let id = FlarkLog.shared.subscribe { event in
                Task { @MainActor in
                    events.append(event)
                    // Bound the in-view buffer to the same cap so a very
                    // chatty session doesn't keep growing the UI's array.
                    if events.count > FlarkLog.shared.capacity {
                        events.removeFirst(events.count - FlarkLog.shared.capacity)
                    }
                }
            }
            subscriptionID = id
        }
        .onDisappear {
            if let id = subscriptionID { FlarkLog.shared.unsubscribe(id) }
        }
    }

    /// Newest-first, search & category & level filtered.
    private var filtered: [LogEvent] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events.reversed().filter { e in
            (filterCategory == nil || e.category == filterCategory!) &&
            (filterLevel == nil || e.level == filterLevel!) &&
            (needle.isEmpty
                || e.action.lowercased().contains(needle)
                || (e.path ?? "").lowercased().contains(needle)
                || (e.detail ?? "").lowercased().contains(needle))
        }
    }
}

private struct LogRow: View {
    let event: LogEvent
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(levelColor).frame(width: 8, height: 8)
                Text(event.action).font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
                Text(event.category.rawValue.uppercased())
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                if let ms = event.durationMs { Text("\(ms)ms").font(.caption2).foregroundStyle(.secondary) }
                if let b = event.bytes { Text(formatBytes(b)).font(.caption2).foregroundStyle(.secondary) }
                Text(timeString).font(.caption2).foregroundStyle(.secondary)
            }
            if let path = event.path, !path.isEmpty {
                Text(displayPath(path))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.middle)
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(event.category == .ai
                        ? .system(.caption, design: .monospaced)
                        : .caption)
                    .foregroundStyle(expanded ? .primary : .secondary)
                    .lineLimit(expanded ? nil : 1)
            }
        }
        .padding(.vertical, 4)
    }

    private var levelColor: Color {
        switch event.level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: event.time)
    }

    /// Collapse "<spaceID>/events/<authorID>/<deviceID>/00000001.json" to
    /// "…/events/.../00000001.json" so the row stays scannable on phone.
    private func displayPath(_ p: String) -> String {
        guard !expanded else { return p }
        let parts = p.split(separator: "/")
        guard parts.count > 3 else { return p }
        return ".../" + parts.suffix(3).joined(separator: "/")
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024.0) }
        return String(format: "%.1fMB", Double(n) / (1024.0 * 1024.0))
    }
}
