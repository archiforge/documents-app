import XCTest
@testable import Documents

/// Rules of the shared rename dialog (board R3.9): 50-character cap and a
/// Confirm button that requires a non-blank name.
final class RenameFormTests: XCTestCase {
    func testClampEnforcesTheRecordedFiftyCharacterCap() {
        XCTAssertEqual(RenameForm.nameLimit, 50)
        XCTAssertEqual(RenameForm.clamped("a").count, 1)
        let fiftyAs = String(repeating: "a", count: 50)
        XCTAssertEqual(RenameForm.clamped(fiftyAs), fiftyAs)
        XCTAssertEqual(RenameForm.clamped(fiftyAs + "overflow"), fiftyAs)
    }

    func testConfirmRequiresNonBlankName() {
        XCTAssertTrue(RenameForm.canConfirm("Scan"))
        XCTAssertTrue(RenameForm.canConfirm("  Padded  "))
        XCTAssertFalse(RenameForm.canConfirm(""))
        XCTAssertFalse(RenameForm.canConfirm("   "))
        XCTAssertFalse(RenameForm.canConfirm("\n"))
    }

    func testBaseNameStripsExactlyOneExtension() {
        XCTAssertEqual(RenameForm.baseName(of: "Report.pdf"), "Report")
        XCTAssertEqual(RenameForm.baseName(of: "Archive.tar.gz"), "Archive.tar")
        XCTAssertEqual(RenameForm.baseName(of: "NoExtension"), "NoExtension")
        XCTAssertEqual(RenameForm.baseName(of: ".hidden"), ".hidden")
    }
}
