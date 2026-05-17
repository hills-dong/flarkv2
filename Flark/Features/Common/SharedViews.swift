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
struct BlobImage: View {
    let blobID: String
    var maxHeight: CGFloat = 200
    @Environment(AppModel.self) private var model
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let img = platformImage(data) {
                img.resizable().scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: maxHeight * 0.7)
                    .overlay(ProgressView())
            }
        }
        .task(id: blobID) { data = await model.loadImage(blobID) }
    }

    private func platformImage(_ d: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: d).map(Image.init(uiImage:))
        #else
        NSImage(data: d).map(Image.init(nsImage:))
        #endif
    }
}

/// Inline renderer for a ContentDocument (text + emoji + images), no styling.
struct ContentDocumentView: View {
    let doc: ContentDocument
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
                        ForEach(line.images, id: \.self) { BlobImage(blobID: $0) }
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
