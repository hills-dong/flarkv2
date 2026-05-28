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

    // Inline quick-reply state. Mirrors the `.newReply` DraftStore entry so
    // dismissing / swiping the full ComposerView doesn't strand its content
    // out of view — the inline bar always shows the same draft the composer
    // would open with, no matter which surface was last edited.
    #if os(iOS)
    @State private var quickAttr = NSAttributedString()
    @State private var quickSelection = NSRange(location: 0, length: 0)
    @State private var quickTypingStyle: Style = []
    #else
    @State private var quickDraft = ""
    #endif
    @FocusState private var quickFocused: Bool
    @State private var showQuickEmoji = false
    /// Reference holder for the autosave debounce so cancel / reassign
    /// doesn't churn observable state (same pattern as `ComposerView`).
    @State private var quickAutosaveBox = AutosaveBox()
    /// Gates autosave until the initial DraftStore load lands, so the
    /// transient empty editor doesn't immediately clobber a stored draft.
    @State private var quickAutosaveArmed = false

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
                quickReplyBar
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
            #if os(iOS)
            // Send button rides on the keyboard accessory — only visible
            // while the inline quick-reply field is the first responder.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    sendQuickReply()
                } label: {
                    Image(systemName: "arrow.up")
                        .fontWeight(.bold)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(quickDoc.isEmpty)
            }
            #endif
        }
        .sheet(isPresented: $showQuickEmoji) {
            EmojiPickerView(title: "选择表情") { item, _ in
                insertQuickEmoji(item)
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
        .task(id: topicID) {
            loadQuickDraftFromStore()
        }
        // ComposerView dismiss (swipe-down, cancel, send) all funnel through
        // here — it writes its latest state to DraftStore on disappear, so
        // re-reading the store mirrors that back into the inline bar. The
        // async hop ensures it runs after the sheet's own teardown.
        .onChange(of: replying) { _, isOpen in
            if !isOpen {
                DispatchQueue.main.async {
                    loadQuickDraftFromStore()
                }
            }
        }
        #if os(iOS)
        .onChange(of: quickAttr) { _, _ in scheduleQuickAutosave() }
        #else
        .onChange(of: quickDraft) { _, _ in scheduleQuickAutosave() }
        #endif
        .onDisappear {
            // Last chance to persist before the view tears down — covers
            // back-navigation away from the topic. Send/clear paths set
            // `quickAutosaveArmed = false` first so this is a no-op there.
            flushQuickAutosave()
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

    /// Inline composer that replaces the old "tap to open ComposerView"
    /// button. Left: emoji picker. Middle: in-place editable input that
    /// renders inserted emoji as inline image attachments (iOS). Right:
    /// expand button that hands the current draft to `ComposerView` via
    /// `DraftStore` for rich-text / image work.
    @ViewBuilder
    private var quickReplyBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { showQuickEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            ZStack(alignment: .topLeading) {
                if quickPlain.isEmpty {
                    Text("回复点什么…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4).padding(.leading, 1)
                        .allowsHitTesting(false)
                }
                // Cap on the editor's column — tall drafts get clipped here
                // and the user is one tap (pencil) away from the full editor.
                // Capping on the ZStack (not the editor itself) sidesteps a
                // quirk where `.frame(maxHeight:)` directly on a
                // UIViewRepresentable stretches it to the cap even when its
                // own intrinsic content is smaller.
                #if os(iOS)
                // Let the editor size to its content (UITextView's
                // `isScrollEnabled` stays false so its intrinsic height
                // tracks the text). No explicit min/max here — empty
                // content should land at ~one line height; tall drafts
                // are bounded by the outer `.frame(maxHeight:)` on the
                // surrounding ZStack so the bar never takes over the
                // screen.
                RichTextEditor(attributedText: $quickAttr,
                               selection: $quickSelection,
                               typingStyle: $quickTypingStyle,
                               focused: $quickFocused)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                #else
                TextField("", text: $quickDraft, axis: .vertical)
                    .focused($quickFocused)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .frame(minHeight: 28)
                #endif
            }
            .frame(maxHeight: 140)

            Button { expandQuickReply() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        // RoundedRectangle (not Capsule): the capsule's end-cap radius scales
        // to half the height, which on a multi-line composer balloons into
        // huge semicircles. A fixed corner radius keeps the shape sane as
        // the editor grows up to its `maxHeight`.
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var quickPlain: String {
        #if os(iOS)
        return quickAttr.string
        #else
        return quickDraft
        #endif
    }

    /// Markdown body for the inline draft. iOS routes through
    /// `markdownFromAttributed` so inline emoji attachments serialize as
    /// `[id]`; macOS escapes plain text wholesale (no inline emoji
    /// attachments exist on that path).
    private var quickDoc: ContentDocument {
        #if os(iOS)
        return ContentDocument(body: markdownFromAttributed(quickAttr))
        #else
        let t = quickDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentDocument(body: t.isEmpty ? "" : MarkdownCodec.escape(quickDraft))
        #endif
    }

    private func insertQuickEmoji(_ item: EmojiItem) {
        model.recordEmojiUsage(item.id)
        #if os(iOS)
        let m = NSMutableAttributedString(attributedString: quickAttr)
        let pos = min(max(quickSelection.location, 0), m.length)
        let frag = emojiAttachmentString(item: item)
        m.insert(frag, at: pos)
        quickAttr = m
        quickSelection = NSRange(location: pos + frag.length, length: 0)
        #else
        quickDraft += item.placeholder
        #endif
        quickFocused = true
    }

    private func sendQuickReply() {
        let doc = quickDoc
        guard !doc.isEmpty else { return }
        model.createReply(topicID: topicID, body: doc)
        // Finalize the draft on the same tick so the pending autosave (which
        // a moment from now would write the about-to-be-empty inline back to
        // disk) can't resurrect the sent text.
        quickAutosaveArmed = false
        quickAutosaveBox.task?.cancel()
        if let localID = model.currentSpace?.localID {
            DraftStore.clear(key: .newReply(topicID: topicID), localID: localID)
        }
        resetQuickReply()
        quickAutosaveArmed = true
    }

    /// Hand the inline draft off to the full ComposerView. The two surfaces
    /// share the same DraftStore key, so a flush here means the composer
    /// opens already prefilled with whatever was in the bar.
    private func expandQuickReply() {
        flushQuickAutosave()
        quickFocused = false
        replying = true
    }

    private func resetQuickReply() {
        #if os(iOS)
        quickAttr = NSAttributedString()
        quickSelection = NSRange(location: 0, length: 0)
        quickTypingStyle = []
        #else
        quickDraft = ""
        #endif
    }

    /// Load `.newReply` from DraftStore into the inline bar. Called on first
    /// appearance and whenever the full ComposerView closes (covers
    /// swipe-down dismiss, where the composer's `onDisappear` writes its
    /// final state and we need to mirror it back).
    private func loadQuickDraftFromStore() {
        guard let localID = model.currentSpace?.localID else {
            quickAutosaveArmed = true
            return
        }
        let doc = DraftStore.load(key: .newReply(topicID: topicID), localID: localID)
        #if os(iOS)
        // Synchronous load: keeps the user's just-started typing from being
        // raced over by an async hydration. Inline drafts rarely carry
        // images; if they do, the segment markers survive as zero-sized
        // attachments and the full editor (which does async-hydrate) will
        // render them properly once the user expands.
        let attr = doc.map {
            attributedString(fromMarkdown: $0.body, catalog: model.emoji)
        } ?? NSAttributedString()
        quickAttr = attr
        quickSelection = NSRange(location: attr.length, length: 0)
        quickTypingStyle = []
        #else
        quickDraft = doc?.plainText(catalog: model.emoji) ?? ""
        #endif
        quickAutosaveArmed = true
    }

    /// Debounced write: every keystroke schedules a save 500ms out, so a
    /// burst of typing collapses to one disk write but no in-flight pause
    /// gets longer than that before the draft is durable.
    private func scheduleQuickAutosave() {
        guard quickAutosaveArmed else { return }
        quickAutosaveBox.task?.cancel()
        let doc = quickDoc
        guard let localID = model.currentSpace?.localID else { return }
        quickAutosaveBox.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            DraftStore.save(doc, key: .newReply(topicID: topicID),
                            localID: localID, initial: ContentDocument())
        }
    }

    /// Flush the debounce immediately — used when control is about to
    /// transfer to the full ComposerView (so it loads our latest content)
    /// or when the view is going away.
    private func flushQuickAutosave() {
        quickAutosaveBox.task?.cancel()
        guard quickAutosaveArmed, let localID = model.currentSpace?.localID else { return }
        DraftStore.save(quickDoc, key: .newReply(topicID: topicID),
                        localID: localID, initial: ContentDocument())
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
