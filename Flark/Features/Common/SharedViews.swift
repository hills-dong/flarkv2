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

/// SwiftUI Image loaded from `Resources/Emoji/<file>` (file is a relative
/// path like `lark/lol.png`). Returns nil if the asset is missing — callers
/// render a placeholder box instead.
///
/// Pass `sizedTo` to pre-rasterise at a specific point-size; needed when
/// embedding inside `Text(Image(...))` (which renders the image at its
/// natural pixel size, breaking layout for 96×96 stickers).
func loadEmojiImage(_ file: String?, sizedTo target: CGFloat? = nil,
                    hPadding: CGFloat = 0) -> Image? {
    guard let file else { return nil }
    let cacheKey = "\(file)@\(target ?? -1)+\(hPadding)"
    if let cached = emojiImageCache[cacheKey] { return cached }
    guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Emoji"),
          let data = try? Data(contentsOf: url) else { return nil }

    let img: Image?
    #if canImport(UIKit)
    guard let ui = UIImage(data: data) else { return nil }
    if let target {
        // Pad the canvas horizontally so adjacent emoji / surrounding text
        // don't crowd the sticker. The image draws in the middle; the extra
        // transparent strips on each side are baked into the bitmap so the
        // SwiftUI Text run can stay a single glyph.
        let canvas = CGSize(width: target + hPadding * 2, height: target)
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let resized = renderer.image { _ in
            ui.draw(in: CGRect(x: hPadding, y: 0, width: target, height: target))
        }
        img = Image(uiImage: resized)
    } else {
        img = Image(uiImage: ui)
    }
    #else
    guard let ns = NSImage(data: data) else { return nil }
    if let target {
        let canvas = NSSize(width: target + hPadding * 2, height: target)
        let resized = NSImage(size: canvas)
        resized.lockFocus()
        ns.draw(in: NSRect(x: hPadding, y: 0, width: target, height: target),
                from: NSRect(origin: .zero, size: ns.size),
                operation: .copy, fraction: 1)
        resized.unlockFocus()
        img = Image(nsImage: resized)
    } else {
        img = Image(nsImage: ns)
    }
    #endif
    if let img { emojiImageCache[cacheKey] = img }
    return img
}

private var emojiImageCache: [String: Image] = [:]

#if canImport(UIKit)
import UIKit

/// Compose an NSAttributedString from a markdown body. Image runs in the
/// parsed body are skipped — callers split the document at image boundaries
/// and render those as separate `BlobImage` blocks. After laying out the
/// typed runs we run a URL auto-detector for any bare URLs the user typed as
/// plain text (markdown `[text](url)` links already carry `.link` from the
/// typed pass).
///
/// Because emoji and image attachments go through `NSTextAttachment.bounds`,
/// glyphs line up identically in the editor and in every display surface.
func attributedInlineText(body: String,
                          catalog: EmojiCatalog,
                          font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
    let m = NSMutableAttributedString()
    for run in MarkdownCodec.parse(body, catalog: catalog) {
        switch run {
        case .text(let s):
            m.append(NSAttributedString(string: s, attributes: inlineTextAttrs(font: font, style: [])))
        case .styled(let s, let style):
            m.append(NSAttributedString(string: s, attributes: inlineTextAttrs(font: font, style: style)))
        case .emoji(let id):
            if let item = catalog.item(id) {
                m.append(emojiAttachmentString(item: item, font: font))
            } else {
                m.append(NSAttributedString(string: "[\(id)]",
                                            attributes: inlineTextAttrs(font: font, style: [])))
            }
        case .image:
            // Inline preview path skips images entirely; block renderer
            // (`ContentDocumentView`) splits on them and uses BlobImage.
            break
        case .link(let text, let url):
            var attrs = inlineTextAttrs(font: font, style: [])
            if let u = URL(string: url) { attrs[.link] = u }
            m.append(NSAttributedString(string: text, attributes: attrs))
        }
    }
    autoLinkifyAttributed(m)
    return m
}

private func inlineTextAttrs(font: UIFont,
                             style: Style) -> [NSAttributedString.Key: Any] {
    var traits: UIFontDescriptor.SymbolicTraits = []
    if style.contains(.bold) { traits.insert(.traitBold) }
    if style.contains(.italic) { traits.insert(.traitItalic) }
    var f = font
    if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) {
        f = UIFont(descriptor: d, size: 0)
    }
    return [.font: f, .foregroundColor: UIColor.label]
}

private let _inlineURLDetector: NSDataDetector? =
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Add `.link` to any auto-detected URL ranges that don't already carry one.
/// We skip ranges already linked so an explicit `[text](url)` markdown link
/// keeps its declared destination even if the display text happens to be a
/// URL pattern itself.
private func autoLinkifyAttributed(_ m: NSMutableAttributedString) {
    guard let detector = _inlineURLDetector else { return }
    let s = m.string
    let full = NSRange(location: 0, length: (s as NSString).length)
    detector.enumerateMatches(in: s, options: [], range: full) { match, _, _ in
        guard let match, let url = match.url else { return }
        if m.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { return }
        m.addAttribute(.link, value: url, range: match.range)
    }
}

/// Non-editable UITextView wrapped as a SwiftUI view. Uses the same TextKit
/// pipeline as the editor's `RichTextEditor`, so any `NSTextAttachment` lines
/// up identically. Renders inline links (via `dataDetectorTypes`) and grows
/// vertically to fit content; horizontal width comes from the SwiftUI parent.
///
/// Hit-testing is link-only: non-link characters fall through to the
/// enclosing view, so a `NavigationLink` row wrapping this view stays
/// tappable on every word.
struct AttrInlineText: UIViewRepresentable {
    let attributed: NSAttributedString
    /// 0 = unlimited, otherwise truncate with `…` at the tail (matches
    /// SwiftUI's `.lineLimit(_:)` for the preview row case).
    var maxLines: Int = 0
    /// Detail-page only: called after each layout pass with the per-glyph
    /// frame (in the UITextView's own coordinates) of every emoji
    /// attachment found in `attributed`. List previews leave this nil and
    /// pay no extra layout cost.
    var onEmojiLayouts: (([InlineEmojiLayout]) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = PassthroughTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        // `isSelectable` controls both selection AND link-tap recognition.
        // Keep it on so taps on links work; `PassthroughTextView.point(...)`
        // restricts the live hit region to link glyphs only.
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = .link
        tv.adjustsFontForContentSizeCategory = true
        tv.textContainer.maximumNumberOfLines = maxLines
        tv.textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        // Same trick as RichTextEditor — let the SwiftUI parent dictate width;
        // the view should grow vertically rather than push siblings sideways.
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if !uiView.attributedText.isEqual(to: attributed) {
            uiView.attributedText = attributed
        }
        uiView.textContainer.maximumNumberOfLines = maxLines
        uiView.textContainer.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        guard let callback = onEmojiLayouts else { return }
        // Defer to the next runloop so layoutManager has the final glyph
        // rects (when called from inside updateUIView, glyph rects can be
        // stale if the attributed text just changed).
        DispatchQueue.main.async {
            let layouts = collectEmojiLayouts(in: uiView)
            if !layouts.isEmpty { callback(layouts) }
        }
    }

    /// Walk every `NSTextAttachment` in the laid-out text and emit a layout
    /// entry for those carrying an `emojiIDAttributeName`. Frames are in
    /// the text view's own coordinate space (matching the SwiftUI frame
    /// the parent reads via GeometryReader).
    private func collectEmojiLayouts(in tv: UITextView) -> [InlineEmojiLayout] {
        guard let attr = tv.attributedText, attr.length > 0 else { return [] }
        let manager = tv.layoutManager
        let container = tv.textContainer
        let inset = tv.textContainerInset
        var out: [InlineEmojiLayout] = []
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            guard value is NSTextAttachment else { return }
            guard let id = attr.attribute(emojiIDAttributeName, at: range.location,
                                          effectiveRange: nil) as? String else { return }
            let glyphRange = manager.glyphRange(forCharacterRange: range,
                                                actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += inset.left
            rect.origin.y += inset.top
            out.append(InlineEmojiLayout(id: id, frameInTextView: rect))
        }
        return out
    }

    /// Without this, UITextView's intrinsic width is the unwrapped text
    /// width — SwiftUI then lays the view out at that width and the
    /// trailing characters get clipped instead of wrapping. We honour the
    /// proposed width from the parent and ask UITextView to wrap to that.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? .infinity
        let constraint = CGSize(width: w.isFinite ? w : .greatestFiniteMagnitude,
                                height: .greatestFiniteMagnitude)
        let fit = uiView.sizeThatFits(constraint)
        return CGSize(width: w.isFinite ? w : fit.width, height: ceil(fit.height))
    }
}

/// UITextView that only claims hit-tests on link characters. Used by
/// `AttrInlineText` so a topic-list row stays tappable on text — without
/// this, UITextView eats every touch and `NavigationLink` never fires.
private final class PassthroughTextView: UITextView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard attributedText.length > 0 else { return false }
        // Find the glyph at this point and check whether it carries a link.
        let manager = layoutManager
        let container = textContainer
        let location = CGPoint(x: point.x - textContainerInset.left,
                               y: point.y - textContainerInset.top)
        let glyphIndex = manager.glyphIndex(for: location, in: container)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                             in: container)
        guard glyphRect.contains(location) else { return false }
        let charIndex = manager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < attributedText.length else { return false }
        return attributedText.attribute(.link, at: charIndex, effectiveRange: nil) != nil
    }
}
#endif

/// Renders one Lark sticker. No Unicode fallback — the catalog is image-only;
/// if an asset is missing we show a tiny "?" box so it's visually obvious.
struct EmojiGlyph: View {
    let item: EmojiItem?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let img = loadEmojiImage(item?.file) {
                img.resizable().scaledToFit()
            } else {
                missing
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var missing: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(.tertiary, lineWidth: 1)
            .overlay(
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
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
    /// Vertical drag-to-dismiss translation. Only non-zero while the image
    /// is at base zoom (scale == 1); when zoomed in, the gesture is rebound
    /// to panning the zoomed image instead.
    @State private var dismissDragOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5
    /// Vertical translation past which we let go and dismiss instead of
    /// springing back. Matches Photos / Messages' feel.
    private let dismissThreshold: CGFloat = 140

    var body: some View {
        ZStack {
            Color.black.opacity(backdropOpacity).ignoresSafeArea()

            image
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * dismissDragScale)
                .offset(x: offset.width + dismissDragOffset.width,
                        y: offset.height + dismissDragOffset.height)
                .gesture(magnification)
                .simultaneousGesture(scale > 1 ? drag : nil)
                .simultaneousGesture(scale <= 1 ? dismissDrag : nil)
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

    /// Drag-down-to-dismiss. The image follows the finger (with horizontal
    /// motion damped so it feels vertical-dominant), and the black backdrop
    /// fades as the image moves away. Releasing past `dismissThreshold`
    /// closes the viewer; otherwise it springs back.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dismissDragOffset = CGSize(width: value.translation.width * 0.4,
                                           height: value.translation.height)
            }
            .onEnded { value in
                if abs(value.translation.height) > dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        dismissDragOffset = .zero
                    }
                }
            }
    }

    /// 1.0 when idle, shrinks toward ~0.85 as the user drags away — small
    /// tactile feedback that the image is "lifting off" before dismissal.
    private var dismissDragScale: CGFloat {
        let h = abs(dismissDragOffset.height)
        return max(0.85, 1 - h / 1200)
    }

    /// Black backdrop fades down to ~0.55 by the time the user reaches the
    /// dismiss threshold so they can preview the content underneath.
    private var backdropOpacity: Double {
        let h = abs(dismissDragOffset.height)
        return Double(max(0.55, 1 - h / 400))
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

/// Inline renderer for a ContentDocument. Splits the segment list into
/// alternating text-runs (rendered as one `AttrInlineText` per run, via the
/// shared NSAttributedString builder) and image blocks (rendered as
/// `BlobImage`). Because text+emoji go through the same TextKit attachment
/// machinery as the editor, emoji alignment is identical here, in the topic
/// list preview, in topic detail, and inside the composer — no per-callsite
/// offset tuning.
struct ContentDocumentView: View {
    let doc: ContentDocument
    /// When false, images render as static previews (taps fall through to an
    /// enclosing row/link instead of opening the zoom viewer).
    var imagesZoomable: Bool = true
    /// Detail-page only: when set, inline text blocks route through
    /// `InlineTextWithFlyIn` so emoji attachments fly in from the left the
    /// first time they're seen this launch. List previews leave this nil.
    var emojiFlyInSpace: String? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .text(let attr):
            #if canImport(UIKit)
            if let space = emojiFlyInSpace {
                InlineTextWithFlyIn(attributed: attr, space: space)
            } else {
                AttrInlineText(attributed: attr)
            }
            #else
            Text(attr.string).font(.body)
            #endif
        case .image(let blob):
            BlobImage(blobID: blob, zoomEnabled: imagesZoomable)
        }
    }

    private enum Block {
        case text(NSAttributedString)
        case image(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var bucket: [Run] = []
        // Track whether the next text-bearing run we accumulate should have
        // one leading `\n` stripped — set right after we flush an image so
        // the editor's `\n[image]\n` wrapping doesn't survive into the text
        // block below the rendered image as a phantom empty line.
        var stripNextLeadingNL = false

        // Parse once so we can both (a) walk the runs to build blocks AND
        // (b) decide up-front whether to render the whole doc at the big
        // "sticker reply" size. A run is treated as sticker-only when
        // there's at least one emoji and all text is whitespace.
        let allRuns = MarkdownCodec.parse(doc.body, catalog: model.emoji)
        #if canImport(UIKit)
        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let font: UIFont = isEmojiOnly(allRuns)
            ? baseFont.withSize(baseFont.pointSize * stickerMagnification)
            : baseFont
        #endif

        func flush() {
            guard !bucket.isEmpty else { return }
            let body = MarkdownCodec.serialize(bucket)
            #if canImport(UIKit)
            let attr = attributedInlineText(body: body, catalog: model.emoji, font: font)
            #else
            let plain = bucket.reduce(into: "") { acc, run in
                switch run {
                case .text(let s), .styled(let s, _): acc += s
                case .emoji(let id):
                    acc += (model.emoji.item(id)?.placeholder ?? "[\(id)]")
                case .image: break
                case .link(let text, _): acc += text
                }
            }
            let attr = NSAttributedString(string: plain)
            #endif
            if attr.length > 0 { out.append(.text(attr)) }
            bucket = []
        }

        for run in allRuns {
            if case .image(let blob) = run {
                stripTrailingNL(in: &bucket)
                flush()
                out.append(.image(blob))
                stripNextLeadingNL = true
            } else {
                var next = run
                if stripNextLeadingNL {
                    next = trimmingLeadingNL(next)
                    stripNextLeadingNL = false
                }
                if !isEmptyText(next) { bucket.append(next) }
            }
        }
        flush()
        return out
    }

    /// Body-text → big-sticker scale factor when a reply/topic is just an
    /// emoji (the iMessage-style "jumbo emoji" treatment).
    private var stickerMagnification: CGFloat { 1.8 }

    /// True when the run sequence has at least one emoji and no
    /// non-whitespace text/styled run — images and links disqualify too,
    /// since those need normal layout sizing.
    private func isEmojiOnly(_ runs: [Run]) -> Bool {
        var hasEmoji = false
        for run in runs {
            switch run {
            case .emoji: hasEmoji = true
            case .text(let s), .styled(let s, _):
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return false
                }
            case .image, .link:
                return false
            }
        }
        return hasEmoji
    }

    private func stripTrailingNL(in bucket: inout [Run]) {
        guard let last = bucket.last else { return }
        switch last {
        case .text(let s) where s.hasSuffix("\n"):
            let t = String(s.dropLast())
            if t.isEmpty { bucket.removeLast() } else { bucket[bucket.count - 1] = .text(t) }
        case .styled(let s, let style) where s.hasSuffix("\n"):
            let t = String(s.dropLast())
            if t.isEmpty { bucket.removeLast() } else { bucket[bucket.count - 1] = .styled(t, style) }
        default:
            break
        }
    }

    private func trimmingLeadingNL(_ run: Run) -> Run {
        switch run {
        case .text(let s) where s.hasPrefix("\n"):
            return .text(String(s.dropFirst()))
        case .styled(let s, let style) where s.hasPrefix("\n"):
            return .styled(String(s.dropFirst()), style)
        default:
            return run
        }
    }

    private func isEmptyText(_ run: Run) -> Bool {
        switch run {
        case .text(let s): return s.isEmpty
        case .styled(let s, _): return s.isEmpty
        default: return false
        }
    }
}

/// Left-aligned wrapping row: lays children out left→right and breaks to a
/// new line when the proposed width runs out. Used so reaction chips show
/// in full (wrapped) instead of overflowing a single clipped HStack.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                        subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                     proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
