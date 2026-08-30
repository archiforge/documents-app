import UIKit

/// Stitches scanned pages into one tall image (the Android app's
/// "Save as Long Image"): pages are scaled to a common width and stacked
/// vertically. Pure logic so it is unit-testable without a camera.
enum LongImageAssembler {
    enum Error: Swift.Error, LocalizedError {
        case noImages

        var errorDescription: String? {
            switch self {
            case .noImages: "There are no pages to stitch."
            }
        }
    }

    /// Renders `images` top-to-bottom at a common width (the widest page),
    /// preserving each page's aspect ratio. Rendered at scale 1 so the
    /// output pixel size is exactly the summed page heights.
    static func image(from images: [UIImage]) throws -> UIImage {
        guard let first = images.first else { throw Error.noImages }

        let commonWidth = images.reduce(CGFloat.zero) { max($0, $1.size.width) }
        let heights = images.map { image in
            let scale = image.size.width > 0 ? commonWidth / image.size.width : 1
            return image.size.height * scale
        }
        let totalHeight = heights.reduce(0, +)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: commonWidth, height: totalHeight),
            format: format
        )
        return renderer.image { _ in
            var offsetY: CGFloat = 0
            for (index, image) in images.enumerated() {
                let rect = CGRect(
                    x: 0,
                    y: offsetY,
                    width: commonWidth,
                    height: heights[index]
                )
                image.draw(in: rect)
                offsetY += heights[index]
            }
        }
    }

    /// Convenience: stitched image encoded as PNG.
    static func pngData(from images: [UIImage]) throws -> Data {
        guard let data = try image(from: images).pngData() else {
            throw ScanSaveError.imageEncodingFailed
        }
        return data
    }
}
