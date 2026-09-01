import XCTest
@testable import Documents

/// The Recent sort menu: field choice, direction, and deterministic
/// tie-breaking.
final class DocumentSortTests: XCTestCase {
    private func record(
        _ name: String,
        kind: DocumentKind = .pdf,
        size: Int64 = 100,
        openedAt: Date
    ) -> DocumentRecord {
        DocumentRecord(
            displayName: name,
            relativePath: name,
            kind: kind,
            sizeBytes: size,
            lastOpenedAt: openedAt
        )
    }

    func testDefaultIsDateDescending() {
        XCTAssertEqual(DocumentSort.defaultSort.field, .date)
        XCTAssertTrue(DocumentSort.defaultSort.isDescending)
    }

    func testDateSortFollowsDirection() {
        let old = record("Old.pdf", openedAt: Date(timeIntervalSince1970: 100))
        let new = record("New.pdf", openedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(DocumentSort.defaultSort.sorted([old, new]).map(\.displayName), ["New.pdf", "Old.pdf"])

        var ascending = DocumentSort.defaultSort
        ascending.isDescending = false
        XCTAssertEqual(ascending.sorted([old, new]).map(\.displayName), ["Old.pdf", "New.pdf"])
    }

    func testNameSortIsCaseInsensitiveAndFollowsDirection() {
        let records = [
            record("banana.pdf", openedAt: .now),
            record("Apple.pdf", openedAt: .now),
            record("cherry.pdf", openedAt: .now),
        ]

        var byName = DocumentSort.defaultSort
        byName.field = .name
        byName.isDescending = false
        XCTAssertEqual(byName.sorted(records).map(\.displayName), ["Apple.pdf", "banana.pdf", "cherry.pdf"])

        byName.isDescending = true
        XCTAssertEqual(byName.sorted(records).map(\.displayName), ["cherry.pdf", "banana.pdf", "Apple.pdf"])
    }

    func testSizeSortFollowsDirection() {
        let small = record("small.zip", size: 10, openedAt: .now)
        let large = record("large.zip", size: 900, openedAt: .now)

        var bySize = DocumentSort.defaultSort
        bySize.field = .size
        XCTAssertEqual(bySize.sorted([small, large]).map(\.displayName), ["large.zip", "small.zip"])

        bySize.isDescending = false
        XCTAssertEqual(bySize.sorted([small, large]).map(\.displayName), ["small.zip", "large.zip"])
    }

    func testKindSortOrdersByTypeLabelThenName() {
        let records = [
            record("zeta.docx", kind: .word, openedAt: .now),
            record("beta.pdf", kind: .pdf, openedAt: .now),
            record("alpha.docx", kind: .word, openedAt: .now),
            record("gamma.zip", kind: .archive, openedAt: .now),
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
        let b = record("B.pdf", size: 42, openedAt: sameMoment)
        let a = record("A.pdf", size: 42, openedAt: sameMoment)

        XCTAssertEqual(DocumentSort.defaultSort.sorted([b, a]).map(\.displayName), ["A.pdf", "B.pdf"])

        var ascending = DocumentSort.defaultSort
        ascending.isDescending = false
        XCTAssertEqual(ascending.sorted([b, a]).map(\.displayName), ["A.pdf", "B.pdf"])
    }
}
