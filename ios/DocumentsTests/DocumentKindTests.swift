import XCTest
@testable import Documents

final class DocumentKindTests: XCTestCase {
    func testKindDerivedFromExtension() {
        XCTAssertEqual(DocumentKind(filename: "a.pdf"), .pdf)
        XCTAssertEqual(DocumentKind(filename: "b.DOCX"), .word)
        XCTAssertEqual(DocumentKind(filename: "c.xls"), .excel)
        XCTAssertEqual(DocumentKind(filename: "d.pptx"), .powerpoint)
        XCTAssertEqual(DocumentKind(filename: "e.txt"), .text)
        XCTAssertEqual(DocumentKind(filename: "f.md"), .markdown)
        XCTAssertEqual(DocumentKind(filename: "g.html"), .html)
        XCTAssertEqual(DocumentKind(filename: "h.PNG"), .image)
        XCTAssertEqual(DocumentKind(filename: "i.zip"), .archive)
        XCTAssertEqual(DocumentKind(filename: "k.ofd"), .ofd)
        XCTAssertEqual(DocumentKind(filename: "l.OFD"), .ofd)
        XCTAssertEqual(DocumentKind(filename: "m.epub"), .epub)
        XCTAssertEqual(DocumentKind(filename: "n.EPUB"), .epub)
        XCTAssertEqual(DocumentKind(filename: "j.unknownext"), .other)
        XCTAssertEqual(DocumentKind(filename: "noextension"), .other)
    }

    func testEveryKindHasGlyphAndLabel() {
        for kind in DocumentKind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) needs an SF Symbol")
            XCTAssertFalse(kind.label.isEmpty, "\(kind) needs a label")
        }
    }
}
