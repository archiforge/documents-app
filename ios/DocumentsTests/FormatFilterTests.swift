import XCTest
@testable import Documents

/// The format filter chips and their matching rules (Android chip order).
final class FormatFilterTests: XCTestCase {
    func testChipsMatchAndroidOrderAndTitles() {
        let titles = FormatFilter.allCases.map(\.title)
        XCTAssertEqual(titles, ["All", "Scanned", "DOC", "XLS", "PPT", "PDF", "OFD", "TXT"])
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
        XCTAssertTrue(FormatFilter.doc.matches(kind: .word, provenance: .imported))
        XCTAssertTrue(FormatFilter.xls.matches(kind: .excel, provenance: .device))
        XCTAssertTrue(FormatFilter.ppt.matches(kind: .powerpoint, provenance: .cloud))
        XCTAssertTrue(FormatFilter.pdf.matches(kind: .pdf, provenance: .imported))
        XCTAssertTrue(FormatFilter.ofd.matches(kind: .ofd, provenance: .imported))
        XCTAssertTrue(FormatFilter.txt.matches(kind: .text, provenance: .imported))
        XCTAssertTrue(FormatFilter.txt.matches(kind: .markdown, provenance: .imported))

        XCTAssertFalse(FormatFilter.doc.matches(kind: .pdf, provenance: .imported))
        XCTAssertFalse(FormatFilter.xls.matches(kind: .word, provenance: .imported))
        XCTAssertFalse(FormatFilter.ofd.matches(kind: .pdf, provenance: .imported))
        XCTAssertFalse(FormatFilter.txt.matches(kind: .html, provenance: .imported))
    }

    func testMarkdownCountsAsTxtButHtmlDoesNot() {
        XCTAssertTrue(FormatFilter.txt.matches(kind: .markdown, provenance: .device))
        XCTAssertFalse(FormatFilter.txt.matches(kind: .html, provenance: .device))
    }
}
