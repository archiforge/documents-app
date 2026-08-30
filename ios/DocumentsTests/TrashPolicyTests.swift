import Foundation
import SwiftData
import XCTest
@testable import Documents

/// Trash retention rules: documents stay in the trash for 30 days, then the
/// store purges them on launch. The boundary is exact — a record trashed
/// precisely 30 days ago survives one more purge pass. The store's injected
/// clock must drive every decision so tests are deterministic.
@MainActor
final class TrashPolicyTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    /// Fixed "now" for the injected clock. Deliberately far from the wall
    /// clock so tests relying on it cannot pass by accident.
    private let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsTrashTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        sourcesDir = tempRoot.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, configurations: configuration)
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
        store.now = { [baseDate] in baseDate }
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

    private func makeSourceFile(named name: String) throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try "Documents test file".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(relativePath).path)
    }

    private func setClock(_ date: Date) {
        store.now = { date }
    }

    private func days(_ count: Double) -> TimeInterval {
        count * 86_400
    }

    // MARK: - Policy math

    func testPurgeDateIsThirtyDaysAfterTrashedAt() {
        let trashedAt = baseDate
        XCTAssertEqual(
            TrashPolicy.purgeDate(trashedAt: trashedAt),
            trashedAt.addingTimeInterval(days(30))
        )
    }

    func testRemainingDaysCountsUpToPurgeAndNeverGoesNegative() {
        XCTAssertEqual(TrashPolicy.remainingDays(trashedAt: baseDate, now: baseDate), 30)
        XCTAssertEqual(TrashPolicy.remainingDays(trashedAt: baseDate, now: baseDate.addingTimeInterval(days(29))), 1)
        XCTAssertEqual(TrashPolicy.remainingDays(trashedAt: baseDate, now: baseDate.addingTimeInterval(days(30) - 1)), 1)
        XCTAssertEqual(TrashPolicy.remainingDays(trashedAt: baseDate, now: baseDate.addingTimeInterval(days(30))), 0)
        XCTAssertEqual(TrashPolicy.remainingDays(trashedAt: baseDate, now: baseDate.addingTimeInterval(days(31))), 0)
    }

    // MARK: - Purge boundary

    func testTrashExactlyAtRetentionBoundarySurvivesThenOneSecondLaterPurges() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Edge.pdf"))

        setClock(baseDate.addingTimeInterval(-days(30)))
        try store.trash(record)

        setClock(baseDate)
        XCTAssertEqual(try store.purgeExpiredTrash(), 0, "exactly 30 days old must survive")
        XCTAssertEqual(try store.fetchTrash().map(\.id), [record.id])
        XCTAssertTrue(fileExists("Edge.pdf"))

        setClock(baseDate.addingTimeInterval(1))
        XCTAssertEqual(try store.purgeExpiredTrash(), 1, "30 days + 1s must purge")
        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertFalse(fileExists("Edge.pdf"))
    }

    func testPurgeRemovesOnlyExpiredTrash() throws {
        let expired = try store.importFile(from: makeSourceFile(named: "Expired.pdf"))
        let boundary = try store.importFile(from: makeSourceFile(named: "Boundary.pdf"))
        let young = try store.importFile(from: makeSourceFile(named: "Young.pdf"))
        let kept = try store.importFile(from: makeSourceFile(named: "Kept.pdf"))

        setClock(baseDate.addingTimeInterval(-days(31)))
        try store.trash(expired)
        setClock(baseDate.addingTimeInterval(-days(30)))
        try store.trash(boundary)
        setClock(baseDate.addingTimeInterval(-days(1)))
        try store.trash(young)
        setClock(baseDate)

        XCTAssertEqual(try store.purgeExpiredTrash(), 1)

        XCTAssertEqual(try store.fetchTrash().map(\.id).sorted(), [boundary.id, young.id].sorted())
        XCTAssertFalse(fileExists("Expired.pdf"), "purged app-owned files leave disk")
        XCTAssertTrue(fileExists("Boundary.pdf"))
        XCTAssertTrue(fileExists("Young.pdf"))
        XCTAssertTrue(fileExists("Kept.pdf"))
        XCTAssertEqual(try store.fetchRecent().map(\.id), [kept.id], "non-trashed records are untouched")
    }

    func testPurgeRemovesLegacyTrashedRowWithoutDate() throws {
        let legacy = try store.importFile(from: makeSourceFile(named: "Legacy.pdf"))
        // Simulate a pre-retention row: trashed with no trashedAt recorded.
        legacy.isTrashed = true
        try store.context.save()

        XCTAssertEqual(try store.purgeExpiredTrash(), 1, "nil trashedAt counts as expired")
        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertFalse(fileExists("Legacy.pdf"))
    }

    // MARK: - Injected clock

    func testPurgeHonorsInjectedClockInsteadOfWallClock() throws {
        // baseDate is far in the past relative to the wall clock: if purge
        // used Date.now the record would look ancient and get removed.
        let record = try store.importFile(from: makeSourceFile(named: "Frozen.pdf"))
        try store.trash(record)

        XCTAssertEqual(try store.purgeExpiredTrash(), 0, "the injected clock must decide expiry")
        XCTAssertEqual(try store.fetchTrash().map(\.id), [record.id])

        setClock(baseDate.addingTimeInterval(days(30) + 1))
        XCTAssertEqual(try store.purgeExpiredTrash(), 1)
    }

    func testTrashUsesInjectedClock() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Stamped.pdf"))

        try store.trash(record)

        XCTAssertEqual(record.trashedAt, baseDate)
    }

    // MARK: - Ownership

    func testPurgeDisownsExpiredExternalRecordWithoutDeletingItsFile() throws {
        let externalURL = sourcesDir.appendingPathComponent("External.pdf")
        try "external bytes".write(to: externalURL, atomically: true, encoding: .utf8)
        let external = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)
        try store.trash(external)

        setClock(baseDate.addingTimeInterval(days(31)))
        XCTAssertEqual(try store.purgeExpiredTrash(), 1)

        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: externalURL.path),
            "purge must never delete a file outside the app container"
        )
    }
}
