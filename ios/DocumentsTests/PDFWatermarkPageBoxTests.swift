import CoreGraphics
import PDFKit
import XCTest
@testable import Documents

/// Phase 0 regression: the watermark pass used to stamp every output page
/// with a fixed US-Letter media box (612×792), clipping A4, landscape, and
/// custom page sizes. These tests pin each source page box, in order.
final class PDFWatermarkPageBoxTests: XCTestCase {
    private let tolerance: CGFloat = 0.5

    private func pageBoxes(of data: Data) throws -> [CGSize] {
        guard
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider)
        else {
            return []
        }
        return (1...max(document.numberOfPages, 0)).compactMap { index in
            document.page(at: index)?.getBoxRect(.mediaBox).size
        }
    }

    private func assertBoxes(_ actual: [CGSize], match expected: [CGSize]) throws {
        XCTAssertEqual(actual.count, expected.count)
        for (index, size) in expected.enumerated() {
            let box = try XCTUnwrap(actual[safe: index])
            XCTAssertEqual(box.width, size.width, accuracy: tolerance, "page \(index + 1) width")
            XCTAssertEqual(box.height, size.height, accuracy: tolerance, "page \(index + 1) height")
        }
    }

    func testWatermarkPreservesA4PageBox() throws {
        let a4 = CGSize(width: 595, height: 842)
        let source = TestPDF.make(pageCount: 1, pageSize: a4)

        let output = try PDFToolbox.watermark(source, text: "CONFIDENTIAL")

        try assertBoxes(try pageBoxes(of: output), match: [a4])
    }

    func testWatermarkPreservesLandscapePageBox() throws {
        let landscape = CGSize(width: 792, height: 612)
        let source = TestPDF.make(pageCount: 1, pageSize: landscape)

        let output = try PDFToolbox.watermark(source, text: "CONFIDENTIAL")

        try assertBoxes(try pageBoxes(of: output), match: [landscape])
    }

    func testWatermarkPreservesRotatedQuadrantPageBox() throws {
        let portrait = CGSize(width: 612, height: 792)
        let source = TestPDF.make(pageCount: 1, pageSize: portrait)
        let document = try XCTUnwrap(PDFDocument(data: source))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        let rotated = try XCTUnwrap(document.dataRepresentation(), "PDFKit must persist the /Rotate entry")

        let output = try PDFToolbox.watermark(rotated, text: "CONFIDENTIAL")

        try assertBoxes(try pageBoxes(of: output), match: [portrait])
    }

    func testWatermarkPreservesMixedPageSizesInOrder() throws {
        let letter = CGSize(width: 612, height: 792)
        let a4 = CGSize(width: 595, height: 842)
        let landscape = CGSize(width: 792, height: 612)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter))
        let mixed = renderer.pdfData { context in
            context.beginPage()
            context.beginPage(withBounds: CGRect(origin: .zero, size: a4), pageInfo: [:])
            context.beginPage(withBounds: CGRect(origin: .zero, size: landscape), pageInfo: [:])
        }

        let output = try PDFToolbox.watermark(mixed, text: "CONFIDENTIAL")

        try assertBoxes(try pageBoxes(of: output), match: [letter, a4, landscape])
    }

    /// `sign()` flattens pages the same way watermarking does; the first
    /// page must not silently take the renderer bounds on mixed-size docs.
    func testSignPreservesMixedPageSizesInOrder() throws {
        let letter = CGSize(width: 612, height: 792)
        let a4 = CGSize(width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter))
        let mixed = renderer.pdfData { context in
            context.beginPage()
            context.beginPage(withBounds: CGRect(origin: .zero, size: a4), pageInfo: [:])
        }
        let ink = TestPDF.solidImage(size: CGSize(width: 220, height: 70), color: .black)

        let signed = try PDFToolbox.sign(mixed, ink: ink, pageIndex: 0)

        try assertBoxes(try pageBoxes(of: signed), match: [letter, a4])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
