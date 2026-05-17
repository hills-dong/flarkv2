import SwiftUI
import FlarkKit

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var composing = false
    @State private var showSpaces = false

    var body: some View {
        let topics = model.projection.topicsByRecency
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
        .navigationTitle(model.currentSpace?.name ?? "话题")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSpaces = true } label: { Image(systemName: "rectangle.stack") }
            }
        }
        .sheet(isPresented: $composing) { ComposerView(mode: .topic) }
        .sheet(isPresented: $showSpaces) { SpaceListView() }
    }
}

struct TopicCard: View {
    @Environment(AppModel.self) private var model
    let topic: TopicState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(authorID: topic.authorID, name: model.displayName(for: topic.authorID))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName(for: topic.authorID))
                        .font(.subheadline.weight(.semibold))
                    Text(Date(timeIntervalSince1970: Double(topic.createdAt) / 1000),
                         style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !topic.title.isEmpty {
                Text(topic.title).font(.headline)
            }
            ContentDocumentView(doc: topic.body)
                .lineLimit(4)
            ReactionBar(targetID: topic.id, targetType: .topic)
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                Text("回复 · \(topic.replyCount)")
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
