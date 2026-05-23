import SwiftUI
import FlarkKit
#if canImport(UIKit)
import UIKit

/// A UITextView-backed editor. The whole text stays editable; bold/italic are
/// stored as font traits on attribute runs (not as committed segments), so
/// toggling styles never freezes prior input.
struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @Binding var selection: NSRange
    @Binding var typingStyle: ContentDocument.TextStyle?
    @FocusState.Binding var focused: Bool
    /// When true, the editor takes first responder as soon as the view is
    /// inserted into a window. We can't rely on toggling `focused` from the
    /// SwiftUI side — no native view in this composer carries `.focused()`,
    /// so the SwiftUI focus engine has nothing to drive, and setting the
    /// binding doesn't reliably call `becomeFirstResponder` through a sheet
    /// transition. This flag short-circuits the dance.
    var autoFocusOnAppear: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let tv = AutoFocusTextView()
        tv.delegate = context.coordinator
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
        let target = clamp(selection, to: attributedText.length)
        if !uiView.attributedText.isEqual(to: attributedText) {
            uiView.attributedText = attributedText
            uiView.selectedRange = target
        } else if !NSEqualRanges(uiView.selectedRange, target) {
            uiView.selectedRange = target
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
        init(_ p: RichTextEditor) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            parent.attributedText = tv.attributedText
            parent.selection = tv.selectedRange
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.selection = tv.selectedRange
            // Sync toolbar highlight: for a collapsed caret, mirror the run
            // the cursor is sitting in; for a real selection, only light up
            // when *every* run in the range carries the same style (so a
            // mixed selection reads as "no style", not a misleading hit).
            guard let attr = tv.attributedText, attr.length > 0 else { return }
            let sel = tv.selectedRange
            let newStyle: ContentDocument.TextStyle?
            if sel.length == 0 {
                let probe = sel.location > 0 ? sel.location - 1 : sel.location
                guard probe < attr.length else { return }
                newStyle = RichTextAttributes.style(from: attr.attribute(.font, at: probe, effectiveRange: nil) as? UIFont)
            } else {
                let range = NSRange(location: sel.location,
                                    length: min(sel.length, attr.length - sel.location))
                guard range.length > 0 else { return }
                var common: ContentDocument.TextStyle? = nil
                var first = true
                var consistent = true
                attr.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                    let s = RichTextAttributes.style(from: value as? UIFont)
                    if first { common = s; first = false }
                    else if s != common { consistent = false; stop.pointee = true }
                }
                newStyle = consistent ? common : nil
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
    static func typing(for style: ContentDocument.TextStyle?) -> [NSAttributedString.Key: Any] {
        let base = UIFont.preferredFont(forTextStyle: .body)
        let font: UIFont
        switch style {
        case .bold:
            let d = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
            font = UIFont(descriptor: d, size: 0)
        case .italic:
            let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
            font = UIFont(descriptor: d, size: 0)
        case nil:
            font = base
        }
        return [.font: font, .foregroundColor: UIColor.label]
    }

    static func style(from font: UIFont?) -> ContentDocument.TextStyle? {
        guard let font else { return nil }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.traitBold) { return .bold }
        if traits.contains(.traitItalic) { return .italic }
        return nil
    }

    /// Toggles a trait on a range. If every run in the range already has the
    /// trait, removes it; otherwise applies it uniformly. Bold and italic are
    /// mutually exclusive (the underlying `ContentDocument.TextStyle` can only
    /// hold one), so applying one clears the other to keep the live editor
    /// state and the saved segments in sync.
    static func toggle(_ style: ContentDocument.TextStyle, on attr: NSAttributedString, range: NSRange) -> NSAttributedString {
        guard range.length > 0, range.location + range.length <= attr.length else { return attr }
        let trait: UIFontDescriptor.SymbolicTraits = (style == .bold ? .traitBold : .traitItalic)
        let other: UIFontDescriptor.SymbolicTraits = (style == .bold ? .traitItalic : .traitBold)
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
            if allHave {
                traits.remove(trait)
            } else {
                traits.insert(trait)
                traits.remove(other)
            }
            let d = f.fontDescriptor.withSymbolicTraits(traits) ?? f.fontDescriptor
            m.addAttribute(.font, value: UIFont(descriptor: d, size: 0), range: sub)
        }
        return m
    }
}

/// Custom attribute that pins an emoji `id` to a text attachment so we can
/// round-trip the editor's NSAttributedString ↔ ContentDocument segments.
let emojiIDAttributeName = NSAttributedString.Key("emojiID")

/// Builds an attributed-string fragment containing one inline Lark sticker —
/// a single `NSTextAttachment` carrying the emoji image, sized to the
/// caller's font line height (so it scales with body / footnote / etc.) and
/// tagged with the catalog id.
func emojiAttachmentString(item: EmojiItem,
                           font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
    let attachment = NSTextAttachment()
    let lineHeight = font.lineHeight
    // Horizontal padding baked into the canvas so the attachment width is
    // `lineHeight + 2 × hPadding` and adjacent characters / emoji don't
    // crowd the sticker. Matches the inline-render value in SharedViews.
    let hPadding: CGFloat = 2
    if let url = Bundle.main.url(forResource: item.file, withExtension: nil, subdirectory: "Emoji"),
       let data = try? Data(contentsOf: url),
       let img = UIImage(data: data) {
        let canvas = CGSize(width: lineHeight + hPadding * 2, height: lineHeight)
        let format = UIGraphicsImageRendererFormat.default()
        let resized = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            img.draw(in: CGRect(x: hPadding, y: 0, width: lineHeight, height: lineHeight))
        }
        attachment.image = resized
        // Drop the image so it sits on the text's optical centre rather than
        // floating above the baseline. ~20% below baseline matches the inline
        // ContentDocumentView render.
        attachment.bounds = CGRect(x: 0, y: -lineHeight * 0.2,
                                   width: canvas.width, height: canvas.height)
    }
    let m = NSMutableAttributedString(attributedString:
        NSAttributedString(attachment: attachment))
    m.addAttribute(emojiIDAttributeName, value: item.id,
                   range: NSRange(location: 0, length: m.length))
    return m
}

/// Image-attachment markers. `imageBlobAttributeName` tags the attachment
/// glyph with the blob id; `imageW/H` carry the original pixel dimensions so
/// `segmentsFromAttributed` can round-trip back to `.image(blobID:w:h:)`.
let imageBlobAttributeName = NSAttributedString.Key("imageBlob")
let imageWidthAttributeName = NSAttributedString.Key("imageW")
let imageHeightAttributeName = NSAttributedString.Key("imageH")

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
/// attachment, carrying the blob/dimension markers needed for round-tripping.
/// Callers (e.g. `ComposerView.insertImage`) are responsible for any
/// surrounding newlines so the attachment lands on its own line. `data` may
/// be nil (e.g. blob still downloading) — the attachment renders an empty
/// box of the right size and lets the user keep editing; the underlying
/// segment is still preserved.
/// Vertical breathing room above and below an inline image. Matches the
/// 8pt `VStack` spacing `ContentDocumentView` uses between text and
/// `BlobImage` in the read view, so the composer's image gutter looks
/// identical to the rendered card.
let inlineImageParagraphSpacing: CGFloat = 8

func imageAttachmentString(blobID: String, w: Int, h: Int, data: Data?) -> NSAttributedString {
    let img: UIImage? = data.flatMap(UIImage.init(data:))
    let attachment = InlineImageAttachment(image: img, w: w, h: h)
    let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
    let r = NSRange(location: 0, length: m.length)
    m.addAttribute(imageBlobAttributeName, value: blobID, range: r)
    m.addAttribute(imageWidthAttributeName, value: w, range: r)
    m.addAttribute(imageHeightAttributeName, value: h, range: r)
    // The image is its own paragraph; let TextKit's paragraph-spacing
    // machinery (rather than empty body-font lines around it) own the
    // vertical gutters. Symmetric above & below by construction.
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = inlineImageParagraphSpacing
    style.paragraphSpacing = inlineImageParagraphSpacing
    m.addAttribute(.paragraphStyle, value: style, range: r)
    return m
}

/// Walks attribute runs and produces ContentDocument segments. Plain text
/// runs merge by style; runs carrying the `emojiID` or image-blob markers
/// emit `.emoji(id:)` / `.image(...)` segments inline.
func segmentsFromAttributed(_ s: NSAttributedString) -> [ContentDocument.Segment] {
    guard s.length > 0 else { return [] }
    var segments: [ContentDocument.Segment] = []
    var textBuf = ""
    var textStyle: ContentDocument.TextStyle? = nil

    func flushText() {
        guard !textBuf.isEmpty else { return }
        if let st = textStyle { segments.append(.styledText(text: textBuf, style: st)) }
        else { segments.append(.text(textBuf)) }
        textBuf = ""
    }

    let full = NSRange(location: 0, length: s.length)
    s.enumerateAttributes(in: full, options: []) { attrs, range, _ in
        if let blob = attrs[imageBlobAttributeName] as? String,
           let w = attrs[imageWidthAttributeName] as? Int,
           let h = attrs[imageHeightAttributeName] as? Int {
            flushText()
            segments.append(.image(blobID: blob, width: w, height: h))
            return
        }
        if let id = attrs[emojiIDAttributeName] as? String {
            flushText()
            segments.append(.emoji(id: id))
            return
        }
        let sub = (s.string as NSString).substring(with: range)
        let style = RichTextAttributes.style(from: attrs[.font] as? UIFont)
        if !textBuf.isEmpty && textStyle != style { flushText() }
        textBuf += sub
        textStyle = style
    }
    flushText()
    return segments
}

/// Rebuilds an NSAttributedString from segments so existing topics / replies
/// load into the editor with styling preserved. Emojis are reinserted as
/// inline attachments; images are reinserted as inline image attachments
/// using `images[blobID]` for the raw bytes (nil values render as empty
/// boxes — the segment is still round-tripped on save).
func attributedString(fromSegments segs: [ContentDocument.Segment],
                      catalog: EmojiCatalog,
                      images: [String: Data] = [:]) -> NSAttributedString {
    let m = NSMutableAttributedString()
    for seg in segs {
        switch seg {
        case .text(let s):
            m.append(NSAttributedString(string: s, attributes: RichTextAttributes.typing(for: nil)))
        case .styledText(let s, let style):
            m.append(NSAttributedString(string: s, attributes: RichTextAttributes.typing(for: style)))
        case .emoji(let id):
            if let item = catalog.item(id) {
                m.append(emojiAttachmentString(item: item))
            }
        case .image(let blob, let w, let h):
            m.append(imageAttachmentString(blobID: blob, w: w, h: h, data: images[blob]))
        }
    }
    return m
}
#endif
