import SwiftData
import XCTest
@testable import Documents

/// `DocumentStore.duplicate` must produce an independent copy: a second
/// tracked file with a deduped name, leaving the original untouched.
@MainActor
final class DocumentStoreDuplicateTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsDuplicateTests-\(UUID().uuidString)", isDirectory: true)
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

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        sourcesDir = nil
        container = nil
        store = nil
        super.tearDown()
    }

    private struct InjectedSaveFailure: Error {}

    private func makeSourceFile(named name: String, contents: String = "duplicate me") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func allRecords() throws -> [DocumentRecord] {
        try store.context.fetch(FetchDescriptor<DocumentRecord>())
    }

    func testDuplicateCreatesIndependentRecordAndFile() throws {
        let original = try store.importFile(from: makeSourceFile(named: "Report.pdf", contents: "v1"))

        let copy = try store.duplicate(original)

        XCTAssertEqual(copy.displayName, "Report (1).pdf")
        XCTAssertEqual(copy.kind, original.kind)
        XCTAssertEqual(copy.provenance, original.provenance)
        XCTAssertFalse(copy.isFavorite)
        XCTAssertFalse(copy.isTrashed)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(try allRecords().count, 2)

        // Both files exist and are independent: rewriting the copy leaves
        // the original's bytes alone.
        let originalURL = documentsDir.appendingPathComponent("Report.pdf")
        let copyURL = documentsDir.appendingPathComponent("Report (1).pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        try "v2".data(using: .utf8)!.write(to: copyURL)
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "v1")
    }

    func testDuplicateDedupesRepeatedly() throws {
        let original = try store.importFile(from: makeSourceFile(named: "Notes.txt"))

        _ = try store.duplicate(original)
        let second = try store.duplicate(original)

        XCTAssertEqual(second.displayName, "Notes (2).txt")
        XCTAssertEqual(try allRecords().count, 3)
    }

    func testDuplicateOfExternalRecordCopiesIntoContainerWithoutTouchingSource() throws {
        let sourceURL = try makeSourceFile(named: "Granted.md", contents: "external bytes")
        let external = try store.adoptFile(at: sourceURL, provenance: .device, absolutePath: sourceURL.path)

        let copy = try store.duplicate(external)

        XCTAssertNil(copy.absolutePath)
        XCTAssertEqual(copy.displayName, "Granted.md")
        XCTAssertEqual(copy.relativePath, "Granted.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Granted.md").path))
        // The indexed source is still there and unchanged.
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "external bytes")
    }

    func testFailedSaveRollsBackRecordAndFile() throws {
        let original = try store.importFile(from: makeSourceFile(named: "Ghost.pdf"))
        store.saveFailureForTesting = InjectedSaveFailure()

        XCTAssertThrowsError(try store.duplicate(original))

        store.saveFailureForTesting = nil
        XCTAssertEqual(try allRecords().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Ghost (1).pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Ghost.pdf").path))
    }
}
