import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Documents

final class ScanPageRendererTests: XCTestCase {
    func testRotateThenCropPreservesTheRotatedQuadrant() throws {
        let sourceData = try quadrantSourceData()
        let page = ScanPageBuffer(
            data: sourceData,
            edit: ScanPageEdit(
                rotationDegrees: 90,
                crop: ScanCrop(x: 0.5, y: 0, width: 0.5, height: 0.25)
            )
        )

        let rendered = try XCTUnwrap(UIImage(data: try ScanPageRenderer.imageData(for: page)))
        XCTAssertEqual(rendered.size.width, 20, accuracy: 1)
        XCTAssertEqual(rendered.size.height, 20, accuracy: 1)

        let pixel = try centerPixel(of: rendered)
        XCTAssertGreaterThan(pixel.red, 180)
        XCTAssertLessThan(pixel.green, 100)
        XCTAssertLessThan(pixel.blue, 100)
    }

    func testRotatingAnExistingCropTransformsItsNormalizedRegion() throws {
        let page = ScanPageBuffer(
            data: try quadrantSourceData(),
            edit: ScanPageEdit(crop: ScanCrop(x: 0.5, y: 0, width: 0.5, height: 0.5))
        )
        let rotated = ScanPageEditing.rotating(page)

        XCTAssertEqual(rotated.edit.crop, ScanCrop(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let rendered = try XCTUnwrap(UIImage(data: try ScanPageRenderer.imageData(for: rotated)))
        let pixel = try centerPixel(of: rendered)
        XCTAssertGreaterThan(pixel.green, 180)
        XCTAssertLessThan(pixel.red, 100)
        XCTAssertLessThan(pixel.blue, 100)
    }

    func testEXIFOrientationIsNormalizedBeforeCropping() throws {
        let page = ScanPageBuffer(
            data: try orientedQuadrantSourceData(),
            edit: ScanPageEdit(crop: ScanCrop(x: 0.5, y: 0, width: 0.5, height: 0.25))
        )

        let rendered = try XCTUnwrap(UIImage(data: try ScanPageRenderer.imageData(for: page)))
        XCTAssertEqual(rendered.size.width, 20, accuracy: 1)
        XCTAssertEqual(rendered.size.height, 20, accuracy: 1)
        let pixel = try centerPixel(of: rendered)
        XCTAssertGreaterThan(pixel.red, 180)
        XCTAssertLessThan(pixel.green, 100)
        XCTAssertLessThan(pixel.blue, 100)
    }

    func testPreviewDecodedPixelsStayWithinRequestedBound() async throws {
        let page = ScanPageBuffer(data: try quadrantSourceData())
        let previewData = try await ScanPageRenderer.previewData(for: page, maxDimension: 16)
        let preview = try XCTUnwrap(UIImage(data: previewData)?.cgImage)

        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 16)
    }

    private func quadrantSourceData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 20))
            UIColor.green.setFill()
            UIRectFill(CGRect(x: 40, y: 0, width: 40, height: 20))
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: 20, width: 40, height: 20))
            UIColor.yellow.setFill()
            UIRectFill(CGRect(x: 40, y: 20, width: 40, height: 20))
        }
        return try XCTUnwrap(source.pngData())
    }

    private func orientedQuadrantSourceData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 20))
            UIColor.green.setFill()
            UIRectFill(CGRect(x: 40, y: 0, width: 40, height: 20))
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: 20, width: 40, height: 20))
            UIColor.yellow.setFill()
            UIRectFill(CGRect(x: 40, y: 20, width: 40, height: 20))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(source.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func centerPixel(of image: UIImage) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (bytes[0], bytes[1], bytes[2])
    }
}
