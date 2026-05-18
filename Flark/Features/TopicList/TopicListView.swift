import SwiftUI
import FlarkKit

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var composing = false
    @State private var showSpaces = false
    @State private var showIdentity = false

    var body: some View {
        let topics = model.projection.topicRowsByRecency
        ZStack(alignment: .bottomTrailing) {
            Group {
                if topics.isEmpty {
                    ContentUnavailableView("还没有话题", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("点右下角 + 创建第一个话题"))
                } else {
                    List(selection: $selection) {
                        ForEach(topics) { topic in
                            TopicCard(topic: topic)
                                .tag(topic.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .reactionPanel(
                                    targetID: topic.id, targetType: .topic,
                                    onDelete: model.canDeleteTopic(topic.id) ? {
                                        if selection == topic.id { selection = nil }
                                        model.deleteTopic(topic.id)
                                    } : nil)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.platformGrouped)

            Button { composing = true } label: {
                Image(systemName: "plus").font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60)
            }
            .glassButton(Circle())
            .padding(24)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SyncStatusBar(status: model.syncStatus)
        }
        .navigationTitle(model.currentSpace?.name ?? "话题")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSpaces = true } label: { Image(systemName: "rectangle.stack") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showIdentity = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .sheet(isPresented: $composing) { ComposerView(mode: .topic) }
        .sheet(isPresented: $showSpaces) { SpaceListView() }
        .sheet(isPresented: $showIdentity) { IdentitySettingsView() }
    }
}

struct TopicCard: View {
    @Environment(AppModel.self) private var model
    let topic: TopicRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(authorID: topic.authorID, name: model.displayName(for: topic.authorID))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName(for: topic.authorID))
                        .font(.subheadline.weight(.semibold))
                    Text(EventTime.label(Int64(topic.createdAt)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !topic.preview.isEmpty {
                Text(topic.preview)
                    .font(.body)
                    .lineLimit(4)
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
        .contentShape(Rectangle())
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
