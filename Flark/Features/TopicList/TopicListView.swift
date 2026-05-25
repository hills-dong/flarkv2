import SwiftUI
import FlarkKit

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var composing = false
    @State private var showSpaces = false
    @State private var showIdentity = false
    @State private var editingTopic: EditingTopic? = nil

    /// True on iPad (regardless of orientation) and macOS — i.e. anywhere
    /// `NavigationSplitView` keeps the master column visible next to the
    /// detail. Originally we keyed this off `horizontalSizeClass == .regular`,
    /// but inside NavigationSplitView's master column iPadOS 26 reports
    /// `.compact` in portrait (the column itself is narrow), so the iPad
    /// branch below was dead code on portrait and iPad portrait fell into
    /// the iPhone `List(selection:)` branch — which is what paints the
    /// accent-tinted selection ring around the tapped row.
    private var isSplitMaster: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return true
        #endif
    }

    fileprivate struct EditingTopic: Identifiable {
        let id: String
        let body: ContentDocument
    }

    var body: some View {
        let topics = model.projection.topicRowsByRecency
        ZStack(alignment: .bottomTrailing) {
            Group {
                if topics.isEmpty {
                    ContentUnavailableView("还没有话题", systemImage: "bubble.left.and.bubble.right",
                                           description: Text(emptyHint))
                } else {
                    topicList(topics)
                }
            }
            // On iOS use the grouped page color so cards stand out against
            // the gray sidebar; on macOS let the sidebar's translucent
            // material show through (painting opaque white over it made the
            // sidebar look like an unrelated white panel).
            #if !os(macOS)
            .background(Color.platformGrouped)
            #endif

            #if !os(macOS)
            // iOS: floating action button. On macOS the "+" lives in the
            // toolbar (added below) which is the platform idiom.
            Button { composing = true } label: {
                Image(systemName: "plus").font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60)
            }
            .glassButton(Circle())
            .padding(24)
            #endif
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SyncStatusBar(status: model.syncStatus)
        }
        .navigationTitle(model.currentSpace?.name ?? "话题")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button { composing = true } label: { Image(systemName: "plus") }
                    .help("新建话题（⇧⌘N）")
                    // ⌘N collides with WindowGroup's default "New Window";
                    // ⇧⌘N is free.
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button { showSpaces = true } label: { Image(systemName: "rectangle.stack") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showIdentity = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .sheet(isPresented: $composing) { ComposerView(mode: .newTopic) }
        .sheet(isPresented: $showSpaces) { SpaceListView() }
        .sheet(isPresented: $showIdentity) { IdentitySettingsView() }
        .sheet(item: $editingTopic) { target in
            ComposerView(mode: .editTopic(topicID: target.id, body: target.body))
        }
    }

    private var emptyHint: LocalizedStringKey {
        #if os(macOS)
        "点右上角 + 创建第一个话题（⇧⌘N）"
        #else
        "点右下角 + 创建第一个话题"
        #endif
    }

    /// iPad split view: drive selection ourselves via plain `Button` rows
    /// inside a `List` (no `selection:` binding) so iPadOS doesn't draw its
    /// chunky tint-colored selection ring. The card's own accent rail is
    /// the only selection cue.
    ///
    /// iPhone compact / macOS: use `List(selection:)` so the system can
    /// translate selection into a push to the detail column. The selection
    /// ring isn't visible there (compact width collapses the list away on
    /// tap), so the standard behavior is fine.
    @ViewBuilder
    private func topicList(_ topics: [TopicRow]) -> some View {
        if isSplitMaster {
            // iPad split view: no Button (iPadOS 26 paints a stuck red
            // active-button ring on plain Buttons inside a List), no List
            // selection binding. Just an onTapGesture on the card → set
            // selection ourselves → parent's NavigationSplitView updates
            // the detail column. The card's own accent rail is the only
            // selection cue.
            List {
                ForEach(topics) { topic in
                    TopicCard(topic: topic,
                              isSelected: selection == topic.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = topic.id }
                        .applyRowChrome(model: model, topicID: topic.id,
                                        selection: $selection, editingTopic: $editingTopic)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
        } else {
            // iPhone compact / macOS: keep List(selection:) so SwiftUI can
            // translate a row tap into a push of the detail. No accent
            // rail here — the list collapses away on tap anyway.
            List(selection: $selection) {
                ForEach(topics) { topic in
                    TopicCard(topic: topic, isSelected: false)
                        .tag(topic.id)
                        .applyRowChrome(model: model, topicID: topic.id,
                                        selection: $selection, editingTopic: $editingTopic)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
        }
    }
}

/// Shared row-level modifiers for both the iPad Button-driven list and the
/// iPhone selection-driven list (separators, insets, swipe-to-react panel).
private extension View {
    func applyRowChrome(model: AppModel, topicID: String,
                        selection: Binding<String?>,
                        editingTopic: Binding<TopicListView.EditingTopic?>) -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .reactionPanel(
                targetID: topicID, targetType: .topic,
                onEdit: model.canEditTopic(topicID) ? {
                    if let t = model.projection.topics[topicID] {
                        editingTopic.wrappedValue = TopicListView.EditingTopic(id: topicID, body: t.body)
                    }
                } : nil,
                onDelete: model.canDeleteTopic(topicID) ? {
                    if selection.wrappedValue == topicID { selection.wrappedValue = nil }
                    model.deleteTopic(topicID)
                } : nil)
    }
}

struct TopicCard: View {
    @Environment(AppModel.self) private var model
    let topic: TopicRow
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(authorID: topic.authorID, name: model.displayName(for: topic.authorID))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName(for: topic.authorID))
                        .font(.subheadline.weight(.semibold))
                    timestampLine
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !topic.previewBody.isEmpty {
                previewText
            }
            if !topic.images.isEmpty {
                TopicImageRow(images: topic.images)
            }
            ReactionBar(targetID: topic.id, targetType: .topic)
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                Text("回复 · \(topic.replyCount)")
                Spacer()
                if topic.replyCount > 0 {
                    Text("最后活跃 \(EventTime.label(Int64(topic.lastActivity)))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(alignment: .leading) {
            // Slim accent rail on the leading edge when this card is the
            // active selection in the split view (iPad). On iPhone compact
            // `isSelected` is always false and the list collapses away on
            // tap, so the rail is never visible there.
            if isSelected {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.18), value: isSelected)
        .contentShape(Rectangle())
    }

    /// "时间戳" + optional "· 已编辑" suffix as a single Text run.
    private var timestampLine: Text {
        let base = Text(EventTime.label(Int64(topic.createdAt)))
        if topic.editedAt != nil {
            return base + Text("  ·  已编辑")
        }
        return base
    }

    /// Same TextKit pipeline as topic detail / editor — emoji attachments
    /// align to text identically. Truncated to 4 lines via the underlying
    /// text container's `maximumNumberOfLines`.
    @ViewBuilder
    private var previewText: some View {
        #if canImport(UIKit)
        AttrInlineText(
            attributed: attributedInlineText(body: topic.previewBody, catalog: model.emoji),
            maxLines: 4
        )
        #else
        Text(ContentDocument(body: topic.previewBody).plainText(catalog: model.emoji))
            .font(.body).lineLimit(4)
        #endif
    }
}

/// Topic images shown as a single adaptive row of thumbnails. The number of
/// visible thumbnails and their height scale with the image count; if there
/// are more images than fit, the last one carries a "+N" overlay. Taps fall
/// through to the enclosing row so the topic still opens.
struct TopicImageRow: View {
    let images: [TopicRow.Image]

    /// At most 4 thumbnails on one row; the rest collapse into a "+N" badge.
    private var visible: [TopicRow.Image] { Array(images.prefix(4)) }
    private var overflow: Int { images.count - visible.count }

    private var height: CGFloat {
        switch images.count {
        case 1: return 180
        case 2: return 150
        default: return 110
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.offset) { idx, img in
                TopicImageThumbnail(blobID: img.blobID)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if idx == visible.count - 1 && overflow > 0 {
                            ZStack {
                                Color.black.opacity(0.4)
                                Text("+\(overflow)")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
            }
        }
    }
}

/// Lightweight, non-interactive image thumbnail for the list. Fills its frame
/// (center-cropped) and lets taps pass through to the topic row.
struct TopicImageThumbnail: View {
    let blobID: String
    @Environment(AppModel.self) private var model
    @State private var data: Data?

    var body: some View {
        // `Color.clear` takes exactly the size the parent proposes (fixed
        // height, flexible width). The image rides in an overlay so its
        // intrinsic size never feeds back into layout and stretches the row.
        Color.clear
            .overlay {
                if let data, let img = platformImage(data) {
                    img.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).overlay(ProgressView())
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .task(id: blobID) { data = await model.loadThumbnail(blobID) }
    }

    private func platformImage(_ d: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: d).map(Image.init(uiImage:))
        #else
        NSImage(data: d).map(Image.init(nsImage:))
        #endif
    }
}
