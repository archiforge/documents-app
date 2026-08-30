import PDFKit
import XCTest
@testable import Documents

final class PDFAssemblerTests: XCTestCase {
    func testTwoImagesBecomeTwoPagesSizedToImages() throws {
        let first = TestPDF.solidImage(size: CGSize(width: 100, height: 150), color: .systemRed)
        let second = TestPDF.solidImage(size: CGSize(width: 200, height: 80), color: .systemBlue)

        let data = try PDFAssembler.pdfData(from: [first, second])

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)

        let firstBounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(firstBounds.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(firstBounds.size.height, 150, accuracy: 0.5)

        let secondBounds = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(secondBounds.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(secondBounds.size.height, 80, accuracy: 0.5)
    }

    func testEmptyImageListThrows() {
        XCTAssertThrowsError(try PDFAssembler.pdfData(from: [])) { error in
            XCTAssertEqual(error as? PDFAssemblerError, .noImages)
        }
    }
}
