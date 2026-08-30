import SwiftData
import XCTest
@testable import Documents

/// Phase 0 regression: store mutations used to swallow SwiftData failures
/// (`try? context.save()`), letting UI state and disk state diverge.
/// Mutations must surface persistence failures and roll back their
/// in-memory change instead of pretending the save happened.
@MainActor
final class StoreMutationFailureTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsMutationTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Save failures surface instead of being swallowed

    func testTrashSurfacesSaveFailureAndRollsBackInMemoryState() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Poisoned.pdf"))
        failNextSave()

        XCTAssertThrowsError(try store.trash(record), "a failed save must not look like success")
        XCTAssertFalse(record.isTrashed, "failed trash must not leave diverged UI state")
        XCTAssertNil(record.trashedAt)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Poisoned.pdf").path)
        )

        store.saveFailureForTesting = nil
        try store.trash(record)
        XCTAssertTrue(record.isTrashed, "the same mutation must succeed once the failure is cleared")
    }

    func testToggleFavoriteSurfacesSaveFailureAndRollsBack() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Fav.pdf"))
        failNextSave()

        XCTAssertThrowsError(try store.toggleFavorite(record))
        XCTAssertFalse(record.isFavorite, "failed favorite toggle must roll back")

        store.saveFailureForTesting = nil
        try store.toggleFavorite(record)
        XCTAssertTrue(record.isFavorite)
    }

    func testRecordOpenSurfacesSaveFailureAndKeepsPreviousTimestamp() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Open.pdf"))
        let previous = record.lastOpenedAt
        failNextSave()

        XCTAssertThrowsError(try store.recordOpen(record))
        XCTAssertEqual(record.lastOpenedAt, previous, "failed open must keep the old timestamp")

        store.saveFailureForTesting = nil
        try store.recordOpen(record)
        XCTAssertGreaterThan(record.lastOpenedAt, previous)
    }

    func testRestoreSurfacesSaveFailureAndRollsBack() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Restore.pdf"))
        try store.trash(record)
        failNextSave()

        XCTAssertThrowsError(try store.restore(record))
        XCTAssertTrue(record.isTrashed, "failed restore must roll back")

        store.saveFailureForTesting = nil
        try store.restore(record)
        XCTAssertFalse(record.isTrashed)
    }
}
