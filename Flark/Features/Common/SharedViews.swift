import SwiftUI
import FlarkKit

/// Deterministic colored initial avatar (no central server → no avatar host).
struct AvatarView: View {
    let authorID: String
    let name: String
    var size: CGFloat = 38

    private var palette: [Color] {
        [.orange, .green, .purple, .pink, .blue, .teal, .indigo]
    }
    private var color: Color {
        palette[abs(authorID.hashValue) % palette.count]
    }
    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.first.map(String.init) ?? "?"))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// Renders one emoji: a bundled Lark image if present, else the Unicode fallback.
struct EmojiGlyph: View {
    let item: EmojiItem?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let file = item?.file,
               let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Emoji"),
               let data = try? Data(contentsOf: url) {
                #if canImport(UIKit)
                if let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                } else { fallback }
                #else
                if let ns = NSImage(data: data) {
                    Image(nsImage: ns).resizable().scaledToFit()
                } else { fallback }
                #endif
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var fallback: some View {
        Text(item?.unicode ?? "❓").font(.system(size: size * 0.95))
    }
}

/// Async image loaded from a content-addressed blob via the open Space.
/// Tap to open a full-screen, pinch-to-zoom viewer (unless `zoomEnabled` is false,
/// e.g. inside a tappable list row where the tap should navigate instead).
struct BlobImage: View {
    let blobID: String
    var maxHeight: CGFloat = 200
    var zoomEnabled: Bool = true
    @Environment(AppModel.self) private var model
    @State private var data: Data?
    @State private var showViewer = false

    var body: some View {
        Group {
            if let data, let img = platformImage(data) {
                img.resizable().scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { if zoomEnabled { showViewer = true } }
                    .accessibilityAddTraits(zoomEnabled ? .isButton : [])
                    .accessibilityHint(zoomEnabled ? Text("轻点放大查看") : Text(""))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: maxHeight * 0.7)
                    .overlay(ProgressView())
            }
        }
        .task(id: blobID) { data = await model.loadImage(blobID) }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showViewer) {
            if let data, let img = platformImage(data) {
                ImageZoomViewer(image: img)
            }
        }
        #else
        .sheet(isPresented: $showViewer) {
            if let data, let img = platformImage(data) {
                ImageZoomViewer(image: img)
            }
        }
        #endif
    }

    private func platformImage(_ d: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: d).map(Image.init(uiImage:))
        #else
        NSImage(data: d).map(Image.init(nsImage:))
        #endif
    }
}

/// Full-screen image viewer with pinch-to-zoom, pan, and double-tap-to-zoom.
struct ImageZoomViewer: View {
    let image: Image
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            image
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(scale > 1 ? drag : nil)
                .onTapGesture(count: 2) { toggleZoom() }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(Text("关闭"))
                    Spacer()
                }
                Spacer()
            }
            .padding(20)
        }
        #if canImport(UIKit)
        .statusBarHidden()
        #endif
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = clamp(lastScale * value)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= minScale { resetTransform() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if scale > minScale {
                resetTransform()
            } else {
                scale = 2.5
                lastScale = scale
            }
        }
    }

    private func resetTransform() {
        scale = minScale
        lastScale = minScale
        offset = .zero
        lastOffset = .zero
    }

    private func clamp(_ v: CGFloat) -> CGFloat {
        min(max(v, minScale), maxScale)
    }
}

/// Inline renderer for a ContentDocument (text + emoji + images), no styling.
struct ContentDocumentView: View {
    let doc: ContentDocument
    /// When false, images render as static previews (taps fall through to an
    /// enclosing row/link instead of opening the zoom viewer).
    var imagesZoomable: Bool = true
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                line.text.isEmpty && line.images.isEmpty ? nil :
                AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        if !line.inline.isEmpty {
                            (line.inline.reduce(Text("")) { $0 + $1 })
                                .font(.body)
                        }
                        ForEach(line.images, id: \.self) { BlobImage(blobID: $0, zoomEnabled: imagesZoomable) }
                    }
                )
            }
        }
    }

    private struct Line { var text = ""; var inline: [Text] = []; var images: [String] = [] }

    private var lines: [Line] {
        var line = Line()
        var all: [Line] = []
        for seg in doc.segments {
            switch seg {
            case .text(let s):
                line.text += s
                line.inline.append(Text(s))
            case .emoji(let id):
                line.text += " "
                let glyph = model.emoji.item(id)?.unicode ?? "🙂"
                line.inline.append(Text(glyph))
            case .image(let blob, _, _):
                all.append(line); line = Line()
                line.images.append(blob)
                all.append(line); line = Line()
            }
        }
        all.append(line)
        return all
    }
}
