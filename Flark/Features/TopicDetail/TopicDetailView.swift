import SwiftUI
import PhotosUI
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
    @State private var showPersonaPicker = false
    @State private var quickPhoto: PhotosPickerItem?
    /// Reference holder for the autosave debounce so cancel / reassign
    /// doesn't churn observable state (same pattern as `ComposerView`).
    @State private var quickAutosaveBox = AutosaveBox()
    /// Gates autosave until the initial DraftStore load lands, so the
    /// transient empty editor doesn't immediately clobber a stored draft.
    @State private var quickAutosaveArmed = false
    #if os(iOS)
    /// Live editor content height — drives the input bar's `.frame(height:)`
    /// so wrapped / multi-line drafts grow the bar naturally up to roughly
    /// ten body lines, then the internal scroll handles overflow.
    @State private var quickEditorHeight: CGFloat = 28
    /// Roughly 10 lines of body text. A constant beats re-measuring the
    /// font: exact metrics aren't critical, and emoji attachments are 1.44×
    /// the body line so this is generous enough to land near 8–9 emoji rows.
    private let quickEditorMaxHeight: CGFloat = 240
    #endif
    /// Bumped from every "user just sent a reply" path so the
    /// `.onChange` inside the ScrollViewReader can scroll the new reply
    /// into view. A nonce instead of e.g. `replies.count` so we *don't*
    /// auto-jump when someone else's reply lands while the user is
    /// reading further up.
    @State private var scrollToBottomNonce = 0
    /// SwiftUI scroll anchor at the very bottom of the content list.
    private let quickReplyBottomAnchor = "quickReplyBottomAnchor"

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
        ScrollViewReader { scrollProxy in
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
                    // AI-persona replies are authored by the user but carry a
                    // hidden persona marker: render the persona's name + initial
                    // avatar in the header, with a secondary note crediting the
                    // real user who summoned it.
                    let persona = PersonaTag.unwrap(reply.body.body)
                    let bodyDoc = persona.map { ContentDocument(body: $0.content) } ?? reply.body
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 10) {
                            if let persona {
                                AvatarView(authorID: persona.name, name: persona.name, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(persona.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("· 来自 \(model.displayName(for: reply.authorID))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    timeLine(createdAt: reply.createdAt, editedAt: reply.editedAt)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                AvatarView(authorID: reply.authorID,
                                           name: model.displayName(for: reply.authorID), size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.displayName(for: reply.authorID))
                                        .font(.subheadline.weight(.semibold))
                                    timeLine(createdAt: reply.createdAt, editedAt: reply.editedAt)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        ContentDocumentView(doc: bodyDoc, emojiFlyInSpace: flyInSpace)
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
                    .id(quickReplyBottomAnchor)
            }
        }
        // Nonce-driven jump-to-bottom: every send path (text reply *and*
        // image-only reply) bumps the nonce, this fires after the new row
        // has been laid out and brings the user's reply into view. The
        // tiny async hop is needed because the projection update + the
        // SwiftUI relayout that adds the new row happen across a render
        // tick — scrolling synchronously would target the old content
        // layout and stop short of the new bottom.
        .onChange(of: scrollToBottomNonce) { _, _ in
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.35)) {
                    scrollProxy.scrollTo(quickReplyBottomAnchor, anchor: .bottom)
                }
            }
        }
        // Standard chat-app feel: any scroll drops the keyboard right
        // away, and a tap anywhere in the conversation list also defocuses
        // the reply field. `simultaneousGesture` so reply-card taps and
        // reaction-panel long-presses keep working — both fire, the side
        // effect is the keyboard going away.
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            TapGesture().onEnded { quickFocused = false }
        )
        .background(Color.platformGrouped)
        .safeAreaInset(edge: .bottom) {
            // Two floating bars stacked tight: the top one is a 1-line
            // input + expand button (tap to fall back to the full
            // ComposerView for long drafts), the bottom one is the action
            // dock (emoji, photos, B/I, send). No `GlassGroup` wrapper
            // because on iOS 26 `GlassEffectContainer` stretches its
            // content vertically over the bottom inset, which turned an
            // earlier single-bar layout into a giant blank capsule.
            VStack(spacing: 6) {
                quickInputBar
                quickControlBar
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
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
        .sheet(isPresented: $showQuickEmoji) {
            EmojiPickerView(title: "选择表情") { item, _ in
                insertQuickEmoji(item)
            }
        }
        .sheet(isPresented: $replying) {
            ComposerView(mode: .newReply(topicID: topicID))
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerSheet { persona, guidance in
                showPersonaPicker = false
                Task {
                    await model.summonPersona(persona, inTopic: topicID, guidance: guidance)
                    scrollToBottomNonce &+= 1
                }
            }
        }
        .alert("AI 回复失败", isPresented: Binding(
            get: { model.aiError != nil },
            set: { if !$0 { model.aiError = nil } }
        )) {
            Button("好") { model.aiError = nil }
        } message: {
            Text(model.aiError ?? "")
        }
        .sheet(isPresented: $editingTopic) {
            if let t = model.projection.topics[topicID] {
                ComposerView(mode: .editTopic(topicID: topicID, body: t.body))
            }
        }
        .sheet(item: $editingReply) { target in
            // Strip the hidden persona marker so the editor shows only the
            // human-readable content; `editReply` re-applies it on save.
            let editable = PersonaTag.unwrap(target.body.body)
                .map { ContentDocument(body: $0.content) } ?? target.body
            ComposerView(mode: .editReply(replyID: target.id, body: editable))
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
        .onChange(of: quickPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let up = await model.uploadImage(data) {
                    // Image picker is a one-shot send: post the picked image
                    // as its own reply without ever routing it through the
                    // text editor. The user's typed draft is left untouched
                    // so they can keep composing alongside the photo reply.
                    let body = MarkdownCodec.serialize([.image(blobID: up.id)])
                    model.createReply(topicID: topicID, body: ContentDocument(body: body))
                    scrollToBottomNonce &+= 1
                }
                quickPhoto = nil
            }
        }
        .onDisappear {
            // Last chance to persist before the view tears down — covers
            // back-navigation away from the topic. Send/clear paths set
            // `quickAutosaveArmed = false` first so this is a no-op there.
            flushQuickAutosave()
        }
        }   // end ScrollViewReader

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

    /// Top bar — text input that grows with the draft (wrapped lines push
    /// the bar taller, up to ~10 lines, then the editor scrolls internally)
    /// plus an expand button to swap into the full ComposerView. The
    /// Return key here submits the reply instead of inserting a newline:
    /// new paragraphs are a "go expand" affordance, not an inline gesture.
    @ViewBuilder
    private var quickInputBar: some View {
        // `.center` so the placeholder, caret, and the expand button all
        // sit on the same vertical midline of the bar. For multi-line
        // drafts the editor still grows up evenly above and below — the
        // button floats centered against it, which reads cleaner than the
        // bottom-pinned variant once content takes a couple of rows.
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .leading) {
                if quickPlain.isEmpty {
                    Text("回复点什么…")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                #if os(iOS)
                RichTextEditor(attributedText: $quickAttr,
                               selection: $quickSelection,
                               typingStyle: $quickTypingStyle,
                               focused: $quickFocused,
                               scrollEnabled: true,
                               onNewlineAttempt: { sendQuickReply() },
                               contentHeight: $quickEditorHeight)
                    .frame(height: min(max(quickEditorHeight, 28), quickEditorMaxHeight))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Belt-and-braces clipping: UITextView's content can
                    // visually overflow the SwiftUI-imposed frame on some
                    // hosting paths even with `tv.clipsToBounds = true`.
                    .clipped()
                #else
                TextField("", text: $quickDraft, axis: .vertical)
                    .focused($quickFocused)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .onSubmit { sendQuickReply() }
                #endif
            }

            Button { expandQuickReply() } label: {
                // Same "expand to fullscreen" glyph as the original — just
                // rotated 90° so the arrows run along the bottom-left ↔
                // top-right diagonal instead of top-left ↔ bottom-right.
                // SF Symbols' `arrow.up.right.and.arrow.down.left` reads as
                // a shrink icon despite the name, so we keep the trusted
                // glyph and rotate it.
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(90))
                    .frame(width: 36, height: 36)
                    // Without `contentShape`, `.buttonStyle(.plain)` hit-tests
                    // only the glyph silhouette — a thin diagonal arrow is
                    // nearly impossible to tap. The Rectangle takes the
                    // whole 36×36 frame.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        // RoundedRectangle (not Capsule): once the bar grows to multiple
        // lines the capsule's height-following end caps balloon into ugly
        // half-circles. A fixed corner radius reads cleanly at any height.
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Bottom bar — the action dock. Mirrors the full ComposerView's
    /// toolbar (emoji, photos, B / I, send) so users get the same set of
    /// affordances without leaving the topic page for short replies.
    @ViewBuilder
    private var quickControlBar: some View {
        HStack(spacing: 4) {
            // 36×36 hit boxes with `contentShape(Rectangle())` are what make
            // these targetable — the bold / italic glyphs especially are
            // narrow strokes that hit-test the actual pixels otherwise.
            Button { showQuickEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            PhotosPicker(selection: $quickPhoto, matching: .images) {
                Image(systemName: "photo")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            #if os(iOS)
            Button { toggleQuickStyle(.bold) } label: {
                Image(systemName: "bold")
                    .font(.title3)
                    .foregroundStyle(quickTypingStyle.contains(.bold) ? Color.accentColor : .primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            Button { toggleQuickStyle(.italic) } label: {
                Image(systemName: "italic")
                    .font(.title3)
                    .foregroundStyle(quickTypingStyle.contains(.italic) ? Color.accentColor : .primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            #endif
            Button {
                quickFocused = false
                showPersonaPicker = true
            } label: {
                Group {
                    if model.aiGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars").font(.title3)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .disabled(model.aiGenerating)
            .help("召唤 AI 角色回复")
            Spacer()
            #if !os(macOS)
            Button {
                sendQuickReply()
            } label: {
                Image(systemName: "arrow.up").fontWeight(.bold)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(quickDoc.isEmpty)
            #endif
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .glassSurface(Capsule())
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

    #if os(iOS)
    /// Toggle a single style bit on the inline editor's selection — or, for
    /// a collapsed caret, flip the pending typing-style so the next typed
    /// run inherits it. Matches `ComposerView.toggleStyle` semantics.
    private func toggleQuickStyle(_ bit: Style) {
        if quickSelection.length > 0 {
            quickAttr = RichTextAttributes.toggle(bit, on: quickAttr, range: quickSelection)
        } else {
            if quickTypingStyle.contains(bit) { quickTypingStyle.remove(bit) }
            else { quickTypingStyle.insert(bit) }
        }
        quickFocused = true
    }
    #endif

    private func sendQuickReply() {
        let doc = quickDoc
        guard !doc.isEmpty else { return }
        model.createReply(topicID: topicID, body: doc)
        scrollToBottomNonce &+= 1
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
