import SwiftData
import XCTest
@testable import Documents

/// Phase 0 regression: deletion used to go through `relativePath` even for
/// records carrying an `absolutePath`, so deleting an external record could
/// remove a same-named app-container file instead. Deletion must branch on
/// ownership: external records are disowned, app-owned files are removed by
/// their resolved app URL.
@MainActor
final class DocumentStoreOwnershipTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsOwnershipTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(relativePath).path)
    }

    private func writeExternalFile(named name: String, contents: String) throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - App-owned deletion

    func testDeleteRemovesAppOwnedFileByResolvedURL() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Mine.pdf"))

        try store.delete(record)

        XCTAssertFalse(fileExists("Mine.pdf"), "an app-owned record's file must be removed")
        XCTAssertTrue(try store.fetchRecent().isEmpty)
    }

    func testDeleteIsIdempotentWhenFileAlreadyGone() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Vanished.pdf"))
        try FileManager.default.removeItem(at: documentsDir.appendingPathComponent("Vanished.pdf"))

        try store.delete(record)

        XCTAssertTrue(try store.fetchRecent().isEmpty, "deleting a record whose file is gone must still succeed")
    }

    // MARK: - External records are disowned, never deleted by relative path

    func testDeletingExternalRecordNeverTouchesSameNamedAppOwnedFile() throws {
        // The hazard: both records end up with relativePath "Report.pdf".
        let appOwned = try store.importFile(from: makeSourceFile(named: "Report.pdf", contents: "app-owned bytes"))
        let externalURL = try writeExternalFile(named: "Report.pdf", contents: "external bytes")
        let external = try store.adoptFile(
            at: externalURL,
            provenance: .imported,
            absolutePath: externalURL.path
        )
        XCTAssertEqual(external.relativePath, "Report.pdf", "test precondition: the paths collide")

        try store.delete(external)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: externalURL.path),
            "an external file must survive a default delete (disown only)"
        )
        XCTAssertTrue(fileExists("Report.pdf"), "the same-named app-owned file must not be touched")
        XCTAssertEqual(try String(contentsOf: documentsDir.appendingPathComponent("Report.pdf"), encoding: .utf8), "app-owned bytes")
        XCTAssertEqual(try store.fetchRecent().map(\.id), [appOwned.id], "only the external record leaves the index")
    }

    func testEmptyTrashRoutesExternalRecordsThroughDisown() throws {
        let appOwned = try store.importFile(from: makeSourceFile(named: "Shared.pdf", contents: "app-owned bytes"))
        let externalURL = try writeExternalFile(named: "Shared.pdf", contents: "external bytes")
        let external = try store.adoptFile(
            at: externalURL,
            provenance: .imported,
            absolutePath: externalURL.path
        )
        try store.trash(appOwned)
        try store.trash(external)

        try store.emptyTrash()

        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: externalURL.path),
            "emptying the trash must not delete an external file"
        )
        XCTAssertFalse(fileExists("Shared.pdf"), "the app-owned file goes with its record")
    }

    private func makeSourceFile(named name: String, contents: String = "Documents test file") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
