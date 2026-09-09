import PDFKit
import XCTest
@testable import Documents

final class PDFPasswordProtectionTests: XCTestCase {
    func testEncryptProducesLockedCopyThatUnlocksWithPassword() throws {
        let source = TestPDF.make(pageCount: 2)
        let original = source
        let password = "correct horse battery staple"

        let protected = try PDFToolbox.encrypt(
            source,
            password: password,
            confirmation: password
        )

        let document = try XCTUnwrap(PDFDocument(data: protected))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "wrong password"))
        XCTAssertTrue(document.isLocked)
        XCTAssertTrue(document.unlock(withPassword: password))
        XCTAssertFalse(document.isLocked)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.string, PDFDocument(data: source)?.string)
        XCTAssertEqual(source, original, "Protecting a PDF must not mutate source bytes")
        XCTAssertNotEqual(protected, source)
    }

    func testEncryptRejectsEmptyAndMismatchedPasswords() {
        let source = TestPDF.make(pageCount: 1)

        XCTAssertThrowsError(
            try PDFToolbox.encrypt(source, password: "   ", confirmation: "   ")
        ) { error in
            XCTAssertEqual(error as? PDFPasswordProtectionError, .emptyPassword)
        }
        XCTAssertThrowsError(
            try PDFToolbox.encrypt(source, password: "one", confirmation: "two")
        ) { error in
            XCTAssertEqual(error as? PDFPasswordProtectionError, .passwordMismatch)
        }
    }

    func testEncryptRejectsAlreadyProtectedSource() throws {
        let source = TestPDF.make(pageCount: 1)
        let protected = try PDFToolbox.encrypt(
            source,
            password: "first password",
            confirmation: "first password"
        )

        XCTAssertThrowsError(
            try PDFToolbox.encrypt(
                protected,
                password: "second password",
                confirmation: "second password"
            )
        ) { error in
            XCTAssertEqual(error as? PDFPasswordProtectionError, .sourceAlreadyLocked)
        }
    }
}
