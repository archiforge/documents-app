import SwiftData
import XCTest
@testable import Documents

@MainActor
final class DocumentStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeSourceFile(named name: String, contents: String = "Documents test file") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(relativePath).path)
    }

    // MARK: - Import & duplicate-name dedupe

    func testImportCopiesFileIntoContainerAndCreatesRecord() throws {
        let source = try makeSourceFile(named: "Report.pdf", contents: "%PDF-1.4 fake pdf content")

        let record = try store.importFile(from: source)

        XCTAssertEqual(record.displayName, "Report.pdf")
        XCTAssertEqual(record.kind, .pdf)
        XCTAssertEqual(record.relativePath, "Report.pdf")
        XCTAssertFalse(record.isFavorite)
        XCTAssertFalse(record.isTrashed)
        XCTAssertNil(record.trashedAt)
        XCTAssertEqual(record.sizeBytes, FileBridge.fileSize(at: source))
        XCTAssertGreaterThan(record.sizeBytes, 0)
        XCTAssertTrue(fileExists("Report.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Import must copy, not move")
        XCTAssertEqual(try store.fetchRecent().count, 1)
    }

    func testImportDeduplicatesNames() throws {
        let source = try makeSourceFile(named: "Report.pdf")

        let first = try store.importFile(from: source)
        let second = try store.importFile(from: source)
        let third = try store.importFile(from: source)

        XCTAssertEqual(first.displayName, "Report.pdf")
        XCTAssertEqual(second.displayName, "Report (1).pdf")
        XCTAssertEqual(third.displayName, "Report (2).pdf")

        XCTAssertTrue(fileExists("Report.pdf"))
        XCTAssertTrue(fileExists("Report (1).pdf"))
        XCTAssertTrue(fileExists("Report (2).pdf"))
        XCTAssertEqual(
            Set([first.relativePath, second.relativePath, third.relativePath]).count,
            3,
            "Each import must land in a distinct file"
        )
        XCTAssertEqual(try store.fetchRecent().count, 3)
    }

    // MARK: - Recents ordering

    func testRecentsOrderedByLastOpenedAfterRecordOpen() throws {
        let a = try store.importFile(from: try makeSourceFile(named: "A.txt"))
        let b = try store.importFile(from: try makeSourceFile(named: "B.txt"))
        let c = try store.importFile(from: try makeSourceFile(named: "C.txt"))

        var recents = try store.fetchRecent()
        XCTAssertEqual(recents.map(\.displayName), ["C.txt", "B.txt", "A.txt"])

        let openedBefore = a.lastOpenedAt
        try store.recordOpen(a)

        XCTAssertGreaterThan(a.lastOpenedAt, openedBefore, "recordOpen must touch lastOpenedAt")
        recents = try store.fetchRecent()
        XCTAssertEqual(recents.map(\.displayName), ["A.txt", "C.txt", "B.txt"])
        XCTAssertEqual(recents.map(\.id), [a.id, c.id, b.id])
    }

    // MARK: - Favorites

    func testToggleFavorite() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Notes.md"))

        XCTAssertFalse(record.isFavorite)
        XCTAssertTrue(try store.fetchFavorites().isEmpty)

        try store.toggleFavorite(record)
        XCTAssertTrue(record.isFavorite)
        XCTAssertEqual(try store.fetchFavorites().map(\.id), [record.id])
        XCTAssertEqual(try store.fetchRecent().count, 1, "Favorites stay visible in recents")

        try store.toggleFavorite(record)
        XCTAssertFalse(record.isFavorite)
        XCTAssertTrue(try store.fetchFavorites().isEmpty)
        XCTAssertEqual(try store.fetchRecent().count, 1)
    }

    // MARK: - Trash / restore / delete forever

    func testTrashKeepsFileAndRestoreRecovers() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Keep.pdf"))

        try store.trash(record)
        XCTAssertTrue(record.isTrashed)
        XCTAssertNotNil(record.trashedAt)
        XCTAssertTrue(fileExists("Keep.pdf"), "Trash must keep the file on disk")
        XCTAssertTrue(try store.fetchRecent().isEmpty, "Trashed items leave recents")
        XCTAssertEqual(try store.fetchTrash().map(\.id), [record.id])

        try store.restore(record)
        XCTAssertFalse(record.isTrashed)
        XCTAssertNil(record.trashedAt)
        XCTAssertTrue(fileExists("Keep.pdf"))
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }

    func testDeleteRemovesRecordAndFile() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Gone.pdf"))
        XCTAssertTrue(fileExists("Gone.pdf"))

        try store.delete(record)

        XCTAssertFalse(fileExists("Gone.pdf"), "delete must remove the file from disk")
        XCTAssertTrue(try store.fetchRecent().isEmpty)
        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertEqual(try store.fetchFavorites().count, 0)
    }

    func testDeleteWorksFromTrash() throws {
        let record = try store.importFile(from: makeSourceFile(named: "TrashedFirst.pdf"))

        try store.trash(record)
        try store.delete(record)

        XCTAssertFalse(fileExists("TrashedFirst.pdf"))
        XCTAssertTrue(try store.fetchTrash().isEmpty)
    }

    func testEmptyTrashDeletesOnlyTrashedItems() throws {
        let keep = try store.importFile(from: makeSourceFile(named: "Keep.pdf"))
        let goneA = try store.importFile(from: makeSourceFile(named: "GoneA.pdf"))
        let goneB = try store.importFile(from: makeSourceFile(named: "GoneB.pdf"))

        try store.trash(goneA)
        try store.trash(goneB)

        try store.emptyTrash()

        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertEqual(try store.fetchRecent().map(\.id), [keep.id])
        XCTAssertTrue(fileExists("Keep.pdf"))
        XCTAssertFalse(fileExists("GoneA.pdf"), "emptyTrash must delete trashed files")
        XCTAssertFalse(fileExists("GoneB.pdf"), "emptyTrash must delete trashed files")
    }

    // MARK: - New Document tool backing

    func testCreateDocumentWritesFileAndRecordsIt() throws {
        let record = try store.createDocument(named: "Ideas", fileExtension: "md", contents: "# Ideas\n")

        XCTAssertEqual(record.displayName, "Ideas.md")
        XCTAssertEqual(record.kind, .markdown)
        XCTAssertTrue(fileExists("Ideas.md"))
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }
}
