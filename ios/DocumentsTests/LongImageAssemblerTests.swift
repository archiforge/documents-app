import CoreGraphics
import XCTest
@testable import Documents

/// The "Save as Long Image" stitcher: common width, stacked heights.
final class LongImageAssemblerTests: XCTestCase {
    func testEmptyInputThrows() {
        XCTAssertThrowsError(try LongImageAssembler.image(from: []))
    }

    func testSinglePageKeepsItsSize() throws {
        let page = TestPDF.solidImage(size: CGSize(width: 300, height: 400), color: .red)
        let stitched = try LongImageAssembler.image(from: [page])
        XCTAssertEqual(stitched.size.width, 300, accuracy: 1)
        XCTAssertEqual(stitched.size.height, 400, accuracy: 1)
    }

    func testPagesAreScaledToCommonWidthAndStackedVertically() throws {
        // 100x200 scaled to the common width 200 doubles to 400 tall;
        // 200x300 stays 300 tall. Total: 200 wide, 700 tall.
        let narrow = TestPDF.solidImage(size: CGSize(width: 100, height: 200), color: .blue)
        let wide = TestPDF.solidImage(size: CGSize(width: 200, height: 300), color: .green)
        let stitched = try LongImageAssembler.image(from: [narrow, wide])
        XCTAssertEqual(stitched.size.width, 200, accuracy: 1)
        XCTAssertEqual(stitched.size.height, 700, accuracy: 1)
    }

    func testPngDataIsAValidImage() throws {
        let page = TestPDF.solidImage(size: CGSize(width: 64, height: 64), color: .purple)
        let data = try LongImageAssembler.pngData(from: [page, page])
        XCTAssertNotNil(UIImage(data: data))
    }

    func testOrderIsPreservedTopToBottom() throws {
        // The top half is red, the bottom half is green.
        let red = TestPDF.solidImage(size: CGSize(width: 50, height: 50), color: .red)
        let green = TestPDF.solidImage(size: CGSize(width: 50, height: 50), color: .green)
        let stitched = try LongImageAssembler.image(from: [red, green])

        guard let cg = stitched.cgImage,
              let redCG = red.cgImage,
              let greenCG = green.cgImage else {
            return XCTFail("images should expose CGImages")
        }

        // Reference triples come from the same TestPDF.solidImage path, so
        // the pixel color is comparable even when the two renderers emit
        // different byte orders (RGBA vs BGRA): each triple is normalized
        // to R,G,B via its own bitmapInfo before comparing.
        guard let redRef = rgbTriple(at: CGPoint(x: redCG.width / 2, y: redCG.height / 2), in: redCG),
              let greenRef = rgbTriple(at: CGPoint(x: greenCG.width / 2, y: greenCG.height / 2), in: greenCG) else {
            return XCTFail("reference samples should be readable")
        }

        let top = rgbTriple(at: CGPoint(x: 25, y: 10), in: cg)
        let bottom = rgbTriple(at: CGPoint(x: 25, y: 90), in: cg)
        XCTAssertEqual(top, redRef)
        XCTAssertEqual(bottom, greenRef)
    }
}

/// Samples the RGB triple at a point in top-left pixel coordinates and
/// normalizes it to R,G,B order using the image's own byte-order info,
/// so differently formatted bitmaps (RGBA vs BGRA) compare equal.
private func rgbTriple(at point: CGPoint, in cg: CGImage) -> [UInt8]? {
    guard cg.bitsPerPixel == 32,
          let data = cg.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }
    let offset = Int(point.y) * cg.bytesPerRow + Int(point.x) * 4
    guard offset >= 0, offset + 3 < CFDataGetLength(data) else { return nil }

    let alphaInfo = cg.alphaInfo
    let alphaFirst = alphaInfo == .premultipliedFirst
        || alphaInfo == .first
        || alphaInfo == .noneSkipFirst
    // kCGBitmapByteOrderMask / kCGBitmapByteOrder32Little are not exposed
    // to Swift; use their CGImage.h values (0x7000 and 2 << 12).
    let littleEndian = cg.bitmapInfo.rawValue & 0x7000 == 0x2000

    switch (littleEndian, alphaFirst) {
    case (false, false): return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]     // R,G,B,A
    case (false, true): return [bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]  // A,R,G,B
    case (true, false): return [bytes[offset + 3], bytes[offset + 2], bytes[offset + 1]]  // A,B,G,R
    case (true, true): return [bytes[offset + 2], bytes[offset + 1], bytes[offset]]       // B,G,R,A
    }
}
