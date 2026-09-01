import XCTest
@testable import Documents

/// The format filter chips and their matching rules (custom row, ledger #8).
final class FormatFilterTests: XCTestCase {
    func testChipOrderAndTitles() {
        let titles = FormatFilter.allCases.map(\.title)
        XCTAssertEqual(titles, ["All", "Scanned", "PDF", "DOC", "EPUB", "XLS", "TXT"])
    }

    func testAllMatchesEverything() {
        let filter = FormatFilter.all
        for kind in DocumentKind.allCases {
            for provenance in Provenance.allCases {
                XCTAssertTrue(filter.matches(kind: kind, provenance: provenance))
            }
        }
    }

    func testScannedMatchesProvenanceNotKind() {
        let filter = FormatFilter.scanned
        XCTAssertTrue(filter.matches(kind: .pdf, provenance: .scanned))
        XCTAssertTrue(filter.matches(kind: .image, provenance: .scanned))
        XCTAssertFalse(filter.matches(kind: .pdf, provenance: .imported))
        XCTAssertFalse(filter.matches(kind: .pdf, provenance: .created))
    }

    func testKindChipsMapTheirFamilies() {
        XCTAssertTrue(FormatFilter.pdf.matches(kind: .pdf, provenance: .imported))
        XCTAssertTrue(FormatFilter.doc.matches(kind: .word, provenance: .imported))
        XCTAssertTrue(FormatFilter.epub.matches(kind: .epub, provenance: .imported))
        XCTAssertTrue(FormatFilter.xls.matches(kind: .excel, provenance: .device))
        XCTAssertTrue(FormatFilter.txt.matches(kind: .text, provenance: .imported))
        XCTAssertTrue(FormatFilter.txt.matches(kind: .markdown, provenance: .imported))

        XCTAssertFalse(FormatFilter.doc.matches(kind: .pdf, provenance: .imported))
        XCTAssertFalse(FormatFilter.xls.matches(kind: .word, provenance: .imported))
        XCTAssertFalse(FormatFilter.epub.matches(kind: .pdf, provenance: .imported))
        XCTAssertFalse(FormatFilter.txt.matches(kind: .html, provenance: .imported))
    }

    func testDroppedKindsFallThroughToAllOnly() {
        XCTAssertTrue(FormatFilter.all.matches(kind: .powerpoint, provenance: .imported))
        XCTAssertTrue(FormatFilter.all.matches(kind: .ofd, provenance: .imported))
        for filter in FormatFilter.allCases where filter != .all {
            XCTAssertFalse(filter.matches(kind: .powerpoint, provenance: .imported))
            XCTAssertFalse(filter.matches(kind: .ofd, provenance: .imported))
        }
    }

    func testMarkdownCountsAsTxtButHtmlDoesNot() {
        XCTAssertTrue(FormatFilter.txt.matches(kind: .markdown, provenance: .device))
        XCTAssertFalse(FormatFilter.txt.matches(kind: .html, provenance: .device))
    }
}
