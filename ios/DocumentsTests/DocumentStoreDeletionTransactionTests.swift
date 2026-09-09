import SwiftData
import XCTest
@testable import Documents

/// Permanent deletion is a two-resource transaction: the metadata row and
/// the app-owned bytes must agree after success, failure, and relaunch.
@MainActor
final class DocumentStoreDeletionTransactionTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsDeletionTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)

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
        container = nil
        store = nil
        try await super.tearDown()
    }

    private struct InjectedSaveFailure: Error {}

    private var stagingDirectory: URL {
        documentsDir.appendingPathComponent(".document-delete-staging", isDirectory: true)
    }

    @discardableResult
    private func makeRecord(
        named name: String,
        data: Data = Data("Documents test file".utf8)
    ) throws -> DocumentRecord {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let url = documentsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return try store.adoptFile(at: url)
    }

    func testFailedDeleteSaveRestoresBytesAndRecord() throws {
        let payload = Data("bytes must survive a failed save".utf8)
        let record = try makeRecord(named: "Keep.pdf", data: payload)
        store.saveFailureForTesting = InjectedSaveFailure()

        XCTAssertThrowsError(try store.delete(record))

        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent("Keep.pdf")),
            payload,
            "rollback must restore the staged bytes"
        )
        XCTAssertEqual(
            try store.fetchRecent().map(\.id),
            [record.id],
            "rollback must restore the deleted metadata row"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingDirectory.appendingPathComponent("\(record.id.uuidString).payload").path),
            "a successful byte restore must consume the staged payload"
        )
    }

    func testSuccessfulDeleteRemovesBytesAndRecord() throws {
        let record = try makeRecord(named: "Gone.pdf")

        try store.delete(record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Gone.pdf").path))
        XCTAssertTrue(try store.fetchRecent().isEmpty)
        XCTAssertTrue(try store.fetchTrash().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testDeletingExternalRecordPreservesSourceBytes() throws {
        let externalURL = tempRoot.appendingPathComponent("External/Shared.pdf")
        try FileManager.default.createDirectory(
            at: externalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data("external bytes".utf8)
        try payload.write(to: externalURL)
        let record = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)

        try store.delete(record)

        XCTAssertEqual(try Data(contentsOf: externalURL), payload)
        XCTAssertTrue(try store.fetchRecent().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testStartupRecoveryRestoresStageWhenRecordSurvived() async throws {
        let payload = Data("interrupted delete".utf8)
        let record = try makeRecord(named: "Interrupted.pdf", data: payload)
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )

        await StartupRecovery.run(store: store, thumbnails: ThumbnailStore(
            cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
        ))

        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent("Interrupted.pdf")),
            payload
        )
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.manifestURL.path))
    }

    func testStartupRecoveryFinalizesStageWhenRecordIsGone() async throws {
        let record = try makeRecord(named: "Committed.pdf")
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )
        contextDeleteAndSave(record)

        await StartupRecovery.run(store: store, thumbnails: ThumbnailStore(
            cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
        ))

        XCTAssertTrue(try store.fetchRecent().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent("Committed.pdf").path))
    }

    func testRecoveryNeverOverwritesAnExistingDestination() async throws {
        let record = try makeRecord(named: "Collision.pdf", data: Data("original".utf8))
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )
        let conflicting = Data("different file".utf8)
        try conflicting.write(to: documentsDir.appendingPathComponent("Collision.pdf"))

        await StartupRecovery.run(store: store, thumbnails: ThumbnailStore(
            cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
        ))

        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent("Collision.pdf")),
            conflicting
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.manifestURL.path))
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }

    func testDirectRestoreRefusesToOverwriteCollision() throws {
        let record = try makeRecord(named: "Collision.pdf", data: Data("staged".utf8))
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )
        let conflicting = Data("unrelated".utf8)
        try conflicting.write(to: documentsDir.appendingPathComponent("Collision.pdf"))

        XCTAssertThrowsError(try store.fileBridge.restoreStagedDeletion(stage))
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent("Collision.pdf")),
            conflicting
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagedURL.path))
    }

    func testRecoveryRetainsRowAndStageWhenDestinationCannotBeRestored() async throws {
        let payload = Data("blocked parent".utf8)
        let record = try makeRecord(named: "Nested/Blocked.pdf", data: payload)
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )

        let blockedParent = documentsDir.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.removeItem(at: blockedParent)
        try Data("a regular file, not a directory".utf8).write(to: blockedParent)

        let thumbnails = ThumbnailStore(
            cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
        )
        await StartupRecovery.run(store: store, thumbnails: thumbnails)
        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.manifestURL.path))

        try FileManager.default.removeItem(at: blockedParent)
        await StartupRecovery.run(store: store, thumbnails: thumbnails)

        XCTAssertEqual(try Data(contentsOf: documentsDir.appendingPathComponent("Nested/Blocked.pdf")), payload)
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.manifestURL.path))
    }

    func testUnknownManifestAndPayloadOnlyStageStayRecoverableAcrossLaunches() async throws {
        let payload = Data("must remain recoverable".utf8)
        let record = try makeRecord(named: "UnknownJournal.pdf", data: payload)
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )
        // Simulate an interrupted/corrupt journal: the UUID payload survives,
        // but its manifest was lost and an unrelated malformed entry remains.
        try FileManager.default.removeItem(at: stage.manifestURL)
        let unknownManifest = stagingDirectory.appendingPathComponent("not-a-record.json")
        try Data("not-json".utf8).write(to: unknownManifest)
        let hiddenArtifact = stagingDirectory.appendingPathComponent(".unreadable-artifact")
        try Data("keep this hidden".utf8).write(to: hiddenArtifact)

        let thumbnails = ThumbnailStore(
            cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
        )
        for _ in 0..<2 {
            await StartupRecovery.run(store: store, thumbnails: thumbnails)

            XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: documentsDir.appendingPathComponent(record.relativePath).path
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagedURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknownManifest.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenArtifact.path))
        }
    }

    func testRestoreLeavesStagingDirectoryWhenHiddenArtifactRemains() throws {
        let record = try makeRecord(named: "HiddenArtifact.pdf")
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )
        let hiddenArtifact = stagingDirectory.appendingPathComponent(".keep-for-recovery")
        try Data("preserve".utf8).write(to: hiddenArtifact)

        try store.fileBridge.restoreStagedDeletion(stage)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenArtifact.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent(record.relativePath).path
            )
        )
    }

    func testStageDeletionRejectsTraversalAndPreservesOutsideBytes() throws {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outsideURL = tempRoot.appendingPathComponent("Outside.pdf")
        let payload = Data("outside bytes".utf8)
        try payload.write(to: outsideURL)

        XCTAssertThrowsError(
            try store.fileBridge.stageDeletion(
                recordID: UUID(),
                atRelativePath: "../Outside.pdf"
            )
        )
        XCTAssertThrowsError(try store.fileBridge.deleteFile(atRelativePath: ""))

        XCTAssertEqual(try Data(contentsOf: outsideURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testStageDeletionRejectsSymlinkParentAndPreservesOutsideBytes() throws {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let outsideDirectory = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideURL = outsideDirectory.appendingPathComponent("Shared.pdf")
        let payload = Data("outside bytes".utf8)
        try payload.write(to: outsideURL)

        let linkedDirectory = documentsDir.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outsideDirectory
        )

        XCTAssertThrowsError(
            try store.fileBridge.stageDeletion(
                recordID: UUID(),
                atRelativePath: "Linked/Shared.pdf"
            )
        )

        XCTAssertEqual(try Data(contentsOf: outsideURL), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: stagingDirectory.appendingPathComponent("Linked").path
            )
        )
    }

    func testDanglingStagingSymlinkBlocksRecoveryAndPreservesRows() async throws {
        let missing = try makeRecord(named: "MissingBehindDanglingStage.pdf")
        let keep = try makeRecord(named: "KeepBehindDanglingStage.pdf", data: Data("keep".utf8))
        try FileManager.default.removeItem(
            at: documentsDir.appendingPathComponent(missing.relativePath)
        )

        let danglingTarget = tempRoot.appendingPathComponent("NoSuchStagingTarget", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: stagingDirectory,
            withDestinationURL: danglingTarget
        )

        XCTAssertThrowsError(
            try store.fileBridge.reconcileDeletionStaging(
                for: [
                    missing.id: missing.relativePath,
                    keep.id: keep.relativePath,
                ]
            )
        )

        await StartupRecovery.run(
            store: store,
            thumbnails: ThumbnailStore(
                cacheDirectory: tempRoot.appendingPathComponent("ThumbnailCache", isDirectory: true)
            )
        )

        XCTAssertEqual(
            Set(try store.fetchRecent().map(\.id)),
            Set([missing.id, keep.id])
        )
        XCTAssertEqual(
            try Data(contentsOf: documentsDir.appendingPathComponent(keep.relativePath)),
            Data("keep".utf8)
        )
        let stagingValues = try stagingDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(stagingValues.isSymbolicLink, true)
    }

    func testRestoreRejectsSymlinkDestinationParentAndPreservesStagedBytes() throws {
        let payload = Data("staged bytes".utf8)
        let record = try makeRecord(named: "Nested/Restore.pdf", data: payload)
        let stage = try XCTUnwrap(
            store.fileBridge.stageDeletion(recordID: record.id, atRelativePath: record.relativePath)
        )

        let outsideDirectory = tempRoot.appendingPathComponent("RestoreOutside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let nestedDirectory = documentsDir.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.removeItem(at: nestedDirectory)
        try FileManager.default.createSymbolicLink(
            at: nestedDirectory,
            withDestinationURL: outsideDirectory
        )

        XCTAssertThrowsError(try store.fileBridge.restoreStagedDeletion(stage))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.stagedURL.path))
        XCTAssertEqual(
            try Data(contentsOf: stage.stagedURL),
            payload
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideDirectory.appendingPathComponent("Restore.pdf").path
            )
        )
    }

    func testStageDeletionRejectsSymlinkStagingDirectory() throws {
        let record = try makeRecord(named: "StageRoot.pdf")
        let outsideDirectory = tempRoot.appendingPathComponent("StagingOutside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: stagingDirectory,
            withDestinationURL: outsideDirectory
        )

        XCTAssertThrowsError(
            try store.fileBridge.stageDeletion(
                recordID: record.id,
                atRelativePath: record.relativePath
            )
        )
        let fakeStage = FileBridge.DeletionStage(
            recordID: record.id,
            relativePath: record.relativePath,
            stagedURL: stagingDirectory.appendingPathComponent("\(record.id.uuidString).payload"),
            manifestURL: stagingDirectory.appendingPathComponent("\(record.id.uuidString).json")
        )
        XCTAssertThrowsError(try store.fileBridge.finalizeStagedDeletion(fakeStage))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: documentsDir.appendingPathComponent(record.relativePath).path
            )
        )
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(
                at: outsideDirectory,
                includingPropertiesForKeys: nil
            )).isEmpty
        )
    }

    private func contextDeleteAndSave(_ record: DocumentRecord) {
        store.context.delete(record)
        try! store.context.save()
    }
}
