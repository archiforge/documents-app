import UIKit

/// HTML → PDF via WebKit's markup print formatter.
///
/// `UIMarkupTextPrintFormatter`/`UIPrintPageRenderer` are main-actor types,
/// so this runs on the main actor by design.
@MainActor
enum HTMLToPDF {
    static let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let insets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)

    static func pdf(fromHTML html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = insets

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: pageSize), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: pageSize.inset(by: insets)), forKey: "printableRect")
        let pages = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageSize)
        return pdfRenderer.pdfData { context in
            for pageIndex in 0..<pages {
                context.beginPage()
                renderer.drawPage(at: pageIndex, in: pageSize)
            }
        }
    }
}
