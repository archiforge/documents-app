import Foundation
import PDFKit
import XCTest
import ZIPFoundation
@testable import Documents

/// Pure rendering tests for every on-device converter (text/md/html/image
/// → PDF) plus the local/service conversion boundary.
final class ConversionTests: XCTestCase {
    // MARK: - On-device renderers

    func testTextToPDFProducesAtLeastOnePage() throws {
        let data = TextToPDF.pdf(from: "Hello Documents\nSecond line")

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
        # Documents

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
        let data = HTMLToPDF.pdf(fromHTML: "<h1>Documents</h1><p>Hello from HTML.</p>")

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

    func testOfficeMatrixMapsApprovedExtensionsAndRejectsNoOpFormats() {
        XCTAssertEqual(DocumentKind(filename: "notes.odt"), .word)
        XCTAssertEqual(DocumentKind(filename: "budget.ods"), .excel)
        XCTAssertEqual(DocumentKind(filename: "slides.odp"), .powerpoint)
        XCTAssertTrue(OfficeConversionMatrix.supports(sourceExtension: "odt", target: .pdf))
        XCTAssertTrue(OfficeConversionMatrix.supports(sourceExtension: "ods", target: .excel))
        XCTAssertTrue(OfficeConversionMatrix.supports(sourceExtension: "odp", target: .ppt))
        XCTAssertFalse(OfficeConversionMatrix.supports(sourceExtension: "docx", target: .word))
        XCTAssertFalse(OfficeConversionMatrix.supports(sourceExtension: "pdf", target: .word))
    }

    func testAvailabilityMatchesLocalAndConfiguredServiceBoundaries() {
        XCTAssertTrue(ConversionTarget.pdf.availability(for: .text).isAvailable)
        XCTAssertTrue(ConversionTarget.pdf.availability(for: .markdown).isAvailable)
        XCTAssertTrue(ConversionTarget.pdf.availability(for: .html).isAvailable)
        XCTAssertTrue(ConversionTarget.pdf.availability(for: .image).isAvailable)
        XCTAssertTrue(ConversionTarget.pdf.availability(for: .word).isAvailable)
        XCTAssertTrue(ConversionTarget.word.availability(for: .text).isAvailable)
        XCTAssertEqual(ConversionTarget.excel.availability(for: .word), .unavailable(.unsupportedOfficeCombination))
        XCTAssertEqual(ConversionTarget.pdf.availability(for: .pdf), .unavailable(.sourceNeedsLocalPDFInput))
        XCTAssertEqual(
            ConversionTarget.word.availability(for: .word, sourceExtension: "docx"),
            .unavailable(.unsupportedOfficeCombination)
        )
    }

    func testOfficeConfigurationRejectsCredentialAndQueryEndpoints() {
        XCTAssertFalse(OfficeConversionConfiguration.isValidEndpoint(URL(string: "http://conversion.example")!))
        XCTAssertFalse(OfficeConversionConfiguration.isValidEndpoint(URL(string: "https://user:pass@conversion.example")!))
        XCTAssertFalse(OfficeConversionConfiguration.isValidEndpoint(URL(string: "https://conversion.example?token=secret")!))
        XCTAssertFalse(OfficeConversionConfiguration.isValidEndpoint(URL(string: "https://conversion.example/#fragment")!))
        XCTAssertTrue(OfficeConversionConfiguration.isValidEndpoint(URL(string: "https://conversion.example/office")!))
    }

    func testOfficePdfOutputValidatorRejectsMalformedBody() throws {
        let valid = TestPDF.make(pageCount: 1)
        try OfficeOutputValidator.validate(valid, target: .pdf)
        XCTAssertThrowsError(try OfficeOutputValidator.validate(Data("%PDF-1.7\n%%EOF".utf8), target: .pdf))
    }

    func testOfficeClientUsesInjectedURLSessionConfiguration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficeClientURLProtocol.self]
        OfficeClientURLProtocol.setResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("""
            {"schemaVersion":"1","serviceBuild":"test","ready":true,
             "sources":[{"extension":"docx","targets":["pdf"]}],
             "targetMediaTypes":{"pdf":"application/pdf"},
             "limits":{"maxInputBytes":52428800,"maxOutputBytes":104857600,
             "timeoutSeconds":120,"maxConcurrentJobs":2}}
            """.utf8)
        )
        let client = OfficeConversionClient(
            configuration: OfficeConversionConfiguration(endpoint: URL(string: "https://conversion.example")!),
            sessionConfiguration: configuration
        )

        let capabilities = try await client.fetchCapabilities(forceRefresh: true)

        XCTAssertTrue(capabilities.ready)
        XCTAssertTrue(capabilities.supports(sourceExtension: "docx", target: .pdf))
        XCTAssertEqual(OfficeClientURLProtocol.lastRequestMethod, "GET")
    }

    func testOfficeClientRejectsNegativeContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficeClientURLProtocol.self]
        OfficeClientURLProtocol.setResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "Content-Length": "-1"],
            body: Data("{}".utf8)
        )
        let client = OfficeConversionClient(
            configuration: OfficeConversionConfiguration(endpoint: URL(string: "https://conversion.example")!),
            sessionConfiguration: configuration
        )

        do {
            _ = try await client.fetchCapabilities(forceRefresh: true)
            XCTFail("Negative Content-Length must be rejected")
        } catch let error as OfficeConversionError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testOfficeZipValidatorChecksXmlCrcAndExternalRelationships() throws {
        let valid = try makeOfficeArchive([
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
            ("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>"),
            ("word/_rels/document.xml.rels", """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
                    Target="https://example.test" TargetMode="External"/>
                </Relationships>
                """)
        ])
        try OfficeOutputValidator.validate(valid, target: .word)

        let malformed = try makeOfficeArchive([
            ("[Content_Types].xml", "not xml"),
            ("word/document.xml", "<w:document/>",)
        ])
        XCTAssertThrowsError(try OfficeOutputValidator.validate(malformed, target: .word))

        let externalObject = try makeOfficeArchive([
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>"),
            ("word/_rels/document.xml.rels", """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject"
                    Target="https://example.test/payload" TargetMode="External"/>
                </Relationships>
                """)
        ])
        XCTAssertThrowsError(try OfficeOutputValidator.validate(externalObject, target: .word))
    }

    private func makeOfficeArchive(_ entries: [(String, String)]) throws -> Data {
        let archive = try XCTUnwrap(Archive(data: Data(), accessMode: .create))
        for (path, string) in entries {
            let payload = Data(string.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(payload.count),
                compressionMethod: .none,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, payload.count)
                    guard start < end else { return Data() }
                    return payload.subdata(in: start..<end)
                }
            )
        }
        return try XCTUnwrap(archive.data)
    }
}

private final class OfficeClientURLProtocol: URLProtocol {
    private static let state = OfficeClientURLProtocolState()

    static var lastRequestMethod: String? {
        state.lastRequestMethod
    }

    static func setResponse(statusCode: Int, headers: [String: String], body: Data) {
        state.setResponse(statusCode: statusCode, headers: headers, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let configured = Self.state.response
        Self.state.record(request: request)
        guard let configured,
              let response = HTTPURLResponse(
                  url: request.url!,
                  statusCode: configured.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: configured.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The URLProtocol callback can run off the XCTest actor. All mutable
/// fixture state is behind a lock and the reference itself is Sendable.
private final class OfficeClientURLProtocolState: @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var storedResponse: Response?
    private var storedRequestMethod: String?

    var response: Response? {
        lock.lock()
        defer { lock.unlock() }
        return storedResponse
    }

    var lastRequestMethod: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestMethod
    }

    func setResponse(statusCode: Int, headers: [String: String], body: Data) {
        lock.lock()
        storedResponse = Response(statusCode: statusCode, headers: headers, body: body)
        storedRequestMethod = nil
        lock.unlock()
    }

    func record(request: URLRequest) {
        lock.lock()
        storedRequestMethod = request.httpMethod
        lock.unlock()
    }
}

/// End-to-end conversion through `ConversionRegistry` with real store
/// records, including the local registry's deliberate Office fallback.
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
        let record = try makeRecord(named: "ConversionFixture.txt", kind: .text, contents: "Hello Documents")

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

    func testOfficeSourceRequiresServiceWhenUsingLocalRegistryFallback() async throws {
        let record = DocumentRecord(
            displayName: "Deck.docx",
            relativePath: "Deck.docx",
            kind: .word,
            sizeBytes: 10
        )

        do {
            _ = try await ConversionRegistry.convert(record, to: .pdf)
            XCTFail("Expected ConversionServiceUnavailableError for an Office source")
        } catch let error as ConversionServiceUnavailableError {
            XCTAssertEqual(error.sourceKind, .word)
            XCTAssertEqual(error.target, .pdf)
            XCTAssertTrue((error.errorDescription ?? "").contains("Office conversion service"))
        }
    }
}
