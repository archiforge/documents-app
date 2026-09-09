import CoreGraphics
import CoreText
import Foundation
import PDFKit
import UIKit

/// Errors surfaced by the PDF toolbox operations.
enum PDFToolboxError: LocalizedError, Equatable {
    case unreadablePDF
    case notEnoughDocumentsToMerge
    case invalidPageRange
    case invalidChunkSize
    case emptyWatermarkText
    case invalidPageIndex
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "The file could not be read as a PDF."
        case .notEnoughDocumentsToMerge:
            "Pick at least two PDFs to merge."
        case .invalidPageRange:
            "The page range is outside the document."
        case .invalidChunkSize:
            "The chunk size must be at least one page."
        case .emptyWatermarkText:
            "Enter some watermark text first."
        case .invalidPageIndex:
            "The selected page does not exist in the document."
        case .renderingFailed:
            "The PDF could not be rendered."
        }
    }
}

/// Pure, camera-free PDF toolbox logic.
///
/// Every function takes raw bytes (or URLs of files already on disk) and
/// returns raw bytes, so the whole toolbox is unit-testable without any UI.
/// PDFKit/CG types never escape these functions.
enum PDFToolbox {
    // MARK: - Inspection

    /// Page count of a PDF payload.
    static func pageCount(of data: Data) throws -> Int {
        guard let document = PDFDocument(data: data) else { throw PDFToolboxError.unreadablePDF }
        return document.pageCount
    }

    /// Creates a password-protected copy using PDFKit's native encryption
    /// options. The dedicated helper owns validation and output verification.
    static func encrypt(
        _ data: Data,
        password: String,
        confirmation: String
    ) throws -> Data {
        try PDFPasswordProtection.encrypt(
            data,
            password: password,
            confirmation: confirmation
        )
    }

    // MARK: - Merge

    /// Merges two or more PDFs into a single PDF, preserving page order.
    static func merge(_ sources: [Data]) throws -> Data {
        guard sources.count >= 2 else { throw PDFToolboxError.notEnoughDocumentsToMerge }
        let merged = PDFDocument()
        for source in sources {
            guard let document = PDFDocument(data: source) else { throw PDFToolboxError.unreadablePDF }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    continue
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }
        guard let data = merged.dataRepresentation() else { throw PDFToolboxError.renderingFailed }
        return data
    }

    // MARK: - Split

    /// Extracts an inclusive 1-based page range into a new PDF.
    static func extractRange(_ data: Data, pages range: ClosedRange<Int>) throws -> Data {
        guard let document = PDFDocument(data: data) else { throw PDFToolboxError.unreadablePDF }
        guard range.lowerBound >= 1, range.upperBound <= document.pageCount else {
            throw PDFToolboxError.invalidPageRange
        }
        let output = PDFDocument()
        for number in range {
            guard let page = document.page(at: number - 1), let copy = page.copy() as? PDFPage else {
                continue
            }
            output.insert(copy, at: output.pageCount)
        }
        guard let result = output.dataRepresentation() else { throw PDFToolboxError.renderingFailed }
        return result
    }

    /// Splits a PDF into chunks of `chunkSize` pages (last chunk may be shorter).
    static func splitEvery(_ data: Data, chunkSize: Int) throws -> [Data] {
        guard chunkSize >= 1 else { throw PDFToolboxError.invalidChunkSize }
        let total = try pageCount(of: data)
        guard total > 0 else { throw PDFToolboxError.unreadablePDF }

        var chunks: [Data] = []
        var start = 1
        while start <= total {
            let end = min(start + chunkSize - 1, total)
            chunks.append(try extractRange(data, pages: start...end))
            start = end + 1
        }
        return chunks
    }

    // MARK: - Watermark

    /// Renders a diagonal, tiled, semi-transparent text watermark onto every
    /// page of a NEW PDF. The source bytes are never mutated and each output
    /// page keeps its source page box (Letter stays Letter, A4 stays A4…),
    /// so differently sized or rotated pages are never clipped.
    ///
    /// Built on a raw `CGContext` with a per-page `kCGPDFContextMediaBox`:
    /// `UIGraphicsPDFRenderer` pre-begins its first page at the renderer
    /// bounds, which silently resizes page 1 on mixed-size documents.
    static func watermark(_ data: Data, text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PDFToolboxError.emptyWatermarkText }
        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGPDFDocument(provider),
              source.numberOfPages > 0
        else { throw PDFToolboxError.unreadablePDF }

        let output = NSMutableData()
        guard let firstPage = source.page(at: 1) else { throw PDFToolboxError.renderingFailed }
        var initialBox = firstPage.getBoxRect(.mediaBox)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &initialBox, nil)
        else { throw PDFToolboxError.renderingFailed }

        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { continue }
            let pageRect = page.getBoxRect(.mediaBox)
            context.beginPDFPage([
                kCGPDFContextMediaBox: Self.rectAsCFData(pageRect),
            ] as CFDictionary)
            context.drawPDFPage(page)
            drawWatermark(in: context, pageRect: pageRect, text: trimmed)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Packages a CGRect as `CFData` (stored by value), the documented
    /// value type for `kCGPDFContextMediaBox`/`kCGPDFContextCropBox`.
    private static func rectAsCFData(_ rect: CGRect) -> CFData {
        withUnsafeBytes(of: rect) { Data($0) } as CFData
    }

    private static func drawWatermark(in context: CGContext, pageRect: CGRect, text: String) {
        let fontSize = max(28, min(pageRect.width, pageRect.height) / 12)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let color = CGColor(gray: 0.45, alpha: 0.28)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let tiled = Array(repeating: text, count: 10).joined(separator: "      ")
        guard
            let attributed = CFAttributedStringCreate(nil, tiled as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        context.clip(to: pageRect)
        context.translateBy(x: pageRect.midX, y: pageRect.midY)
        context.rotate(by: .pi / 4)
        context.textMatrix = .identity

        // Tile parallel lines of text across a region large enough to cover
        // the rotated page.
        let extent = max(pageRect.width, pageRect.height) * 1.6
        let step = fontSize * 5
        var y = -extent
        while y <= extent {
            context.textPosition = CGPoint(x: -extent, y: y)
            CTLineDraw(line, context)
            y += step
        }
        context.restoreGState()
    }

    // MARK: - Sign

    /// Stamps an ink image (from PencilKit) onto one page of a NEW PDF,
    /// bottom-right at roughly 30% of the page width. The result is
    /// flattened — no live annotation is left behind — and every output
    /// page keeps its source page box.
    ///
    /// Built on a raw `CGContext` with a per-page `kCGPDFContextMediaBox`
    /// (like `watermark`): `UIGraphicsPDFRenderer` pre-begins its first
    /// page at the renderer bounds, which silently resizes page 1 on
    /// mixed-size documents.
    static func sign(_ data: Data, ink: UIImage, pageIndex: Int) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGPDFDocument(provider),
              source.numberOfPages > 0
        else { throw PDFToolboxError.unreadablePDF }
        guard pageIndex >= 0, pageIndex < source.numberOfPages else { throw PDFToolboxError.invalidPageIndex }
        guard let cgInk = ink.cgImage else { throw PDFToolboxError.renderingFailed }

        let output = NSMutableData()
        guard let firstPage = source.page(at: 1) else { throw PDFToolboxError.renderingFailed }
        var initialBox = firstPage.getBoxRect(.mediaBox)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &initialBox, nil)
        else { throw PDFToolboxError.renderingFailed }

        for index in 0..<source.numberOfPages {
            guard let page = source.page(at: index + 1) else { continue }
            let pageRect = page.getBoxRect(.mediaBox)
            context.beginPDFPage([
                kCGPDFContextMediaBox: Self.rectAsCFData(pageRect),
            ] as CFDictionary)
            context.drawPDFPage(page)

            if index == pageIndex {
                let width = pageRect.width * 0.3
                let aspect = ink.size.height / max(ink.size.width, 1)
                let height = min(width * aspect, pageRect.height * 0.3)
                let inset: CGFloat = 24
                let rect = CGRect(
                    x: pageRect.width - width - inset,
                    y: pageRect.height - height - inset,
                    width: width,
                    height: height
                )
                context.draw(cgInk, in: rect)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    // MARK: - Image extraction

    /// Extracts embedded JPEG (DCTDecode) image streams verbatim from the raw
    /// PDF bytes. Streams with any other filter are skipped.
    ///
    /// `CGPDFStream.copyData()` decodes stream contents, which would destroy
    /// the JPEG encoding, so this walks the raw bytes instead: locate each
    /// `DCTDecode` filter, then slice the following `stream ... endstream`
    /// payload and trim it to the JPEG SOI/EOI markers.
    static func extractJPEGImages(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let filterToken = [UInt8]("DCTDecode".utf8)
        let endstreamToken = [UInt8]("endstream".utf8)
        let streamToken = [UInt8]("stream".utf8)

        var results: [Data] = []
        var cursor = 0
        while let filterRange = range(of: filterToken, in: bytes, from: cursor) {
            cursor = filterRange.upperBound
            guard let dataStart = streamDataStart(after: filterRange.upperBound, token: streamToken, in: bytes),
                  let endRange = range(of: endstreamToken, in: bytes, from: dataStart)
            else { continue }

            var payloadEnd = endRange.lowerBound
            while payloadEnd > dataStart, bytes[payloadEnd - 1] == 0x0A || bytes[payloadEnd - 1] == 0x0D {
                payloadEnd -= 1
            }
            guard payloadEnd > dataStart else { continue }
            let candidate = Data(bytes[dataStart..<payloadEnd])
            if let jpeg = trimmedJPEG(candidate) {
                results.append(jpeg)
            }
        }
        return results
    }

    /// Finds the byte offset where a stream's payload starts after `position`:
    /// the first standalone `stream` keyword (not part of `endstream`),
    /// skipping the mandated end-of-line marker.
    private static func streamDataStart(after position: Int, token: [UInt8], in bytes: [UInt8]) -> Int? {
        var search = position
        while let found = range(of: token, in: bytes, from: search) {
            let isStandalone = found.lowerBound >= 3
                && bytes[found.lowerBound - 3] != UInt8(ascii: "e")
                && bytes[found.lowerBound - 2] != UInt8(ascii: "n")
                && bytes[found.lowerBound - 1] != UInt8(ascii: "d")
            if isStandalone {
                var start = found.upperBound
                if start < bytes.count, bytes[start] == 0x0D { start += 1 }
                if start < bytes.count, bytes[start] == 0x0A { start += 1 }
                return start
            }
            search = found.lowerBound + 1
        }
        return nil
    }

    /// Keeps only a well-formed JPEG payload: must start with the SOI marker;
    /// anything after the final EOI marker is dropped.
    private static func trimmedJPEG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var end = bytes.count
        var index = bytes.count - 2
        while index >= 0 {
            if bytes[index] == 0xFF, bytes[index + 1] == 0xD9 {
                end = index + 2
                break
            }
            index -= 1
        }
        return Data(bytes[0..<end])
    }

    private static func range(of token: [UInt8], in bytes: [UInt8], from start: Int) -> Range<Int>? {
        guard !token.isEmpty, start >= 0, start + token.count <= bytes.count else { return nil }
        var index = start
        while index + token.count <= bytes.count {
            if Array(bytes[index..<index + token.count]) == token {
                return index..<index + token.count
            }
            index += 1
        }
        return nil
    }

    // MARK: - Page rendering (image-extraction fallback)

    /// Renders every page to a PNG (used when a PDF carries no embedded JPEG
    /// images so there is still something to hand back).
    static func renderPagesAsPNG(from data: Data, scale: CGFloat = 2) throws -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGPDFDocument(provider)
        else { throw PDFToolboxError.unreadablePDF }
        var pages: [Data] = []
        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { continue }
            let rect = page.getBoxRect(.mediaBox)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
            let png = renderer.pngData { context in
                let cg = context.cgContext
                cg.translateBy(x: 0, y: rect.size.height)
                cg.scaleBy(x: 1, y: -1)
                cg.drawPDFPage(page)
            }
            pages.append(png)
        }
        return pages
    }
}
