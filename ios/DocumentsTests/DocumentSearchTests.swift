import XCTest
@testable import Documents

/// The Recent search bar: the query is a case- and diacritic-insensitive
/// substring of the display name, and composes with the format chips —
/// search only narrows within the active document type.
final class DocumentSearchTests: XCTestCase {
    private func record(_ name: String, kind: DocumentKind) -> DocumentRecord {
        DocumentRecord(
            displayName: name,
            relativePath: name,
            kind: kind,
            sizeBytes: 100,
            lastOpenedAt: Date(timeIntervalSince1970: 1_000),
            importedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(DocumentSearch.matches("", name: "Anything.pdf"))
    }

    func testWhitespaceOnlyQueryMatchesEverything() {
        XCTAssertTrue(DocumentSearch.matches(" \n\t ", name: "Anything.pdf"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(DocumentSearch.matches("REPORT", name: "quarterly report.pdf"))
        XCTAssertTrue(DocumentSearch.matches("report", name: "Quarterly REPORT.pdf"))
    }

    func testMatchIsDiacriticInsensitive() {
        XCTAssertTrue(DocumentSearch.matches("cafe", name: "Café Menu.pdf"))
        XCTAssertTrue(DocumentSearch.matches("CAFÉ", name: "cafe menu.pdf"))
    }

    func testMatchIsSubstringAnywhereInName() {
        XCTAssertTrue(DocumentSearch.matches("quarterly", name: "quarterly report 2026.pdf"))
        XCTAssertTrue(DocumentSearch.matches("2026", name: "quarterly report 2026.pdf"))
    }

    func testRejectsNonMatchingNames() {
        XCTAssertFalse(DocumentSearch.matches("invoice", name: "quarterly report.pdf"))
    }

    func testSearchComposesWithFormatFilterChip() {
        let records = [
            record("Annual Report.pdf", kind: .pdf),
            record("Report.docx", kind: .word),
            record("report.epub", kind: .epub),
        ]

        // The PDF chip scopes the search: the EPUB/DOC names that also
        // match stay hidden.
        let pdfOnly = records.filter {
            FormatFilter.pdf.matches($0) && DocumentSearch.matches("report", name: $0.displayName)
        }
        XCTAssertEqual(pdfOnly.map(\.displayName), ["Annual Report.pdf"])

        // Under All, every name match is visible.
        let all = records.filter {
            FormatFilter.all.matches($0) && DocumentSearch.matches("report", name: $0.displayName)
        }
        XCTAssertEqual(Set(all.map(\.displayName)), Set(["Annual Report.pdf", "Report.docx", "report.epub"]))
    }
}
