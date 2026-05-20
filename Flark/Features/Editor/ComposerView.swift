import SwiftUI
import PhotosUI
import FlarkKit

/// The content editor. The input box itself is the live WYSIWYG preview:
/// inserted emoji and images render inline immediately, no separate preview.
struct ComposerView: View {
    enum Mode { case topic, reply }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    var topicID: String? = nil

    @State private var segments: [ContentDocument.Segment] = []
    @State private var draft = ""
    @State private var showEmoji = false
    @State private var photo: PhotosPickerItem?
    @FocusState private var focused: Bool

    private var liveDoc: ContentDocument {
        var s = segments
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { s.append(.text(draft)) }
        return ContentDocument(segments: s)
    }

    private func commitDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { segments.append(.text(draft)) }
        draft = ""
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // WYSIWYG input box
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !segments.isEmpty {
                            ContentDocumentView(doc: ContentDocument(segments: segments))
                        }
                        // TextEditor (not a vertical-axis TextField) so the
                        // Return key inserts real newlines instead of being
                        // swallowed as a submit action.
                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text(segments.isEmpty ? "写点什么… 图片和表情直接在此输入框内所见即所得" : "继续输入…")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $draft)
                                .focused($focused)
                                .scrollContentBackground(.hidden)
                                .scrollDisabled(true)
                                .frame(minHeight: 28)
                        }
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
                // on macOS the nav-bar "发布" button is the sole send action,
                // so showing a second big blue circle would be redundant.
                GlassGroup {
                    HStack(spacing: 14) {
                        Button { commitDraft(); showEmoji = true } label: {
                            Image(systemName: "face.smiling").font(toolbarIconFont)
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Image(systemName: "photo").font(toolbarIconFont)
                        }
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
            .navigationTitle(mode == .topic ? "新话题" : "回复")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { send() }
                        .disabled(liveDoc.isEmpty)
                }
            }
            .sheet(isPresented: $showEmoji) {
                EmojiPickerView(title: "选择表情") { item in
                    commitDraft()
                    segments.append(.emoji(id: item.id))
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

    private func send() {
        let doc = liveDoc
        guard !doc.isEmpty else { return }
        switch mode {
        case .topic:
            model.createTopic(body: doc)
        case .reply:
            if let tid = topicID { model.createReply(topicID: tid, body: doc) }
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
