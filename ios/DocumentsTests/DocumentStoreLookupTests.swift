import SwiftData
import XCTest
@testable import Documents

/// Browse lookups are keyed by container-relative paths. External records can
/// carry the same basename, but must never satisfy a container-file lookup.
@MainActor
final class DocumentStoreLookupTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsLookupTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        sourcesDir = tempRoot.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, configurations: configuration)
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        sourcesDir = nil
        container = nil
        store = nil
        try await super.tearDown()
    }

    private func makeSourceFile(named name: String, contents: String = "Documents test file") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRecordForRelativePathReturnsOwnedRecordWhenExternalRecordSharesName() throws {
        let owned = try store.importFile(from: makeSourceFile(named: "Report.pdf", contents: "owned"))
        let externalURL = tempRoot.appendingPathComponent("External", isDirectory: true)
            .appendingPathComponent("Report.pdf")
        try FileManager.default.createDirectory(
            at: externalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "external".write(to: externalURL, atomically: true, encoding: .utf8)
        let external = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)

        XCTAssertEqual(external.relativePath, owned.relativePath)
        XCTAssertEqual(try store.record(forRelativePath: "Report.pdf")?.id, owned.id)
    }

    func testRecordForRelativePathExcludesExternalOnlyRecord() throws {
        let externalURL = try makeSourceFile(named: "Granted.pdf")
        let external = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)

        XCTAssertNil(try store.record(forRelativePath: external.relativePath))
    }

    func testRecordForRelativePathReturnsOwnedRecord() throws {
        let owned = try store.importFile(from: makeSourceFile(named: "Owned.pdf"))

        XCTAssertEqual(try store.record(forRelativePath: owned.relativePath)?.id, owned.id)
    }

    func testRecordForRelativePathReturnsNilForNonexistentPath() throws {
        XCTAssertNil(try store.record(forRelativePath: "Missing.pdf"))
    }
}
