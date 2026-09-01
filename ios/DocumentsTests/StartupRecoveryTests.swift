import SwiftData
import XCTest
@testable import Documents

/// Launch-time reconciliation of the metadata store against the disk.
@MainActor
final class StartupRecoveryTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var cacheDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!
    private var thumbnails: ThumbnailStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        cacheDir = tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, FolderGrant.self, configurations: configuration)
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
        thumbnails = ThumbnailStore(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        cacheDir = nil
        container = nil
        store = nil
        thumbnails = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes `data` into the container Documents directory and adopts it as
    /// an app-owned record.
    @discardableResult
    private func makeRecord(
        named name: String,
        data: Data = Data("Documents test file".utf8)
    ) throws -> DocumentRecord {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let url = documentsDir.appendingPathComponent(name)
        try data.write(to: url)
        return try store.adoptFile(at: url)
    }

    private func deleteFile(named name: String) throws {
        try FileManager.default.removeItem(at: documentsDir.appendingPathComponent(name))
    }

    // MARK: - Disowning records whose file is gone

    func testRecordWithDeletedFileIsDisowned() async throws {
        try makeRecord(named: "Gone.pdf")
        try makeRecord(named: "Keep.pdf")
        try deleteFile(named: "Gone.pdf")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(try store.fetchRecent().map(\.displayName), ["Keep.pdf"])
    }

    func testTrashedRecordWithDeletedFileIsDisowned() async throws {
        let record = try makeRecord(named: "Trashed.pdf")
        try store.trash(record)
        try deleteFile(named: "Trashed.pdf")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertTrue(try store.fetchRecent().isEmpty)
    }

    func testFilePresentRecordsAreUntouched() async throws {
        let first = try makeRecord(named: "A.pdf")
        let second = try makeRecord(named: "B.txt")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(
            Set(try store.fetchRecent().map(\.id)),
            [first.id, second.id]
        )
    }

    func testExternalRecordsWithMissingFilesAreLeftForTheLibrary() async throws {
        let external = tempRoot.appendingPathComponent("External/Missing.pdf")
        try FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("external".utf8).write(to: external)
        let record = try store.adoptFile(at: external, absolutePath: external.path)
        try FileManager.default.removeItem(at: external)

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(
            try store.fetchRecent().map(\.id),
            [record.id],
            "Vanished external files are pruned by the device library, not startup recovery"
        )
    }

    func testSecondRunIsIdempotent() async throws {
        try makeRecord(named: "Gone.pdf")
        try makeRecord(named: "Keep.pdf")
        try deleteFile(named: "Gone.pdf")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)
        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(try store.fetchRecent().map(\.displayName), ["Keep.pdf"])
        XCTAssertTrue(try store.fetchTrash().isEmpty)
    }

    // MARK: - Adoption stays with the device library

    func testOrphanContainerFilesAreNotAdopted() async throws {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: documentsDir.appendingPathComponent("Orphan.pdf"))

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertTrue(
            try store.fetchRecent().isEmpty,
            "Adopting orphan container files is the device library's job, not recovery's"
        )
    }

    // MARK: - Thumbnail sweep wiring

    func testStaleThumbnailEntriesAreSweptAndCurrentOnesKept() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 1))
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let mtime = try XCTUnwrap(
            ThumbnailStore.modificationDate(at: documentsDir.appendingPathComponent("Doc.pdf"))
        )
        let currentKey = ThumbnailStore.entryName(recordID: record.id, mtime: mtime)
        try Data("current".utf8).write(to: cacheDir.appendingPathComponent(currentKey))
        try Data("stale".utf8).write(to: cacheDir.appendingPathComponent("stale-entry-1.png"))

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(Set(entries), [currentKey])
    }

    func testThumbnailEntryForUnstatableFileSurvivesSweep() async throws {
        // A granted-folder record whose file cannot be stat'd yet (security
        // scope not restored at sweep time): unknown ≠ vanished, so its
        // cache entry must survive the sweep.
        let missing = tempRoot.appendingPathComponent("External/Missing.pdf")
        let record = try store.adoptFile(at: missing, absolutePath: missing.path)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let entryName = "\(record.id.uuidString)-12345.png"
        try Data("thumbnail".utf8).write(to: cacheDir.appendingPathComponent(entryName))
        try Data("stale".utf8).write(to: cacheDir.appendingPathComponent("stale-entry-1.png"))

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(Set(entries), [entryName])
        XCTAssertEqual(
            try store.fetchRecent().map(\.id),
            [record.id],
            "Unstatable external records stay until the device library prunes them"
        )
    }

    func testThumbnailEntryForDisownedRecordIsSwept() async throws {
        let record = try makeRecord(named: "Gone.pdf")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let staleKey = ThumbnailStore.entryName(
            recordID: record.id,
            mtime: Date(timeIntervalSince1970: 1_000_000)
        )
        try Data("stale".utf8).write(to: cacheDir.appendingPathComponent(staleKey))
        try deleteFile(named: "Gone.pdf")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Creation-date backfill

    func testNilCreationDateIsBackfilledFromTheFile() async throws {
        let record = try makeRecord(named: "Old.pdf")
        let fileCreation = try XCTUnwrap(
            FileBridge.creationDate(at: documentsDir.appendingPathComponent("Old.pdf"))
        )
        record.createdAt = nil

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        let refetched = try XCTUnwrap(try store.fetchRecent().first)
        XCTAssertEqual(refetched.id, record.id)
        XCTAssertEqual(refetched.createdAt, fileCreation)
    }

    func testKnownCreationDateIsNotOverwritten() async throws {
        let record = try makeRecord(named: "Keep.pdf")
        let sentinel = Date(timeIntervalSince1970: 123_456)
        record.createdAt = sentinel

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(
            try store.fetchRecent().first?.createdAt,
            sentinel,
            "backfill only fills unknown creation dates"
        )
    }

    func testUnstatableFileStaysWithoutCreationDateAndRetriesNextLaunch() async throws {
        let missing = tempRoot.appendingPathComponent("External/Missing.pdf")
        let record = try store.adoptFile(at: missing, absolutePath: missing.path)
        XCTAssertNil(record.createdAt, "adopting a vanished file cannot know its creation date")

        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(
            try store.fetchRecent().first?.createdAt,
            nil,
            "unstatable records keep nil and retry on the next launch"
        )
    }
}
