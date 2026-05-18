import SwiftUI
import FlarkKit

struct TopicDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
                                Text(EventTime.label(Int64(topic.createdAt)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ContentDocumentView(doc: topic.body)
                        ReactionBar(targetID: topic.id, targetType: .topic)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                    .contentShape(Rectangle())
                    .reactionPanel(
                        targetID: topic.id, targetType: .topic,
                        onDelete: model.canDeleteTopic(topic.id) ? {
                            model.deleteTopic(topic.id)
                            dismiss()
                        } : nil)
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
                            Text(EventTime.label(Int64(reply.createdAt)))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ContentDocumentView(doc: reply.body)
                            .padding(.leading, 42)
                        ReactionBar(targetID: reply.id, targetType: .reply)
                            .padding(.leading, 42)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .reactionPanel(
                        targetID: reply.id, targetType: .reply,
                        onDelete: model.canDeleteReply(reply.id) ? {
                            model.deleteReply(reply.id)
                        } : nil)
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
                    .contentShape(Capsule())
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
