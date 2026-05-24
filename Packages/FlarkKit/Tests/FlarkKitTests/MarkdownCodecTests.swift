import XCTest
@testable import FlarkKit

final class MarkdownCodecTests: XCTestCase {
    private let catalog = EmojiCatalog(items: [
        EmojiItem(id: "lark_smile", file: "smile.png", nameZh: "笑容满面", nameEn: "smile", aliases: ["笑"]),
        EmojiItem(id: "lark_lol", file: "lol.png", nameZh: "笑哭", nameEn: "LOL", aliases: []),
    ])

    // MARK: - Round trip

    private func roundTrip(_ runs: [Run], file: StaticString = #file, line: UInt = #line) {
        let body = MarkdownCodec.serialize(runs)
        let back = MarkdownCodec.parse(body, catalog: catalog)
        XCTAssertEqual(back, runs, "round-trip differs; body=\"\(body)\"", file: file, line: line)
    }

    func testPlainTextRoundTrip() {
        roundTrip([.text("hello world")])
        roundTrip([.text("含中文 + emoji unicode 🎉 也行")])
        roundTrip([.text("line1\nline2\n\nline4")])
    }

    func testEscapingRoundTrip() {
        // User typed literal markdown special chars — round-trip must
        // preserve them as plain text, never re-parse as emphasis/links.
        roundTrip([.text("a*b*c")])
        roundTrip([.text("**not bold**")])
        roundTrip([.text("price [50]")])
        roundTrip([.text("a\\b")])
        roundTrip([.text("[fake link](nope)")])
    }

    func testEmphasis() {
        roundTrip([.styled("bold", .bold)])
        roundTrip([.styled("italic", .italic)])
        roundTrip([.styled("both", [.bold, .italic])])
        roundTrip([.text("see "), .styled("this", .bold), .text(" please")])
    }

    func testEmoji() {
        // Storage form uses the canonical id.
        roundTrip([.emoji(id: "lark_lol")])
        roundTrip([.text("hahaha "), .emoji(id: "lark_smile"), .text(" yo")])
    }

    func testEmojiAliasResolution() {
        // Lark exports use `[笑哭]` (zh name); parser resolves to canonical id.
        let runs = MarkdownCodec.parse("hi [笑哭] there", catalog: catalog)
        XCTAssertEqual(runs, [.text("hi "), .emoji(id: "lark_lol"), .text(" there")])
    }

    func testUnknownEmojiKeptAsText() {
        let runs = MarkdownCodec.parse("[not-an-emoji]", catalog: catalog)
        XCTAssertEqual(runs, [.text("[not-an-emoji]")])
    }

    func testImage() {
        roundTrip([.image(blobID: "abc123")])
        roundTrip([
            .text("before\n"),
            .image(blobID: "deadbeef"),
            .text("\nafter"),
        ])
    }

    func testLink() {
        roundTrip([.link(text: "youtube", url: "https://youtube.com/watch?v=abc")])
        roundTrip([
            .text("see "),
            .link(text: "this video", url: "https://x.com/v/1"),
            .text(" for context"),
        ])
    }

    func testLinkWithEscapedParensInURL() {
        // URLs containing `)` need an escape on serialize; parser unescapes.
        let runs: [Run] = [.link(text: "wiki", url: "https://en.wikipedia.org/wiki/Foo_(bar)")]
        let body = MarkdownCodec.serialize(runs)
        XCTAssertTrue(body.contains(#"\)"#))
        XCTAssertEqual(MarkdownCodec.parse(body, catalog: catalog), runs)
    }

    // MARK: - Parse-only edge cases

    func testUnclosedEmphasisStaysLiteral() {
        XCTAssertEqual(MarkdownCodec.parse("*hello", catalog: catalog), [.text("*hello")])
        XCTAssertEqual(MarkdownCodec.parse("**hello", catalog: catalog), [.text("**hello")])
        XCTAssertEqual(MarkdownCodec.parse("***hello", catalog: catalog), [.text("***hello")])
    }

    func testMismatchedClosingCount() {
        // `***hello**` — opening 3 stars, closing 2: matches as bold; the
        // extra leading star becomes literal.
        XCTAssertEqual(MarkdownCodec.parse("***hello**", catalog: catalog),
                       [.text("*"), .styled("hello", .bold)])
    }

    func testLinkInsideText() {
        let runs = MarkdownCodec.parse("see [me](https://x.com) ok", catalog: catalog)
        XCTAssertEqual(runs, [
            .text("see "),
            .link(text: "me", url: "https://x.com"),
            .text(" ok"),
        ])
    }

    func testImageBlobOnly() {
        let runs = MarkdownCodec.parse("![](blob://abc123)", catalog: catalog)
        XCTAssertEqual(runs, [.image(blobID: "abc123")])
    }

    func testImageWithAltIgnoresAlt() {
        // Alt text is intentionally not preserved — round-trip via serialize
        // would drop it anyway.
        let runs = MarkdownCodec.parse("![old size](blob://abc123)", catalog: catalog)
        XCTAssertEqual(runs, [.image(blobID: "abc123")])
    }

    func testNonBlobImageRejected() {
        // We only render blob-addressed images. A regular URL image stays
        // literal text so the user can see the misformat.
        let runs = MarkdownCodec.parse("![](https://x.com/a.png)", catalog: catalog)
        XCTAssertEqual(runs, [.text("![](https://x.com/a.png)")])
    }

    func testBlobIDsScanner() {
        let body = "intro ![](blob://a1) and ![](blob://b2) end"
        XCTAssertEqual(MarkdownCodec.blobIDs(in: body), ["a1", "b2"])
    }
}
