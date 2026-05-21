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
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var segments: [ContentDocument.Segment]
    @State private var showEmoji = false
    @State private var photo: PhotosPickerItem?
    @FocusState private var focused: Bool

    #if os(iOS)
    @State private var draftAttr: NSAttributedString
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var typingStyle: ContentDocument.TextStyle? = nil

    private var draftSegments: [ContentDocument.Segment] { segmentsFromAttributed(draftAttr) }
    private var draftPlain: String { draftAttr.string }
    #else
    @State private var draft: String
    private var draftSegments: [ContentDocument.Segment] {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [.text(draft)]
    }
    private var draftPlain: String { draft }
    #endif

    init(mode: Mode) {
        self.mode = mode
        // Prefill: split the initial body into (committed prelude + trailing
        // text/styled run). The trailing run goes into the live editor so it
        // can be edited; emoji/images and anything preceding them stay above
        // as already-committed segments. New-* modes start empty.
        let body = mode.initialBody
        var prelude: [ContentDocument.Segment] = body.segments
        var trailing: [ContentDocument.Segment] = []
        while let last = prelude.last, isInlineText(last) {
            trailing.insert(prelude.removeLast(), at: 0)
        }
        _segments = State(initialValue: prelude)
        #if os(iOS)
        _draftAttr = State(initialValue: attributedString(fromSegments: trailing))
        #else
        _draft = State(initialValue: trailing.reduce(into: "") { acc, seg in
            switch seg {
            case .text(let s), .styledText(let s, _): acc += s
            default: break
            }
        })
        #endif
    }

    private var liveDoc: ContentDocument {
        ContentDocument(segments: segments + draftSegments)
    }

    private func commitDraft() {
        segments.append(contentsOf: draftSegments)
        clearDraft()
    }

    private func clearDraft() {
        #if os(iOS)
        draftAttr = NSAttributedString()
        selection = NSRange(location: 0, length: 0)
        #else
        draft = ""
        #endif
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
                        if !segments.isEmpty {
                            ContentDocumentView(doc: ContentDocument(segments: segments))
                        }
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
                    Button("取消") { dismiss() }
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
            .onChange(of: photo) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let up = await model.uploadImage(data) {
                        commitDraft()
                        segments.append(.image(blobID: up.id, width: up.w, height: up.h))
                    }
                    photo = nil
                }
            }
            .onAppear { focused = true }
        }
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draftPlain.isEmpty {
                Text(segments.isEmpty ? "写点什么… 图片和表情直接在此输入框内所见即所得" : "继续输入…")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4).padding(.leading, 1)
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            RichTextEditor(attributedText: $draftAttr,
                           selection: $selection,
                           typingStyle: $typingStyle,
                           focused: $focused)
                .frame(minHeight: 28)
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

/// True for inline text-like segments (text or styled text). Emoji and images
/// are kept as committed segments and not pulled into the live editor.
private func isInlineText(_ seg: ContentDocument.Segment) -> Bool {
    switch seg {
    case .text, .styledText: return true
    case .emoji, .image: return false
    }
}
