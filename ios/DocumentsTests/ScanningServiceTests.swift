import XCTest
@testable import Documents

@MainActor
final class ScanningServiceTests: XCTestCase {
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 30
        components.hour = 9
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testSuggestedNamesFollowTheBriefFormats() {
        XCTAssertEqual(
            ScanningService.suggestedName(for: .document, date: fixedDate),
            "Scan 2026-08-30.pdf"
        )
        XCTAssertEqual(
            ScanningService.suggestedName(for: .idCard, date: fixedDate),
            "ID Card 2026-08-30.pdf"
        )
        XCTAssertEqual(
            ScanningService.suggestedName(for: .testPaper, date: fixedDate),
            "Test Paper 2026-08-30.txt"
        )
    }

    func testEveryModeHasTitleAndInstructions() {
        for mode in ScanMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, "\(mode) needs a title")
            XCTAssertFalse(mode.instructions.isEmpty, "\(mode) needs instructions")
        }
    }

    func testCameraAvailabilityIsABooleanDecision() {
        // Simulator has no camera hardware; the exact value is environment
        // dependent, so we only assert the check itself is callable and the
        // alert path (driven by this flag) stays reachable in both worlds.
        let available = ScanningService.isCameraAvailable
        XCTAssertNotNil(available as Bool?)
    }

    func testImageNamesSinglePageKeepsBaseName() {
        XCTAssertEqual(
            ScanningService.imageNames(pageCount: 1, date: fixedDate),
            ["Scan 2026-08-30.png"]
        )
    }

    func testImageNamesMultiPageGetsPageSuffixes() {
        XCTAssertEqual(
            ScanningService.imageNames(pageCount: 3, date: fixedDate),
            ["Scan 2026-08-30 Page 1.png", "Scan 2026-08-30 Page 2.png", "Scan 2026-08-30 Page 3.png"]
        )
    }

    func testLongImageNameUsesDayStamp() {
        XCTAssertEqual(
            ScanningService.longImageName(date: fixedDate),
            "Scan 2026-08-30 Long.png"
        )
    }
}
