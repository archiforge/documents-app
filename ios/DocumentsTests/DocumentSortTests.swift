import XCTest
@testable import Documents

/// The Recent sort menu: field choice, direction, and deterministic
/// tie-breaking. Date is the creation date — the file's actual creation
/// time (`createdAt`) when known, else the import time.
final class DocumentSortTests: XCTestCase {
    private func record(
        _ name: String,
        kind: DocumentKind = .pdf,
        size: Int64 = 100,
        importedAt: Date,
        fileCreatedAt: Date? = nil,
        openedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DocumentRecord {
        DocumentRecord(
            displayName: name,
            relativePath: name,
            kind: kind,
            sizeBytes: size,
            lastOpenedAt: openedAt,
            importedAt: importedAt,
            createdAt: fileCreatedAt
        )
    }

    func testDefaultIsDateDescending() {
        XCTAssertEqual(DocumentSort.defaultSort.field, .date)
        XCTAssertTrue(DocumentSort.defaultSort.isDescending)
    }

    func testDateSortFollowsDirection() {
        let old = record("Old.pdf", importedAt: Date(timeIntervalSince1970: 100))
        let new = record("New.pdf", importedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(DocumentSort.defaultSort.sorted([old, new]).map(\.displayName), ["New.pdf", "Old.pdf"])

        var ascending = DocumentSort.defaultSort
        ascending.isDescending = false
        XCTAssertEqual(ascending.sorted([old, new]).map(\.displayName), ["Old.pdf", "New.pdf"])
    }

    func testFileCreationDateDrivesDateSortOverImportTime() {
        // Imported today, but the file itself was created long ago.
        let ancient = record(
            "ancient.pdf",
            importedAt: Date(timeIntervalSince1970: 900),
            fileCreatedAt: Date(timeIntervalSince1970: 100)
        )
        let fresh = record(
            "fresh.pdf",
            importedAt: Date(timeIntervalSince1970: 100),
            fileCreatedAt: Date(timeIntervalSince1970: 800)
        )

        XCTAssertEqual(
            DocumentSort.defaultSort.sorted([ancient, fresh]).map(\.displayName),
            ["fresh.pdf", "ancient.pdf"]
        )
    }

    func testMissingFileCreationDateFallsBackToImportTime() {
        let lateImport = record("late.pdf", importedAt: Date(timeIntervalSince1970: 900))
        let earlyImport = record("early.pdf", importedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            DocumentSort.defaultSort.sorted([lateImport, earlyImport]).map(\.displayName),
            ["late.pdf", "early.pdf"]
        )
    }

    func testNameSortIsCaseInsensitiveAndFollowsDirection() {
        let records = [
            record("banana.pdf", importedAt: .now),
            record("Apple.pdf", importedAt: .now),
            record("cherry.pdf", importedAt: .now),
        ]

        var byName = DocumentSort.defaultSort
        byName.field = .name
        byName.isDescending = false
        XCTAssertEqual(byName.sorted(records).map(\.displayName), ["Apple.pdf", "banana.pdf", "cherry.pdf"])

        byName.isDescending = true
        XCTAssertEqual(byName.sorted(records).map(\.displayName), ["cherry.pdf", "banana.pdf", "Apple.pdf"])
    }

    func testSizeSortFollowsDirection() {
        let small = record("small.zip", size: 10, importedAt: .now)
        let large = record("large.zip", size: 900, importedAt: .now)

        var bySize = DocumentSort.defaultSort
        bySize.field = .size
        XCTAssertEqual(bySize.sorted([small, large]).map(\.displayName), ["large.zip", "small.zip"])

        bySize.isDescending = false
        XCTAssertEqual(bySize.sorted([small, large]).map(\.displayName), ["small.zip", "large.zip"])
    }

    func testKindSortOrdersByTypeLabelThenName() {
        let records = [
            record("zeta.docx", kind: .word, importedAt: .now),
            record("beta.pdf", kind: .pdf, importedAt: .now),
            record("alpha.docx", kind: .word, importedAt: .now),
            record("gamma.zip", kind: .archive, importedAt: .now),
        ]

        var byKind = DocumentSort.defaultSort
        byKind.field = .kind
        byKind.isDescending = false
        // Labels A→Z: Archive < PDF < Word; ties inside Word fall back to name.
        XCTAssertEqual(
            byKind.sorted(records).map(\.displayName),
            ["gamma.zip", "beta.pdf", "alpha.docx", "zeta.docx"]
        )
    }

    func testEqualKeysTieBreakOnNameAscendingRegardlessOfDirection() {
        let sameMoment = Date(timeIntervalSince1970: 500)
        let b = record("B.pdf", size: 42, importedAt: sameMoment)
        let a = record("A.pdf", size: 42, importedAt: sameMoment)

        XCTAssertEqual(DocumentSort.defaultSort.sorted([b, a]).map(\.displayName), ["A.pdf", "B.pdf"])

        var ascending = DocumentSort.defaultSort
        ascending.isDescending = false
        XCTAssertEqual(ascending.sorted([b, a]).map(\.displayName), ["A.pdf", "B.pdf"])
    }
}
