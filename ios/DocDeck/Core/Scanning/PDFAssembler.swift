import UIKit

enum PDFAssemblerError: LocalizedError {
    case noImages

    var errorDescription: String? {
        switch self {
        case .noImages: "There are no pages to assemble."
        }
    }
}

/// Turns a list of scanned page images into a PDF — one page per image,
/// each page sized to its image. Pure logic so scanner flows can be tested
/// without a camera.
enum PDFAssembler {
    static func pdfData(from images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw PDFAssemblerError.noImages }

        let maxSize = images.reduce(CGSize.zero) { partial, image in
            CGSize(
                width: max(partial.width, image.size.width),
                height: max(partial.height, image.size.height)
            )
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: maxSize))
        return renderer.pdfData { context in
            for image in images {
                let pageRect = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: pageRect, pageInfo: [:])
                image.draw(in: pageRect)
            }
        }
    }
}
