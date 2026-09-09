import SwiftData
import XCTest
@testable import Documents

@MainActor
final class DocumentStoreFolderTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsFolderTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: DocumentRecord.self,
            FolderGrant.self,
            configurations: configuration
        )
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        container = nil
        store = nil
        try await super.tearDown()
    }

    @discardableResult
    private func makeOwned(
        named name: String,
        data: Data = Data("folder test".utf8)
    ) throws -> DocumentRecord {
        let url = documentsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return try store.adoptFile(at: url)
    }

    func testCreateFolderAndNestedFolder() throws {
        let reports = try store.createFolder(named: "Reports")
        let year = try store.createFolder(named: "2026", inRelativePath: reports)

        XCTAssertEqual(reports, "Reports")
        XCTAssertEqual(year, "Reports/2026")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(year).path))
    }

    func testFolderValidationRejectsTraversalAndHiddenNames() throws {
        XCTAssertThrowsError(try store.createFolder(named: "../Outside"))
        XCTAssertThrowsError(try store.createFolder(named: ".Hidden"))
        XCTAssertThrowsError(try store.createFolder(named: "Child", inRelativePath: "../Outside"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("Outside").path))
    }

    func testFolderOperationsRejectSymlinkEscape() throws {
        let outside = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let link = documentsDir.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try store.createFolder(named: "Child", inRelativePath: "Link"))
        let record = try makeOwned(named: "Report.pdf")
        XCTAssertThrowsError(try store.move(record, toRelativeFolder: "Link"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Child").path))
    }

    func testMoveUpdatesNestedRelativePathAndPreservesBytes() throws {
        _ = try store.createFolder(named: "Reports")
        _ = try store.createFolder(named: "2026", inRelativePath: "Reports")
        let payload = Data("nested move".utf8)
        let record = try makeOwned(named: "Report.pdf", data: payload)

        try store.move(record, toRelativeFolder: "Reports/2026")

        XCTAssertEqual(record.relativePath, "Reports/2026/Report.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Report.pdf").path))
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent(record.relativePath)),
            payload
        )
        XCTAssertEqual(try store.record(forRelativePath: record.relativePath)?.id, record.id)
    }

    func testMoveAllowsHiddenFinalFilenameAndRollsBackSaveFailure() throws {
        _ = try store.createFolder(named: "Reports")
        _ = try store.createFolder(named: "Archive")
        let payload = Data("hidden move".utf8)
        let record = try makeOwned(named: ".Notes.txt", data: payload)

        try store.move(record, toRelativeFolder: "Reports")

        XCTAssertEqual(record.relativePath, "Reports/.Notes.txt")
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent(record.relativePath)),
            payload
        )

        store.saveFailureForTesting = TestSaveFailure()
        XCTAssertThrowsError(try store.move(record, toRelativeFolder: "Archive"))

        XCTAssertEqual(record.relativePath, "Reports/.Notes.txt")
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent("Reports/.Notes.txt")),
            payload
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent("Archive/.Notes.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent(".document-move-journal").path
            )
        )
    }

    func testImportIntoNestedFolderRecordsDestinationAndPreservesSource() throws {
        _ = try store.createFolder(named: "Reports")
        _ = try store.createFolder(named: "2026", inRelativePath: "Reports")
        let sourceURL = tempRoot.appendingPathComponent("Picked.txt")
        let payload = Data("picked bytes".utf8)
        try payload.write(to: sourceURL)

        let record = try store.importFile(
            from: sourceURL,
            intoRelativeFolder: "Reports/2026"
        )

        XCTAssertEqual(record.relativePath, "Reports/2026/Picked.txt")
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent(record.relativePath)),
            payload
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), payload)
    }

    func testImportIntoNestedFolderRemovesCopyWhenMetadataSaveFails() throws {
        _ = try store.createFolder(named: "Reports")
        let sourceURL = tempRoot.appendingPathComponent("Picked.txt")
        try Data("picked bytes".utf8).write(to: sourceURL)
        store.saveFailureForTesting = TestSaveFailure()

        XCTAssertThrowsError(
            try store.importFile(from: sourceURL, intoRelativeFolder: "Reports")
        )

        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("picked bytes".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent("Reports/Picked.txt").path
            )
        )
        XCTAssertTrue(try store.fetchRecent().isEmpty)
    }

    func testMoveRejectsOccupiedDestinationWithoutChangingSource() throws {
        _ = try store.createFolder(named: "Reports")
        let record = try makeOwned(named: "Report.pdf", data: Data("source".utf8))
        let occupied = documentsDir.appendingPathComponent("Reports/Report.pdf")
        try Data("existing".utf8).write(to: occupied)

        XCTAssertThrowsError(try store.move(record, toRelativeFolder: "Reports")) { error in
            XCTAssertEqual(
                error as? FileBridgeFolderError,
                .destinationOccupied("Reports/Report.pdf")
            )
        }
        XCTAssertEqual(record.relativePath, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: documentsDir.appendingPathComponent("Report.pdf")), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing".utf8))
    }

    func testMoveRejectsExternalRecordAndPreservesSource() throws {
        let externalURL = tempRoot.appendingPathComponent("Granted/Report.pdf")
        try FileManager.default.createDirectory(
            at: externalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data("external".utf8)
        try payload.write(to: externalURL)
        let record = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)
        _ = try store.createFolder(named: "Reports")

        XCTAssertThrowsError(try store.move(record, toRelativeFolder: "Reports")) { error in
            XCTAssertEqual(error as? DocumentMoveError, .externalFileNotMovable)
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Reports/Report.pdf").path))
    }

    func testExternalRecordLookupUsesCanonicalPathForRepeatedAdoption() throws {
        let externalURL = tempRoot.appendingPathComponent("Granted/Report.pdf")
        try FileManager.default.createDirectory(
            at: externalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("external".utf8).write(to: externalURL)
        let nested = externalURL.deletingLastPathComponent().appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let aliasedPath = nested.appendingPathComponent("../Report.pdf").path
        let first = try store.adoptFile(
            at: externalURL,
            absolutePath: aliasedPath
        )

        let existing = try XCTUnwrap(store.record(forAbsolutePath: externalURL.path))
        XCTAssertEqual(existing.id, first.id)
        XCTAssertEqual(try store.fetchRecent().filter { $0.absolutePath != nil }.count, 1)
    }

    func testMoveRollsBackFileAndMetadataWhenSaveFails() throws {
        _ = try store.createFolder(named: "Reports")
        let record = try makeOwned(named: "Report.pdf", data: Data("rollback".utf8))
        store.saveFailureForTesting = TestSaveFailure()

        XCTAssertThrowsError(try store.move(record, toRelativeFolder: "Reports"))

        XCTAssertEqual(record.relativePath, "Report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Report.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Reports/Report.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(".document-move-journal").path))
        store.saveFailureForTesting = nil
        try store.move(record, toRelativeFolder: "Reports")
        XCTAssertEqual(record.relativePath, "Reports/Report.pdf")
    }

    func testMoveJournalRecoveryRestoresFileWhenMetadataSaveDidNotCommit() async throws {
        let record = try makeOwned(named: "Report.pdf")
        _ = try store.createFolder(named: "Reports")
        let transaction = try XCTUnwrap(
            store.fileBridge.stageMove(
                recordID: record.id,
                fromRelativePath: record.relativePath,
                toRelativeFolder: "Reports"
            )
        )

        await StartupRecovery.run(
            store: store,
            thumbnails: ThumbnailStore(cacheDirectory: tempRoot.appendingPathComponent("Thumbnails"))
        )

        XCTAssertEqual(record.relativePath, "Report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Report.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.journalURL.path))
    }

    func testUnresolvedMoveIsReservedAcrossIndexPassesUntilRecoveryRestoresSource() async throws {
        let record = try makeOwned(named: "Blocked/Report.pdf", data: Data("recover me".utf8))
        _ = try store.createFolder(named: "Recovered")
        let transaction = try XCTUnwrap(
            store.fileBridge.stageMove(
                recordID: record.id,
                fromRelativePath: record.relativePath,
                toRelativeFolder: "Recovered"
            )
        )

        // A regular file now occupies the source parent, so two launch
        // recovery passes must leave the staged destination untouched.
        try FileManager.default.removeItem(at: documentsDir.appendingPathComponent("Blocked"))
        try Data("parent collision".utf8).write(
            to: documentsDir.appendingPathComponent("Blocked")
        )

        for _ in 0..<2 {
            await StartupRecovery.run(
                store: store,
                thumbnails: ThumbnailStore(cacheDirectory: tempRoot.appendingPathComponent("Thumbnails"))
            )
            let library = DeviceLibraryService()
            library.grantService = FolderGrantService(context: container.mainContext)
            library.start(store: store)
            try await waitForLibrarySync(library)
            await library.syncNowAndWait()
            library.stop()

            let records = try store.fetchRecent()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.id, record.id)
            XCTAssertNil(records.first { $0.relativePath == transaction.destinationRelativePath })
            XCTAssertEqual(
                try Data(contentsOf: documentsDir.appendingPathComponent(transaction.destinationRelativePath)),
                Data("recover me".utf8)
            )
        }

        try FileManager.default.removeItem(at: documentsDir.appendingPathComponent("Blocked"))
        try FileManager.default.createDirectory(
            at: documentsDir.appendingPathComponent("Blocked"),
            withIntermediateDirectories: true
        )

        await StartupRecovery.run(
            store: store,
            thumbnails: ThumbnailStore(cacheDirectory: tempRoot.appendingPathComponent("Thumbnails"))
        )
        let library = DeviceLibraryService()
        library.grantService = FolderGrantService(context: container.mainContext)
        library.start(store: store)
        try await waitForLibrarySync(library)
        await library.syncNowAndWait()
        library.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(record.relativePath).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent(transaction.destinationRelativePath).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.journalURL.path))
        XCTAssertEqual(try store.fetchRecent().filter { $0.id == record.id }.count, 1)
    }

    func testMalformedMoveJournalDefersAppContainerAdoption() async throws {
        try FileManager.default.createDirectory(
            at: documentsDir.appendingPathComponent(".document-move-journal"),
            withIntermediateDirectories: true
        )
        let malformedJournal = documentsDir
            .appendingPathComponent(".document-move-journal")
            .appendingPathComponent("not-a-record.json")
        try Data("not-json".utf8).write(to: malformedJournal)

        let orphanURL = documentsDir.appendingPathComponent("Orphan.pdf")
        try TestPDF.make(pageCount: 1).write(to: orphanURL)

        await StartupRecovery.run(
            store: store,
            thumbnails: ThumbnailStore(cacheDirectory: tempRoot.appendingPathComponent("Thumbnails"))
        )
        let library = DeviceLibraryService()
        library.grantService = FolderGrantService(context: container.mainContext)
        library.start(store: store)
        try await waitForLibrarySync(library)
        await library.syncNowAndWait()
        library.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(try store.fetchRecent().contains { $0.relativePath == "Orphan.pdf" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedJournal.path))
    }

    private func waitForLibrarySync(_ library: DeviceLibraryService) async throws {
        let deadline = Date().addingTimeInterval(5)
        while library.lastSyncAt == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(library.lastSyncAt, "DeviceLibraryService did not complete its startup sync")
    }

    private struct TestSaveFailure: Error {}
}
