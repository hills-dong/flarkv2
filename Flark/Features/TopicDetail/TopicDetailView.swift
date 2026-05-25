import SwiftUI
import FlarkKit

struct TopicDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let topicID: String
    @State private var replying = false
    @State private var editingTopic = false
    @State private var editingReply: EditingReply? = nil
    /// Per-detail-page host for emoji fly-in flights. Recreated on each
    /// `TopicDetailView` instantiation; the dedupe set (which emoji ids
    /// have already played) lives in the app-scope `EmojiFlyInTracker`
    /// instead, so reopening the same topic in one session won't re-fire.
    @State private var flightHost = EmojiFlightHost()

    /// Coordinate space the source modifiers + overlay both anchor to.
    /// Frames captured by `GeometryReader` here resolve in this space, and
    /// the overlay positions its in-flight emoji in this same space.
    private let flyInSpace = "topicDetailRoot"

    private struct EditingReply: Identifiable {
        let id: String
        let body: ContentDocument
    }

    var body: some View {
        let topic = model.projection.topics[topicID]
        let replies = model.projection.replies(forTopic: topicID)

        ZStack(alignment: .topLeading) {
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
                                timeLine(createdAt: topic.createdAt, editedAt: topic.editedAt)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ContentDocumentView(doc: topic.body, emojiFlyInSpace: flyInSpace)
                        ReactionBar(targetID: topic.id, targetType: .topic,
                                    emojiFlyInSpace: flyInSpace)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                    .contentShape(Rectangle())
                    .reactionPanel(
                        targetID: topic.id, targetType: .topic,
                        onEdit: model.canEditTopic(topic.id) ? {
                            editingTopic = true
                        } : nil,
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
                        HStack(alignment: .center, spacing: 10) {
                            AvatarView(authorID: reply.authorID,
                                       name: model.displayName(for: reply.authorID), size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.displayName(for: reply.authorID))
                                    .font(.subheadline.weight(.semibold))
                                timeLine(createdAt: reply.createdAt, editedAt: reply.editedAt)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        ContentDocumentView(doc: reply.body, emojiFlyInSpace: flyInSpace)
                            .padding(.leading, 42)
                        ReactionBar(targetID: reply.id, targetType: .reply,
                                    emojiFlyInSpace: flyInSpace)
                            .padding(.leading, 42)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .reactionPanel(
                        targetID: reply.id, targetType: .reply,
                        onEdit: model.canEditReply(reply.id) ? {
                            editingReply = EditingReply(id: reply.id, body: reply.body)
                        } : nil,
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
                        Text("回复点什么…").foregroundStyle(.secondary)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Easter egg: pick a random emoji currently in the
                    // viewport and play its fly-around animation.
                    flightHost.flyRandom()
                } label: {
                    Image(systemName: "sparkles")
                }
                .help("随机飞入一个表情")
            }
        }
        .sheet(isPresented: $replying) {
            ComposerView(mode: .newReply(topicID: topicID))
        }
        .sheet(isPresented: $editingTopic) {
            if let t = model.projection.topics[topicID] {
                ComposerView(mode: .editTopic(topicID: topicID, body: t.body))
            }
        }
        .sheet(item: $editingReply) { target in
            ComposerView(mode: .editReply(replyID: target.id, body: target.body))
        }

            EmojiFlightOverlay(host: flightHost)
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(flyInSpace))
        .environment(flightHost)
        // Same host, surfaced via an optional environment key so
        // `ReactionActionPanel` (which can also be presented from the
        // topic-list, where no host exists) can read it without
        // crashing on the list page.
        .environment(\.optionalEmojiFlightHost, flightHost)
    }

    /// "时间戳" + (optional) " · 已编辑 时间戳" suffix as one Text run so the
    /// caller can apply `.font` / `.foregroundStyle` once.
    private func timeLine(createdAt: Int64, editedAt: Int64?) -> Text {
        let base = Text(EventTime.label(Int64(createdAt)))
        if let editedAt {
            return base + Text("  ·  已编辑 \(EventTime.label(editedAt))")
        }
        return base
    }
}
