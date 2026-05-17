import XCTest
@testable import FlarkKit

final class ContentDocumentTests: XCTestCase {
    func testRoundTrip() throws {
        let doc = ContentDocument(segments: [
            .text("上线窗口已确认 "),
            .emoji(id: "lark_done"),
            .text(" 见图"),
            .image(blobID: "abc123", width: 800, height: 600)
        ])
        let data = try doc.encoded()
        let back = try ContentDocument.decode(data)
        XCTAssertEqual(doc, back)
        XCTAssertEqual(back.blobIDs, ["abc123"])
        XCTAssertEqual(back.plainText, "上线窗口已确认 [lark_done] 见图[图片]")
        XCTAssertFalse(back.isEmpty)
    }

    func testEmptyDetection() {
        XCTAssertTrue(ContentDocument(text: "   ").isEmpty)
        XCTAssertTrue(ContentDocument().isEmpty)
        XCTAssertFalse(ContentDocument(segments: [.emoji(id: "x")]).isEmpty)
    }
}
