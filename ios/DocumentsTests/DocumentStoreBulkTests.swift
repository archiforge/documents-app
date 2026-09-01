import SwiftData
import XCTest
@testable import Documents

/// Batch mutations behind the selection-mode bulk bar (board R3.8):
/// `trashAll` and `setFavorite` must apply to every record in one save,
/// surface persistence failures, and revert all touched records — the same
/// guarantees the single-record mutations give (Phase 0 regression class).
@MainActor
final class DocumentStoreBulkTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsBulkTests-\(UUID().uuidString)", isDirectory: true)
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

    private struct InjectedSaveFailure: Error {}

    private func makeSourceFile(named name: String, contents: String = "Documents test file") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func failNextSave() {
        store.saveFailureForTesting = InjectedSaveFailure()
    }

    @discardableResult
    private func importThree() throws -> [DocumentRecord] {
        try [
            store.importFile(from: makeSourceFile(named: "Report.pdf")),
            store.importFile(from: makeSourceFile(named: "Notes.txt")),
            store.importFile(from: makeSourceFile(named: "Sheet.xlsx"))
        ]
    }

    // MARK: - trashAll

    func testTrashAllFlagsEveryRecordAndHidesThemFromRecent() throws {
        let records = try importThree()

        try store.trashAll(records)

        for record in records {
            XCTAssertTrue(record.isTrashed)
            XCTAssertNotNil(record.trashedAt)
        }
        XCTAssertEqual(try store.fetchRecent().count, 0, "Trashed records leave the recent list")
        XCTAssertEqual(try store.fetchTrash().count, 3)
        // Soft trash: the container files themselves stay on disk.
        for record in records {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: store.fileBridge.documentsDirectory
                    .appendingPathComponent(record.relativePath).path)
            )
        }
    }

    func testTrashAllKeepsOriginalTrashedAtForAlreadyTrashedRecords() throws {
        let first = try store.importFile(from: makeSourceFile(named: "Old.pdf"))
        let second = try store.importFile(from: makeSourceFile(named: "New.pdf"))
        let originalDate = Date(timeIntervalSince1970: 1000)
        store.now = { originalDate }
        try store.trash(first)
        let laterDate = Date(timeIntervalSince1970: 2000)
        store.now = { laterDate }

        try store.trashAll([first, second])

        XCTAssertEqual(first.trashedAt, originalDate, "Re-trashing must not restamp the retention clock")
        XCTAssertEqual(second.trashedAt, laterDate)
        XCTAssertTrue(second.isTrashed)
    }

    func testTrashAllRevertsEveryRecordWhenSaveFails() throws {
        let records = try importThree()

        failNextSave()
        XCTAssertThrowsError(try store.trashAll(records))

        for record in records {
            XCTAssertFalse(record.isTrashed)
            XCTAssertNil(record.trashedAt)
        }
        XCTAssertEqual(try store.fetchRecent().count, 3)
    }

    func testTrashAllLeavesIndexedExternalFilesUntouched() throws {
        let source = try makeSourceFile(named: "External.pdf", contents: "external content")
        let record = try store.adoptFile(at: source, absolutePath: source.path)

        try store.trashAll([record])

        XCTAssertTrue(record.isTrashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "Trash never deletes files; indexed externals only leave the index when purged")
    }

    // MARK: - setFavorite

    func testSetFavoriteSetsFlagOnEveryRecord() throws {
        let records = try importThree()
        try store.toggleFavorite(records[0])

        try store.setFavorite(records, to: true)
        XCTAssertTrue(records.allSatisfy(\.isFavorite))

        try store.setFavorite(records, to: false)
        XCTAssertTrue(records.allSatisfy { !$0.isFavorite })
    }

    func testSetFavoriteRevertsEveryRecordWhenSaveFails() throws {
        let records = try importThree()
        try store.toggleFavorite(records[0])

        failNextSave()
        XCTAssertThrowsError(try store.setFavorite(records, to: false))

        XCTAssertTrue(records[0].isFavorite, "Previously favorite record keeps its flag")
        XCTAssertTrue(records.dropFirst().allSatisfy { !$0.isFavorite })
    }
}
