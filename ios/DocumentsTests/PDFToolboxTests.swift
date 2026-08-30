import PDFKit
import XCTest
@testable import Documents

final class PDFToolboxTests: XCTestCase {
    // MARK: - Merge

    func testMergeCombinesPageCounts() throws {
        let twoPages = TestPDF.make(pageCount: 2)
        let threePages = TestPDF.make(pageCount: 3)

        let merged = try PDFToolbox.merge([twoPages, threePages])

        XCTAssertEqual(try PDFToolbox.pageCount(of: merged), 5)
    }

    func testMergeRequiresAtLeastTwoSources() {
        let single = TestPDF.make(pageCount: 1)

        XCTAssertThrowsError(try PDFToolbox.merge([single])) { error in
            XCTAssertEqual(error as? PDFToolboxError, .notEnoughDocumentsToMerge)
        }
    }

    // MARK: - Split

    func testExtractRangeProducesRequestedPages() throws {
        let source = TestPDF.make(pageCount: 5)

        let extracted = try PDFToolbox.extractRange(source, pages: 2...4)

        XCTAssertEqual(try PDFToolbox.pageCount(of: extracted), 3)
    }

    func testExtractRangeRejectsOutOfRange() {
        let source = TestPDF.make(pageCount: 5)

        XCTAssertThrowsError(try PDFToolbox.extractRange(source, pages: 4...9)) { error in
            XCTAssertEqual(error as? PDFToolboxError, .invalidPageRange)
        }
    }

    func testSplitEveryNProducesExpectedChunks() throws {
        let source = TestPDF.make(pageCount: 5)

        let chunks = try PDFToolbox.splitEvery(source, chunkSize: 2)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(
            try chunks.map { try PDFToolbox.pageCount(of: $0) },
            [2, 2, 1]
        )
    }

    func testSplitEveryRejectsZeroChunkSize() {
        let source = TestPDF.make(pageCount: 2)

        XCTAssertThrowsError(try PDFToolbox.splitEvery(source, chunkSize: 0)) { error in
            XCTAssertEqual(error as? PDFToolboxError, .invalidChunkSize)
        }
    }

    // MARK: - Watermark

    func testWatermarkKeepsPageCountAndChangesBytes() throws {
        let source = TestPDF.make(pageCount: 3)

        let watermarked = try PDFToolbox.watermark(source, text: "Documents Sample")

        XCTAssertEqual(
            try PDFToolbox.pageCount(of: watermarked),
            try PDFToolbox.pageCount(of: source),
            "Watermarking must not change the page count"
        )
        XCTAssertNotEqual(source, watermarked, "Watermarked bytes must differ from the source")
    }

    func testWatermarkRejectsEmptyText() {
        let source = TestPDF.make(pageCount: 1)

        XCTAssertThrowsError(try PDFToolbox.watermark(source, text: "   ")) { error in
            XCTAssertEqual(error as? PDFToolboxError, .emptyWatermarkText)
        }
    }

    // MARK: - Sign

    func testSignKeepsPageCountAndChangesBytes() throws {
        let source = TestPDF.make(pageCount: 2)
        let ink = TestPDF.solidImage(size: CGSize(width: 220, height: 70), color: .black)

        let signed = try PDFToolbox.sign(source, ink: ink, pageIndex: 1)

        XCTAssertEqual(try PDFToolbox.pageCount(of: signed), 2, "Signing must preserve page count")
        XCTAssertNotEqual(source, signed)
    }

    func testSignRejectsPageIndexOutsideDocument() {
        let source = TestPDF.make(pageCount: 2)
        let ink = TestPDF.solidImage(size: CGSize(width: 100, height: 40), color: .black)

        XCTAssertThrowsError(try PDFToolbox.sign(source, ink: ink, pageIndex: 5)) { error in
            XCTAssertEqual(error as? PDFToolboxError, .invalidPageIndex)
        }
    }

    // MARK: - JPEG extraction

    /// Crafts a minimal PDF containing one DCTDecode image XObject around a
    /// real JPEG payload, then verifies the extractor returns that JPEG
    /// verbatim (SOI/EOI intact).
    func testExtractJPEGFromCraftedPDFWithDCTDecodeXObject() throws {
        let jpeg = try XCTUnwrap(
            TestPDF.solidImage(size: CGSize(width: 24, height: 24), color: .systemRed)
                .jpegData(compressionQuality: 0.8)
        )

        var pdf = Data()
        pdf.append(Data("%PDF-1.4\n".utf8))
        pdf.append(Data("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8))
        pdf.append(Data("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n".utf8))
        pdf.append(Data((
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] " +
                "/Resources << /XObject << /Im0 4 0 R >> >> >>\nendobj\n"
        ).utf8))
        pdf.append(Data((
            "4 0 obj\n<< /Type /XObject /Subtype /Image /Width 24 /Height 24 " +
                "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode " +
                "/Length \(jpeg.count) >>\nstream\n"
        ).utf8))
        pdf.append(jpeg)
        pdf.append(Data("\nendstream\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8))

        let images = PDFToolbox.extractJPEGImages(from: pdf)

        XCTAssertEqual(images.count, 1)
        let bytes = [UInt8](try XCTUnwrap(images.first))
        XCTAssertGreaterThanOrEqual(bytes.count, 4)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker expected")
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xD9], "JPEG EOI marker expected")
    }

    func testTextOnlyPDFYieldsNoJPEGsAndPNGFallbackRendersEveryPage() throws {
        let source = TestPDF.make(pageCount: 2)

        XCTAssertTrue(
            PDFToolbox.extractJPEGImages(from: source).isEmpty,
            "A text-only PDF carries no embedded JPEGs"
        )

        let pngs = try PDFToolbox.renderPagesAsPNG(from: source)
        XCTAssertEqual(pngs.count, 2)
        for png in pngs {
            XCTAssertEqual(Array([UInt8](png).prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic bytes expected")
        }
    }
}
