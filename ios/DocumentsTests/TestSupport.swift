import UIKit

/// Shared factories for hermetic tests: synthesized PDFs, solid-color
/// images, and text images for OCR. Everything is generated in-test, so the
/// suite never depends on bundled fixtures.
enum TestPDF {
    static let defaultPageSize = CGSize(width: 612, height: 792)

    /// A real, renderable PDF with `pageCount` pages; each page carries a
    /// visible "Page N" label so page identity survives round-trips.
    static func make(pageCount: Int, pageSize: CGSize = defaultPageSize) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 24),
                    .foregroundColor: UIColor.black,
                ]
                ("Page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: attributes
                )
            }
        }
    }

    static func solidImage(size: CGSize, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// High-contrast text image sized for reliable on-device OCR.
    static func textImage(_ text: String) -> UIImage {
        let size = CGSize(width: 720, height: 240)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(at: CGPoint(x: 24, y: 84), withAttributes: attributes)
        }
    }
}
