import SwiftUI
import FlarkKit
#if canImport(UIKit)
import UIKit

/// A UITextView-backed editor. The whole text stays editable; bold/italic are
/// stored as font traits on attribute runs (not as committed runs), so
/// toggling styles never freezes prior input. Bold and italic are independent —
/// the same range can carry both at once and round-trips through markdown as
/// `***bold-italic***`.
struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selection: NSRange
    @Binding var typingStyle: Style
    @FocusState.Binding var focused: Bool
    /// When true, the editor takes first responder as soon as the view is
    /// inserted into a window. We can't rely on toggling `focused` from the
    /// SwiftUI side — no native view in this composer carries `.focused()`,
    /// so the SwiftUI focus engine has nothing to drive, and setting the
    /// binding doesn't reliably call `becomeFirstResponder` through a sheet
    /// transition. This flag short-circuits the dance.
    var autoFocusOnAppear: Bool = false
    /// Optional escape hatch for callers that need the underlying
    /// `UITextView` — e.g. the picker → editor emoji fly-in needs the
    /// caret rect in window coordinates. Held weak inside the handle so
    /// the view's lifecycle is unaffected.
    var handle: EditorHandle? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = AutoFocusTextView()
        tv.delegate = context.coordinator
        handle?.textView = tv
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.attributedText = attributedText
        tv.typingAttributes = RichTextAttributes.typing(for: typingStyle)
        tv.shouldAutoFocusOnMoveToWindow = autoFocusOnAppear
        // Without these, UITextView's intrinsic width grows with the longest
        // line and the editor pushes its SwiftUI parent wider instead of
        // wrapping. Low horizontal hugging lets the parent's `maxWidth:
        // .infinity` win; high compression resistance keeps text from being
        // clipped if the layout still tries to shrink us.
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coord = context.coordinator
        let target = clamp(selection, to: attributedText.length)
        // Compare against what we last pushed, NOT against `uiView.attributedText`:
        // UITextView canonicalizes attributes on assignment (especially paragraph
        // style around NSTextAttachment runs), so reading back yields a string
        // that's no longer byte-equal to what we set. Comparing canonical-vs-
        // pristine would mismatch every render and re-assign attributedText every
        // frame → textViewDidChangeSelection → parent.selection mutation →
        // re-render → loop, hanging the app on edit of image-bearing content.
        if !coord.lastPushedAttributed.isEqual(to: attributedText) {
            uiView.attributedText = attributedText
            coord.lastPushedAttributed = attributedText
            uiView.selectedRange = target
            coord.lastPushedSelection = target
        } else if !NSEqualRanges(coord.lastPushedSelection, target) {
            uiView.selectedRange = target
            coord.lastPushedSelection = target
        }
        uiView.typingAttributes = RichTextAttributes.typing(for: typingStyle)
        if focused, !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        }
    }

    /// Match SwiftUI's proposed width so long text wraps instead of being
    /// clipped at the line's right edge. See the matching override in
    /// `AttrInlineText` for the same reasoning.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? .infinity
        let constraint = CGSize(width: w.isFinite ? w : .greatestFiniteMagnitude,
                                height: .greatestFiniteMagnitude)
        let fit = uiView.sizeThatFits(constraint)
        return CGSize(width: w.isFinite ? w : fit.width, height: ceil(fit.height))
    }

    private func clamp(_ r: NSRange, to length: Int) -> NSRange {
        let loc = min(max(r.location, 0), length)
        let len = min(r.length, length - loc)
        return NSRange(location: loc, length: max(0, len))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        /// Snapshot of the attributed text / selection that `updateUIView` last
        /// pushed into the UITextView. Used so the next render compares against
        /// the same uncanonicalized form we sent down rather than UITextView's
        /// post-TextKit reading, avoiding a re-assign-every-frame loop.
        var lastPushedAttributed: NSAttributedString = NSAttributedString()
        var lastPushedSelection: NSRange = NSRange(location: 0, length: 0)
        init(_ p: RichTextEditor) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            let attr = tv.attributedText ?? NSAttributedString()
            parent.attributedText = attr
            parent.selection = tv.selectedRange
            // The user-edited text *is* the canonical form; record it so the
            // next `updateUIView` doesn't echo it back to the text view.
            lastPushedAttributed = attr
            lastPushedSelection = tv.selectedRange
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.selection = tv.selectedRange
            lastPushedSelection = tv.selectedRange
            // Sync toolbar highlight: for a collapsed caret, mirror the run
            // the cursor is sitting in; for a real selection, only light up
            // when *every* run in the range carries the same style (so a
            // mixed selection reads as "no style", not a misleading hit).
            guard let attr = tv.attributedText, attr.length > 0 else { return }
            let sel = tv.selectedRange
            let newStyle: Style
            if sel.length == 0 {
                let probe = sel.location > 0 ? sel.location - 1 : sel.location
                guard probe < attr.length else { return }
                newStyle = RichTextAttributes.style(from: attr.attribute(.font, at: probe, effectiveRange: nil) as? UIFont)
            } else {
                let range = NSRange(location: sel.location,
                                    length: min(sel.length, attr.length - sel.location))
                guard range.length > 0 else { return }
                var common: Style = []
                var first = true
                var consistent = true
                attr.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                    let s = RichTextAttributes.style(from: value as? UIFont)
                    if first { common = s; first = false }
                    else if s != common { consistent = false; stop.pointee = true }
                }
                newStyle = consistent ? common : []
            }
            if parent.typingStyle != newStyle { parent.typingStyle = newStyle }
        }

        func textViewDidBeginEditing(_ tv: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.focused = false }
    }
}

/// UITextView subclass that grabs first responder the moment it lands in a
/// window — happens *after* the sheet's presentation animation, so the
/// keyboard reliably comes up on first open. We do this in
/// `didMoveToWindow` rather than from SwiftUI's `.onAppear` because the
/// view-tree callback fires before the underlying UITextView is actually
/// attached to a window, and `becomeFirstResponder` then silently no-ops.
private final class AutoFocusTextView: UITextView {
    var shouldAutoFocusOnMoveToWindow = false
    private var didAutoFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard shouldAutoFocusOnMoveToWindow, !didAutoFocus, window != nil else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }
}

enum RichTextAttributes {
    static func typing(for style: Style) -> [NSAttributedString.Key: Any] {
        let base = UIFont.preferredFont(forTextStyle: .body)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        let font: UIFont
        if traits.isEmpty {
            font = base
        } else if let d = base.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: d, size: 0)
        } else {
            font = base
        }
        return [.font: font, .foregroundColor: UIColor.label]
    }

    static func style(from font: UIFont?) -> Style {
        guard let font else { return [] }
        var s: Style = []
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.traitBold) { s.insert(.bold) }
        if traits.contains(.traitItalic) { s.insert(.italic) }
        return s
    }

    /// Toggle a single style bit (`.bold` or `.italic`) on the range. Bold
    /// and italic are independent — combining the two yields the bold-italic
    /// font trait pair which serializes as `***…***` in markdown.
    static func toggle(_ bit: Style, on attr: NSAttributedString, range: NSRange) -> NSAttributedString {
        guard range.length > 0, range.location + range.length <= attr.length else { return attr }
        let trait: UIFontDescriptor.SymbolicTraits = bit.contains(.bold) ? .traitBold : .traitItalic
        let m = NSMutableAttributedString(attributedString: attr)
        var allHave = true
        m.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            let f = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            if !f.fontDescriptor.symbolicTraits.contains(trait) {
                allHave = false; stop.pointee = true
            }
        }
        m.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let f = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            var traits = f.fontDescriptor.symbolicTraits
            if allHave { traits.remove(trait) }
            else { traits.insert(trait) }
            let d = f.fontDescriptor.withSymbolicTraits(traits) ?? f.fontDescriptor
            m.addAttribute(.font, value: UIFont(descriptor: d, size: 0), range: sub)
        }
        return m
    }
}

/// Custom attribute that pins an emoji `id` to a text attachment so we can
/// round-trip the editor's NSAttributedString ↔ markdown.
let emojiIDAttributeName = NSAttributedString.Key("emojiID")

/// Builds an attributed-string fragment containing one inline Lark sticker —
/// a single `NSTextAttachment` carrying the emoji image, sized to the
/// caller's font line height (so it scales with body / footnote / etc.) and
/// tagged with the catalog id.
// Inline Lark emoji are drawn 1.44x the font's line height — same-size
// glyphs read as too small next to body text; this bump matches the
// "emoji slightly larger than text" feel of mainstream chat apps.
private let inlineEmojiScale: CGFloat = 1.44

func emojiAttachmentString(item: EmojiItem,
                           font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
    let attachment = NSTextAttachment()
    let size = font.lineHeight * inlineEmojiScale
    // Horizontal padding baked into the canvas so adjacent characters /
    // emoji don't crowd the sticker. Matches the inline-render value in
    // SharedViews. Not scaled with the emoji — it's a text-side gap.
    let hPadding: CGFloat = 2
    let resolved = EmojiPackResolver.resolvedFile(item.file)
    if let url = Bundle.main.url(forResource: resolved, withExtension: nil, subdirectory: "Emoji"),
       let data = try? Data(contentsOf: url),
       let img = UIImage(data: data) {
        let canvas = CGSize(width: size + hPadding * 2, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        let resized = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            img.draw(in: CGRect(x: hPadding, y: 0, width: size, height: size))
        }
        attachment.image = resized
        // Drop the image so it sits on the text's optical centre rather than
        // floating above the baseline. ~20% below baseline matches the inline
        // ContentDocumentView render.
        attachment.bounds = CGRect(x: 0, y: -size * 0.2,
                                   width: canvas.width, height: canvas.height)
    }
    let m = NSMutableAttributedString(attributedString:
        NSAttributedString(attachment: attachment))
    m.addAttribute(emojiIDAttributeName, value: item.id,
                   range: NSRange(location: 0, length: m.length))
    return m
}

/// Image-attachment marker. Tags the attachment glyph with the blob id so
/// `markdownFromAttributed` can round-trip back to `![](blob://<id>)`.
/// Dimensions live only on the in-memory attachment (decoded from blob data
/// at load time) — the persisted markdown has no dims.
let imageBlobAttributeName = NSAttributedString.Key("imageBlob")

/// NSTextAttachment that sizes itself to the editor's full text-container
/// width and renders the image with rounded corners + aspect-fill cropping —
/// so inline images in the composer match `BlobImage`'s look in the read
/// view. Subclassing (vs baking at insertion time) lets the layout track
/// container-width changes (rotation, dynamic-type re-layout).
final class InlineImageAttachment: NSTextAttachment {
    let originalW: Int
    let originalH: Int
    static let maxDisplayHeight: CGFloat = 200
    static let cornerRadius: CGFloat = 14

    init(image: UIImage?, w: Int, h: Int) {
        self.originalW = max(1, w)
        self.originalH = max(1, h)
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    required init?(coder: NSCoder) { fatalError("InlineImageAttachment is code-only") }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect,
                                   glyphPosition: CGPoint,
                                   characterIndex: Int) -> CGRect {
        // The image sits on its own paragraph (we wrap with `\n`), so
        // `proposedLineFragment.width` *is* the full available line. Combine
        // both sources — `textContainer.size.width` can be 0 before the view
        // is first laid out; `proposedLineFragment.width` is also 0 in some
        // intrinsic-sizing calls — so we take the max and fall back only as
        // a last resort.
        let containerW = textContainer?.size.width ?? 0
        let proposedW = proposedLineFragment.width
        let w = max(containerW, proposedW, 0)
        let resolved = w > 0 ? w : 320
        let aspect = CGFloat(originalH) / CGFloat(originalW)
        let h = min(resolved * aspect, Self.maxDisplayHeight)
        return CGRect(x: 0, y: 0, width: resolved, height: h)
    }

    /// Render the source bitmap into the actual line-fragment-sized bounds
    /// with aspect-fill cropping and a rounded-rect clip — matches
    /// `BlobImage` (`scaledToFill` + `RoundedRectangle(cornerRadius: 14)`).
    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> UIImage? {
        guard let raw = image,
              imageBounds.width > 0, imageBounds.height > 0 else { return image }
        let size = imageBounds.size
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: Self.cornerRadius).addClip()
            let srcAspect = raw.size.width / max(raw.size.height, 1)
            let dstAspect = size.width / max(size.height, 1)
            let drawRect: CGRect
            if srcAspect > dstAspect {
                let scaledW = size.height * srcAspect
                drawRect = CGRect(x: (size.width - scaledW) / 2, y: 0,
                                  width: scaledW, height: size.height)
            } else {
                let scaledH = size.width / max(srcAspect, 0.0001)
                drawRect = CGRect(x: 0, y: (size.height - scaledH) / 2,
                                  width: size.width, height: scaledH)
            }
            raw.draw(in: drawRect)
        }
    }
}

/// Builds an attributed-string fragment containing just one inline image
/// attachment, carrying the blob marker needed for round-tripping. Callers
/// (e.g. `ComposerView.insertImage`) are responsible for any surrounding
/// newlines so the attachment lands on its own line. `data` may be nil
/// (e.g. blob still downloading) — the attachment renders an empty box of
/// the right size and lets the user keep editing; the underlying segment is
/// still preserved.
///
/// `w` and `h` are intrinsic pixel dimensions used by the attachment for
/// layout only — they don't persist into the saved markdown (the renderer
/// decodes them from blob bytes on next open).
let inlineImageParagraphSpacing: CGFloat = 8

func imageAttachmentString(blobID: String, w: Int, h: Int, data: Data?) -> NSAttributedString {
    let img: UIImage? = data.flatMap(UIImage.init(data:))
    let attachment = InlineImageAttachment(image: img, w: w, h: h)
    let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
    let r = NSRange(location: 0, length: m.length)
    m.addAttribute(imageBlobAttributeName, value: blobID, range: r)
    // The image is its own paragraph; let TextKit's paragraph-spacing
    // machinery (rather than empty body-font lines around it) own the
    // vertical gutters. Symmetric above & below by construction.
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = inlineImageParagraphSpacing
    style.paragraphSpacing = inlineImageParagraphSpacing
    m.addAttribute(.paragraphStyle, value: style, range: r)
    return m
}

/// Serialize the live editor's NSAttributedString into a markdown body that
/// `MarkdownCodec.parse` can read back. Walks attribute runs, hoists out
/// image / emoji attachments by their marker attributes, and collects
/// contiguous `.link` ranges into single link runs (any internal styling on
/// a link's display text is flattened, since `Run.link` carries a plain
/// string).
func markdownFromAttributed(_ s: NSAttributedString) -> String {
    guard s.length > 0 else { return "" }
    var runs: [Run] = []

    // First pass: collect link ranges in document order. enumerateAttribute
    // returns non-overlapping ranges already.
    var linkRanges: [(NSRange, URL)] = []
    s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length),
                         options: []) { value, range, _ in
        if let url = value as? URL { linkRanges.append((range, url)) }
    }

    func emitNonLink(_ range: NSRange) {
        guard range.length > 0 else { return }
        var buf = ""
        var bufStyle: Style = []

        func flushBuf() {
            guard !buf.isEmpty else { return }
            if bufStyle.isEmpty { runs.append(.text(buf)) }
            else { runs.append(.styled(buf, bufStyle)) }
            buf = ""
        }

        s.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
            if let blob = attrs[imageBlobAttributeName] as? String {
                flushBuf()
                runs.append(.image(blobID: blob))
                return
            }
            if let id = attrs[emojiIDAttributeName] as? String {
                flushBuf()
                runs.append(.emoji(id: id))
                return
            }
            let style = RichTextAttributes.style(from: attrs[.font] as? UIFont)
            let text = (s.string as NSString).substring(with: sub)
            if bufStyle != style { flushBuf(); bufStyle = style }
            buf += text
        }
        flushBuf()
    }

    var cursor = 0
    for (range, url) in linkRanges {
        emitNonLink(NSRange(location: cursor, length: range.location - cursor))
        let text = (s.string as NSString).substring(with: range)
        runs.append(.link(text: text, url: url.absoluteString))
        cursor = range.location + range.length
    }
    emitNonLink(NSRange(location: cursor, length: s.length - cursor))

    return MarkdownCodec.serialize(runs)
}

/// Hydrate a markdown body into the editor's NSAttributedString. Emojis are
/// reinserted as inline attachments; images are reinserted as inline image
/// attachments using `images[blobID]` for the raw bytes (+ dimensions). A
/// missing entry yields a 1×1 box — the markdown still round-trips because
/// the blob marker rides on the attachment.
func attributedString(fromMarkdown body: String,
                      catalog: EmojiCatalog,
                      images: [String: (data: Data, w: Int, h: Int)] = [:]) -> NSAttributedString {
    let runs = MarkdownCodec.parse(body, catalog: catalog)
    let m = NSMutableAttributedString()
    let nlAttrs = RichTextAttributes.typing(for: [])

    // Mirror `ComposerView.insertImage` so loaded images live on their own
    // paragraph. Without surrounding `\n`s the image attachment's paragraph
    // style (paragraphSpacingBefore/After) collides with the text run's
    // paragraph style inside a single paragraph — TextKit then crashes when
    // the caret moves across the boundary (e.g. tapping text before an image).
    func endsWithNewline() -> Bool {
        guard m.length > 0 else { return false }
        return (m.string as NSString).substring(with: NSRange(location: m.length - 1, length: 1)) == "\n"
    }
    var pendingTrailingNL = false
    func consumePendingTrailing(nextStartsWithNewline: Bool) {
        guard pendingTrailingNL else { return }
        pendingTrailingNL = false
        if !nextStartsWithNewline {
            m.append(NSAttributedString(string: "\n", attributes: nlAttrs))
        }
    }

    for run in runs {
        switch run {
        case .text(let s):
            consumePendingTrailing(nextStartsWithNewline: s.first == "\n")
            m.append(NSAttributedString(string: s, attributes: RichTextAttributes.typing(for: [])))
        case .styled(let s, let style):
            consumePendingTrailing(nextStartsWithNewline: s.first == "\n")
            m.append(NSAttributedString(string: s, attributes: RichTextAttributes.typing(for: style)))
        case .emoji(let id):
            consumePendingTrailing(nextStartsWithNewline: false)
            if let item = catalog.item(id) {
                m.append(emojiAttachmentString(item: item))
            }
        case .image(let blob):
            consumePendingTrailing(nextStartsWithNewline: false)
            if m.length > 0, !endsWithNewline() {
                m.append(NSAttributedString(string: "\n", attributes: nlAttrs))
            }
            let info = images[blob]
            m.append(imageAttachmentString(blobID: blob,
                                           w: info?.w ?? 1,
                                           h: info?.h ?? 1,
                                           data: info?.data))
            pendingTrailingNL = true
        case .link(let text, let url):
            consumePendingTrailing(nextStartsWithNewline: text.first == "\n")
            var attrs = RichTextAttributes.typing(for: [])
            if let u = URL(string: url) { attrs[.link] = u }
            m.append(NSAttributedString(string: text, attributes: attrs))
        }
    }
    consumePendingTrailing(nextStartsWithNewline: false)
    return m
}
#endif
