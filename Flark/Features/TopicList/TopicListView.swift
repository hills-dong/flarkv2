import SwiftUI
import FlarkKit

struct TopicListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var composing = false
    @State private var showSpaces = false
    @State private var showIdentity = false
    @State private var pendingDelete: TopicRow?

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
                                .swipeActions(edge: .trailing) {
                                    if model.canDeleteTopic(topic.id) {
                                        Button(role: .destructive) {
                                            pendingDelete = topic
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
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
            ToolbarItem(placement: .primaryAction) {
                Button { showIdentity = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .sheet(isPresented: $composing) { ComposerView(mode: .topic) }
        .sheet(isPresented: $showSpaces) { SpaceListView() }
        .sheet(isPresented: $showIdentity) { IdentitySettingsView() }
        .confirmationDialog("删除话题",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { topic in
            Button("删除话题", role: .destructive) {
                if selection == topic.id { selection = nil }
                model.deleteTopic(topic.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("删除后无法恢复。仅可删除没有任何互动的话题。")
        }
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
                    Text(Date(timeIntervalSince1970: Double(topic.createdAt) / 1000),
                         style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !topic.title.isEmpty {
                Text(topic.title).font(.headline)
            }
            if !topic.preview.isEmpty {
                Text(topic.preview)
                    .font(.body)
                    .lineLimit(4)
            }
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
