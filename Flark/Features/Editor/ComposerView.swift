import SwiftUI
import PhotosUI
import FlarkKit

/// The content editor. The input box itself is the live WYSIWYG preview:
/// inserted emoji and images render inline immediately, no separate preview.
struct ComposerView: View {
    enum Mode {
        case newTopic
        case newReply(topicID: String)
        case editTopic(topicID: String, body: ContentDocument)
        case editReply(replyID: String, body: ContentDocument)

        var initialBody: ContentDocument {
            switch self {
            case .newTopic, .newReply: return ContentDocument()
            case .editTopic(_, let b), .editReply(_, let b): return b
            }
        }

        var draftKey: DraftKey {
            switch self {
            case .newTopic: return .newTopic
            case .newReply(let id): return .newReply(topicID: id)
            case .editTopic(let id, _): return .editTopic(topicID: id)
            case .editReply(let id, _): return .editReply(replyID: id)
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .newTopic: return "新话题"
            case .newReply: return "回复"
            case .editTopic: return "编辑话题"
            case .editReply: return "编辑回复"
            }
        }

        var confirmLabel: LocalizedStringKey {
            switch self {
            case .editTopic, .editReply: return "保存"
            default: return "发布"
            }
        }

        var placeholder: LocalizedStringKey {
            switch self {
            case .newTopic, .editTopic: return "写点什么…"
            case .newReply, .editReply: return "回复点什么…"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let mode: Mode

    @State private var showEmoji = false
    @State private var photo: PhotosPickerItem?
    @FocusState private var focused: Bool

    /// Debounce token for auto-save. Cancelled on every keystroke and
    /// flushed when the composer disappears or the app backgrounds.
    @State private var saveTask: Task<Void, Never>?
    /// Auto-save is disabled until the initial prefill (which may load image
    /// blobs asynchronously) lands. Otherwise the transient empty editor
    /// would immediately clear an in-progress edit draft.
    @State private var autosaveArmed = false
    /// True once the user has explicitly sent or cancelled. In that case we
    /// must NOT re-save in `onDisappear` — they've already opted to discard.
    @State private var draftFinalized = false
    @State private var showDiscardConfirm = false

    #if os(iOS)
    @State private var draftAttr: NSAttributedString = NSAttributedString()
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var typingStyle: ContentDocument.TextStyle? = nil

    private var draftSegments: [ContentDocument.Segment] { segmentsFromAttributed(draftAttr) }
    private var draftPlain: String { draftAttr.string }
    #else
    @State private var draft: String = ""
    private var draftSegments: [ContentDocument.Segment] {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [.text(draft)]
    }
    private var draftPlain: String { draft }
    #endif

    @State private var didPrefill = false

    /// Load the initial body into the editor as one editable WYSIWYG
    /// attributed string: text / styled text / emoji / images all become
    /// inline attribute runs (images via `InlineImageAttachment`). Image
    /// blobs are pulled from `model.loadImage` first so they render with
    /// real bitmaps; missing blobs still round-trip as zero-sized boxes
    /// (the segment markers are on the attachment, not on the bytes).
    private func prefillFromMode() {
        // Persisted draft (from a previous unclean exit) wins over the mode's
        // initial body — that's the whole point of auto-save. For edit modes
        // the draft is only persisted when it diverged from the initial body
        // (see `DraftStore.save`), so falling back to `initialBody` here gives
        // the latest remote-edited content when no local draft exists.
        let saved: ContentDocument? = model.currentSpace
            .flatMap { DraftStore.load(key: mode.draftKey, localID: $0.localID) }
        let body = saved ?? mode.initialBody
        #if os(iOS)
        Task {
            var blobs: [String: Data] = [:]
            for seg in body.segments {
                if case .image(let id, _, _) = seg, blobs[id] == nil {
                    if let d = await model.loadImage(id) { blobs[id] = d }
                }
            }
            let attr = attributedString(fromSegments: body.segments,
                                        catalog: model.emoji,
                                        images: blobs)
            await MainActor.run {
                draftAttr = attr
                selection = NSRange(location: attr.length, length: 0)
                autosaveArmed = true
            }
        }
        #else
        // macOS `TextEditor` can't render inline images; flatten to text.
        draft = body.segments.reduce(into: "") { acc, seg in
            switch seg {
            case .text(let s), .styledText(let s, _): acc += s
            case .emoji(let id): acc += (model.emoji.item(id)?.placeholder ?? "[\(id)]")
            case .image: break
            }
        }
        autosaveArmed = true
        #endif
    }

    /// Debounced auto-save. Writing after every keystroke would thrash the
    /// disk; 500ms is well below the typical crash/backgrounding window and
    /// covers the case where the user pauses, then the app is killed.
    private func scheduleAutosave() {
        guard autosaveArmed, !draftFinalized else { return }
        saveTask?.cancel()
        let doc = liveDoc
        let key = mode.draftKey
        let initial = mode.initialBody
        guard let localID = model.currentSpace?.localID else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            DraftStore.save(doc, key: key, localID: localID, initial: initial)
        }
    }

    /// Synchronous flush — used when we can't wait for the debounce (sheet
    /// dismissed, scene backgrounded). Caller must check `autosaveArmed` so
    /// we don't overwrite a not-yet-prefilled body with the empty editor.
    private func flushAutosave() {
        saveTask?.cancel()
        guard autosaveArmed, !draftFinalized else { return }
        guard let localID = model.currentSpace?.localID else { return }
        DraftStore.save(liveDoc, key: mode.draftKey, localID: localID, initial: mode.initialBody)
    }

    private func clearDraft() {
        saveTask?.cancel()
        draftFinalized = true
        guard let localID = model.currentSpace?.localID else { return }
        DraftStore.clear(key: mode.draftKey, localID: localID)
    }

    private var liveDoc: ContentDocument {
        ContentDocument(segments: draftSegments)
    }

    /// True when the editor diverges from where the user started — i.e.,
    /// cancelling would actually throw away work. For new modes that's "any
    /// non-empty content"; for edit modes that's "anything different from
    /// the body we prefilled".
    private var hasUnsavedChanges: Bool {
        let doc = liveDoc
        switch mode {
        case .newTopic, .newReply:
            return !doc.isEmpty
        case .editTopic(_, let body), .editReply(_, let body):
            return doc != body
        }
    }

    private var discardConfirmMessage: LocalizedStringKey {
        switch mode {
        case .editTopic, .editReply: return "放弃此次编辑吗？已修改的内容将不会保存。"
        default: return "放弃这条草稿吗？"
        }
    }

    /// Splice an emoji into the live editor at the current caret. The image
    /// rides along as an `NSTextAttachment`, so the cursor lands right after
    /// it and the user can keep typing on the same line — no commit / no
    /// auto-newline / no re-focus dance.
    private func insertEmoji(_ item: EmojiItem) {
        #if os(iOS)
        let m = NSMutableAttributedString(attributedString: draftAttr)
        let pos = min(max(selection.location, 0), m.length)
        let frag = emojiAttachmentString(item: item)
        m.insert(frag, at: pos)
        draftAttr = m
        selection = NSRange(location: pos + frag.length, length: 0)
        #else
        draft += item.placeholder
        #endif
    }

    #if os(iOS)
    /// Splice an inline image attachment into the editor at the current
    /// caret. Inserts surrounding newlines only when needed so the image
    /// lands on its own line; cursor parks on the line after the image so
    /// the user can keep typing without another tap.
    private func insertImage(blobID: String, w: Int, h: Int, data: Data?) {
        let m = NSMutableAttributedString(attributedString: draftAttr)
        let pos = min(max(selection.location, 0), m.length)
        let ns = m.string as NSString

        // Newlines just promote the image to its own paragraph; the actual
        // vertical gutter is controlled by the paragraph style baked into
        // `imageAttachmentString`, so plain body-font `\n`s are fine here.
        let nlAttrs = RichTextAttributes.typing(for: nil)
        let needsLeadingNL = pos > 0 && ns.substring(with: NSRange(location: pos - 1, length: 1)) != "\n"
        let needsTrailingNL = pos == m.length || ns.substring(with: NSRange(location: pos, length: 1)) != "\n"

        var cursor = pos
        if needsLeadingNL {
            m.insert(NSAttributedString(string: "\n", attributes: nlAttrs), at: cursor)
            cursor += 1
        }
        let frag = imageAttachmentString(blobID: blobID, w: w, h: h, data: data)
        m.insert(frag, at: cursor)
        cursor += frag.length
        if needsTrailingNL {
            m.insert(NSAttributedString(string: "\n", attributes: nlAttrs), at: cursor)
            cursor += 1
        }
        draftAttr = m
        selection = NSRange(location: cursor, length: 0)
    }
    #endif

    #if os(iOS)
    private func toggleStyle(_ style: ContentDocument.TextStyle) {
        if selection.length > 0 {
            // Apply/remove on the current selection. Prior input stays editable.
            draftAttr = RichTextAttributes.toggle(style, on: draftAttr, range: selection)
        } else {
            typingStyle = (typingStyle == style) ? nil : style
        }
        focused = true
    }
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        editor
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(Color.platformBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5))

                Spacer(minLength: 0)

                // Liquid Glass toolbar. The send button only appears on iOS;
                // on macOS the nav-bar action is the sole send button.
                GlassGroup {
                    HStack(spacing: 14) {
                        Button { showEmoji = true } label: {
                            Image(systemName: "face.smiling").font(toolbarIconFont)
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Image(systemName: "photo").font(toolbarIconFont)
                        }
                        #if os(iOS)
                        Button { toggleStyle(.bold) } label: {
                            Image(systemName: "bold")
                                .font(toolbarIconFont)
                                .foregroundStyle(typingStyle == .bold ? Color.accentColor : .primary)
                        }
                        Button { toggleStyle(.italic) } label: {
                            Image(systemName: "italic")
                                .font(toolbarIconFont)
                                .foregroundStyle(typingStyle == .italic ? Color.accentColor : .primary)
                        }
                        #endif
                        Spacer()
                        #if !os(macOS)
                        Button {
                            send()
                        } label: {
                            Image(systemName: "arrow.up").fontWeight(.bold)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor, in: Circle())
                                .foregroundStyle(.white)
                        }
                        .disabled(liveDoc.isEmpty)
                        #endif
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassSurface(Capsule())
                }
            }
            .padding(16)
            .background(Color.platformGrouped)
            .navigationTitle(mode.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        // Explicit cancel discards the auto-saved draft. If
                        // there's content the user could lose (anything that
                        // diverges from the initial body), confirm first so
                        // an accidental tap doesn't wipe their work.
                        if hasUnsavedChanges {
                            showDiscardConfirm = true
                        } else {
                            clearDraft()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.confirmLabel) { send() }
                        .disabled(liveDoc.isEmpty)
                }
            }
            .sheet(isPresented: $showEmoji) {
                EmojiPickerView(title: "选择表情") { item in
                    insertEmoji(item)
                    focused = true
                }
            }
            .confirmationDialog("",
                                isPresented: $showDiscardConfirm,
                                titleVisibility: .hidden) {
                Button("放弃更改", role: .destructive) {
                    clearDraft()
                    dismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text(discardConfirmMessage)
            }
            .onChange(of: photo) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let up = await model.uploadImage(data) {
                        #if os(iOS)
                        // Use the recompressed bytes the model wrote into the
                        // blob store (via `loadImage`) so the inline preview
                        // matches what other clients will see, not the raw
                        // HEIC straight from Photos.
                        let blob = await model.loadImage(up.id) ?? data
                        insertImage(blobID: up.id, w: up.w, h: up.h, data: blob)
                        focused = true
                        #endif
                    }
                    photo = nil
                }
            }
            .onAppear {
                if !didPrefill {
                    didPrefill = true
                    prefillFromMode()
                }
                // Sheet presentation + keyboard come up reliably together
                // only after the sheet's transition lands; without a short
                // delay the first-open keyboard sometimes silently no-ops.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focused = true
                }
            }
            #if os(iOS)
            .onChange(of: draftAttr) { _, _ in scheduleAutosave() }
            #else
            .onChange(of: draft) { _, _ in scheduleAutosave() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                // Background / inactive is our last chance to persist before
                // the OS may suspend or kill the app; bypass the debounce.
                if phase != .active { flushAutosave() }
            }
            .onDisappear {
                // Covers sheet-swipe-down and any other implicit dismiss:
                // we want the in-progress content to be there next time.
                // Send/Cancel set `draftFinalized` first, so this is a no-op
                // for those explicit-exit paths.
                flushAutosave()
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draftPlain.isEmpty {
                Text(mode.placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4).padding(.leading, 1)
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            RichTextEditor(attributedText: $draftAttr,
                           selection: $selection,
                           typingStyle: $typingStyle,
                           focused: $focused,
                           autoFocusOnAppear: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            #else
            TextEditor(text: $draft)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 28)
            #endif
        }
    }

    private func send() {
        let doc = liveDoc
        guard !doc.isEmpty else { return }
        switch mode {
        case .newTopic:
            model.createTopic(body: doc)
        case .newReply(let topicID):
            model.createReply(topicID: topicID, body: doc)
        case .editTopic(let topicID, _):
            model.editTopic(topicID, body: doc)
        case .editReply(let replyID, _):
            model.editReply(replyID, body: doc)
        }
        clearDraft()
        dismiss()
    }

    private var toolbarIconFont: Font {
        #if os(macOS)
        .body
        #else
        .title3
        #endif
    }
}
