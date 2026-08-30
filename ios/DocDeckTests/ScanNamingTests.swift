import XCTest
@testable import DocDeck

/// Pins the shipped scan-naming path: `ScanningService.baseName` /
/// `fileName` are what the scanner flow actually uses for every save, so
/// the rename and extension rules are covered here instead of only in the
/// view.
@MainActor
final class ScanNamingTests: XCTestCase {
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 30
        components.hour = 9
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - baseName

    func testBaseNameDefaultsToDatedSuggestedName() {
        XCTAssertEqual(
            ScanningService.baseName(for: .document, renamed: nil, date: fixedDate),
            "Scan 2026-08-30"
        )
        XCTAssertEqual(
            ScanningService.baseName(for: .idCard, renamed: nil, date: fixedDate),
            "ID Card 2026-08-30"
        )
        XCTAssertEqual(
            ScanningService.baseName(for: .testPaper, renamed: nil, date: fixedDate),
            "Test Paper 2026-08-30"
        )
    }

    func testBaseNamePrefersNonEmptyRename() {
        XCTAssertEqual(
            ScanningService.baseName(for: .document, renamed: "Contract", date: fixedDate),
            "Contract"
        )
    }

    func testBaseNameTreatsWhitespaceRenameAsAbsent() {
        XCTAssertEqual(
            ScanningService.baseName(for: .document, renamed: "   ", date: fixedDate),
            "Scan 2026-08-30"
        )
    }

    // MARK: - fileName

    func testFileNameAppendsMissingExtension() {
        XCTAssertEqual(
            ScanningService.fileName(base: "Scan 2026-08-30", fileExtension: "pdf"),
            "Scan 2026-08-30.pdf"
        )
    }

    func testFileNameKeepsExistingExtension() {
        XCTAssertEqual(
            ScanningService.fileName(base: "Report.pdf", fileExtension: "pdf"),
            "Report.pdf"
        )
    }

    func testFileNameAppendsWhenExtensionDiffers() {
        XCTAssertEqual(
            ScanningService.fileName(base: "Report.png", fileExtension: "pdf"),
            "Report.png.pdf"
        )
    }
}
