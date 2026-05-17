import SwiftUI
import FlarkKit

struct TopicDetailView: View {
    @Environment(AppModel.self) private var model
    let topicID: String
    @State private var replying = false

    var body: some View {
        let topic = model.projection.topics[topicID]
        let replies = model.projection.replies(forTopic: topicID)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let topic {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            AvatarView(authorID: topic.authorID,
                                       name: model.displayName(for: topic.authorID))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.displayName(for: topic.authorID))
                                    .font(.subheadline.weight(.semibold))
                                Text(Date(timeIntervalSince1970: Double(topic.createdAt) / 1000),
                                     style: .relative)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !topic.title.isEmpty {
                            Text(topic.title).font(.title3.weight(.bold))
                        }
                        ContentDocumentView(doc: topic.body)
                        ReactionBar(targetID: topic.id, targetType: .topic)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                    .padding(16)
                }

                Text("全部回复 · \(replies.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 4)

                ForEach(replies) { reply in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            AvatarView(authorID: reply.authorID,
                                       name: model.displayName(for: reply.authorID), size: 32)
                            Text(model.displayName(for: reply.authorID))
                                .font(.subheadline.weight(.semibold))
                            Text(Date(timeIntervalSince1970: Double(reply.createdAt) / 1000),
                                 style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ContentDocumentView(doc: reply.body)
                            .padding(.leading, 42)
                        ReactionBar(targetID: reply.id, targetType: .reply)
                            .padding(.leading, 42)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    Divider().padding(.leading, 18)
                }
                Color.clear.frame(height: 80)
            }
        }
        .background(Color.platformGrouped)
        .safeAreaInset(edge: .bottom) {
            GlassGroup {
                Button { replying = true } label: {
                    HStack {
                        Image(systemName: "face.smiling")
                        Text("写回复… 支持图片和表情").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "square.and.pencil")
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .glassSurface(Capsule())
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .navigationTitle("话题详情")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $replying) {
            ComposerView(mode: .reply, topicID: topicID)
        }
    }
}
