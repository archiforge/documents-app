import PDFKit
import SwiftData
import XCTest
@testable import Documents

@MainActor
final class OfficeConversionAuditTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!
    private let sourceBytes = Data("{\\rtf1 Synthetic conversion audit}".utf8)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeAudit-\(UUID())")
        container = try ModelContainer(
            for: DocumentRecord.self, FolderGrant.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = DocumentStore(context: container.mainContext, fileBridge: FileBridge(documentsDirectory: root))
    }

    override func tearDown() async throws {
        store = nil
        container = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOfficeSuccessReadsInjectedRootAndPreservesOriginal() async throws {
        let source = try store.saveGeneratedFile(name: "source.rtf", data: sourceBytes)
        let output = TestPDF.make(pageCount: 1)
        let client = AuditOfficeClient(output: output)
        let result = try await ConversionCoordinator.convert(source, to: .pdf, store: store, officeClient: client)
        let captured = await client.lastInput
        XCTAssertEqual(captured, sourceBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(result.relativePath)), output)
        XCTAssertNotEqual(result.id, source.id)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<DocumentRecord>()), 2)
    }

    func testLateCancelledOfficeResponseCannotSave() async throws {
        let source = try store.saveGeneratedFile(name: "source.rtf", data: sourceBytes)
        let client = AuditOfficeClient(output: TestPDF.make(pageCount: 1), suspended: true)
        let operation = Task {
            _ = try await ConversionCoordinator.convert(source, to: .pdf, store: store, officeClient: client)
        }
        await client.waitUntilStarted()
        operation.cancel()
        await client.release()
        do {
            _ = try await operation.value
            XCTFail("A cancelled conversion must not save a late response")
        } catch is CancellationError {}
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<DocumentRecord>()), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("converted.pdf").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), sourceBytes)
    }

    func testFailedOfficeSaveRollsBackOutputAndKeepsSource() async throws {
        let source = try store.saveGeneratedFile(name: "source.rtf", data: sourceBytes)
        store.saveFailureForTesting = AuditSaveError()
        do {
            _ = try await ConversionCoordinator.convert(source, to: .pdf, store: store,
                officeClient: AuditOfficeClient(output: TestPDF.make(pageCount: 1)))
            XCTFail("Injected persistence failure must propagate")
        } catch is AuditSaveError {}
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<DocumentRecord>()), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("converted.pdf").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), sourceBytes)
    }

    func testExternalOfficeSourceWithoutGrantNeverReachesService() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.rtf")
        try sourceBytes.write(to: external)
        let source = try store.adoptFile(at: external, absolutePath: external.path)
        let client = AuditOfficeClient(output: TestPDF.make(pageCount: 1))
        do {
            _ = try await ConversionCoordinator.convert(source, to: .pdf, store: store, officeClient: client)
            XCTFail("Cached absolute paths are not permission")
        } catch is DocumentSourceAccessError {}
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testLocalPDFConversionUsesInjectedSourceRoot() async throws {
        let source = try store.saveGeneratedFile(name: "local.txt", data: Data("Local PDF audit".utf8))
        let result = try await ConversionCoordinator.convert(source, to: .pdf, store: store)
        let data = try Data(contentsOf: root.appendingPathComponent(result.relativePath))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
        XCTAssertTrue(PDFDocument(data: data)?.string?.contains("Local PDF audit") == true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source.relativePath)), Data("Local PDF audit".utf8))
    }
}

private struct AuditSaveError: Error {}

private actor AuditOfficeClient: OfficeConversionServicing {
    let output: Data
    let suspended: Bool
    private(set) var calls = 0
    private(set) var lastInput: Data?
    private var waiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    init(output: Data, suspended: Bool = false) {
        self.output = output
        self.suspended = suspended
    }

    func fetchCapabilities(forceRefresh: Bool) async throws -> OfficeCapabilities {
        throw OfficeConversionError.serviceUnavailable
    }

    func convert(data: Data, filename: String, sourceExtension: String, target: ConversionTarget) async throws -> OfficeConversionResponse {
        calls += 1
        lastInput = data
        if suspended {
            await withCheckedContinuation { continuation in
                waiter = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        return OfficeConversionResponse(data: output, filename: "converted.pdf", target: target)
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
