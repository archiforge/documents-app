import PDFKit
import XCTest
@testable import DocDeck

/// Pure rendering tests for every on-device converter (text/md/html/image
/// → PDF) plus the Phase-2b gating of office sources.
final class ConversionTests: XCTestCase {
    // MARK: - On-device renderers

    func testTextToPDFProducesAtLeastOnePage() throws {
        let data = TextToPDF.pdf(from: "Hello DocDeck\nSecond line")

        XCTAssertGreaterThanOrEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    func testLongTextPaginatesAcrossPages() throws {
        let lines = (1...4000)
            .map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")

        let data = TextToPDF.pdf(from: lines)

        XCTAssertGreaterThan(try PDFToolbox.pageCount(of: data), 1, "Long text must span multiple pages")
    }

    func testMarkdownToPDFProducesAtLeastOnePage() throws {
        let data = MarkdownToPDF.pdf(fromMarkdown: """
        # DocDeck

        - first item
        - second item

        Some *emphasized* text.
        """)

        XCTAssertGreaterThanOrEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    func testMarkdownFallsBackToPlainTextForBadInput() throws {
        let data = MarkdownToPDF.pdf(fromMarkdown: "")

        XCTAssertGreaterThanOrEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    @MainActor
    func testHTMLToPDFProducesAtLeastOnePage() throws {
        let data = HTMLToPDF.pdf(fromHTML: "<h1>DocDeck</h1><p>Hello from HTML.</p>")

        XCTAssertGreaterThanOrEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    func testImageToPDFProducesOnePagePerImage() throws {
        let image = TestPDF.solidImage(size: CGSize(width: 120, height: 160), color: .systemGreen)

        let data = try PDFAssembler.pdfData(from: [image])

        XCTAssertEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    // MARK: - Registry mapping

    func testRegistryMapsOnDeviceSourcesToPDF() {
        XCTAssertNotNil(ConversionRegistry.converter(for: .text, target: .pdf))
        XCTAssertNotNil(ConversionRegistry.converter(for: .markdown, target: .pdf))
        XCTAssertNotNil(ConversionRegistry.converter(for: .html, target: .pdf))
        XCTAssertNotNil(ConversionRegistry.converter(for: .image, target: .pdf))
    }

    func testRegistryLeavesOfficeSourcesAndOfficeTargetsUnmapped() {
        XCTAssertNil(ConversionRegistry.converter(for: .word, target: .pdf))
        XCTAssertNil(ConversionRegistry.converter(for: .excel, target: .pdf))
        XCTAssertNil(ConversionRegistry.converter(for: .powerpoint, target: .pdf))
        XCTAssertNil(ConversionRegistry.converter(for: .pdf, target: .pdf))
        XCTAssertNil(ConversionRegistry.converter(for: .text, target: .word))
        XCTAssertNil(ConversionRegistry.converter(for: .text, target: .excel))
        XCTAssertNil(ConversionRegistry.converter(for: .text, target: .ppt))
    }
}

/// End-to-end conversion through `ConversionRegistry` with real store
/// records, including the Phase-2b pending error for office sources.
@MainActor
final class ConversionRegistryTests: XCTestCase {
    private var createdURLs: [URL] = []
    private var tempOutputDirs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        for url in tempOutputDirs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        tempOutputDirs = []
        super.tearDown()
    }

    private func makeRecord(named name: String, kind: DocumentKind, contents: String) throws -> DocumentRecord {
        let url = FileBridge().absoluteURL(forRelativePath: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        createdURLs.append(url)
        return DocumentRecord(
            displayName: name,
            relativePath: name,
            kind: kind,
            sizeBytes: Int64(contents.utf8.count)
        )
    }

    func testTextRecordConvertsToPDFFile() async throws {
        let record = try makeRecord(named: "ConversionFixture.txt", kind: .text, contents: "Hello DocDeck")

        let outputURL = try await ConversionRegistry.convert(record, to: .pdf)
        tempOutputDirs.append(outputURL.deletingLastPathComponent())

        XCTAssertEqual(outputURL.lastPathComponent, "ConversionFixture.pdf")
        let data = try Data(contentsOf: outputURL)
        XCTAssertGreaterThanOrEqual(try PDFToolbox.pageCount(of: data), 1)
    }

    func testImageRecordConvertsToPDFFile() async throws {
        let image = TestPDF.solidImage(size: CGSize(width: 96, height: 128), color: .systemIndigo)
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))

        let name = "ConversionFixture.jpg"
        let url = FileBridge().absoluteURL(forRelativePath: name)
        try jpeg.write(to: url)
        createdURLs.append(url)
        let record = DocumentRecord(
            displayName: name,
            relativePath: name,
            kind: .image,
            sizeBytes: Int64(jpeg.count)
        )

        let outputURL = try await ConversionRegistry.convert(record, to: .pdf)
        tempOutputDirs.append(outputURL.deletingLastPathComponent())

        XCTAssertEqual(outputURL.lastPathComponent, "ConversionFixture.pdf")
        XCTAssertEqual(try PDFToolbox.pageCount(of: try Data(contentsOf: outputURL)), 1)
    }

    func testOfficeSourceThrowsPendingServiceError() async throws {
        let record = DocumentRecord(
            displayName: "Deck.docx",
            relativePath: "Deck.docx",
            kind: .word,
            sizeBytes: 10
        )

        do {
            _ = try await ConversionRegistry.convert(record, to: .pdf)
            XCTFail("Expected ConversionServiceUnavailableError for an office source")
        } catch let error as ConversionServiceUnavailableError {
            XCTAssertEqual(error.sourceKind, .word)
            XCTAssertEqual(error.target, .pdf)
            XCTAssertTrue(
                (error.errorDescription ?? "").contains("Phase 2b"),
                "The friendly message must point at Phase 2b"
            )
        }
    }
}
