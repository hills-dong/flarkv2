import XCTest
@testable import FlarkKit

final class ContentDocumentTests: XCTestCase {
    private let catalog = EmojiCatalog(items: [
        EmojiItem(id: "lark_done", file: "done.png", nameZh: "完成", nameEn: "done")
    ])

    func testJSONRoundTrip() throws {
        let body = "上线窗口已确认 [lark_done] 见图\n![](blob://abc123)"
        let doc = ContentDocument(body: body)
        let data = try doc.encoded()
        let back = try ContentDocument.decode(data)
        XCTAssertEqual(doc, back)
        XCTAssertEqual(back.body, body)
    }

    func testBlobIDsExtraction() {
        let doc = ContentDocument(body: "intro ![](blob://a1) middle ![](blob://b2) end")
        XCTAssertEqual(doc.blobIDs, ["a1", "b2"])
    }

    func testPlainText() {
        let doc = ContentDocument(body: "see **this** and [lark_done] then ![](blob://x)")
        XCTAssertEqual(doc.plainText(catalog: catalog), "see this and [完成] then [图片]")
    }

    func testEmptyDetection() {
        XCTAssertTrue(ContentDocument(text: "   ").isEmpty)
        XCTAssertTrue(ContentDocument().isEmpty)
        XCTAssertFalse(ContentDocument(body: "yo").isEmpty)
    }

    func testTextInitEscapesSpecials() {
        // `ContentDocument(text:)` accepts a plain string — special chars get
        // escaped so the body parses back as one literal text run.
        let doc = ContentDocument(text: "price [50] *not bold*")
        let runs = MarkdownCodec.parse(doc.body, catalog: catalog)
        XCTAssertEqual(runs, [.text("price [50] *not bold*")])
    }
}
