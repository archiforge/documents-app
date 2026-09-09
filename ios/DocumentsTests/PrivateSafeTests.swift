import Foundation
import XCTest
@testable import Documents

final class PrivateSafeTests: XCTestCase {
    private var root: URL!
    private var cacheRoot: URL!
    private let key = Data(repeating: 0x2A, count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSafeTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("vault", isDirectory: true)
        cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        root = nil
        cacheRoot = nil
        try super.tearDownWithError()
    }

    func testRoundTripRetainsSourceAndDeletesOnlyEncryptedCopy() async throws {
        let source = try writeSource(bytes: Data(repeating: 0x5A, count: PrivateSafeCrypto.chunkSize + 17))
        let original = try Data(contentsOf: source)
        let store = makeStore()

        let item = try await store.addCopy(
            from: source,
            displayName: "Research.bin",
            sourceRecordID: UUID(),
            rawKey: key
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
        let listed = try await store.listItems(rawKey: key)
        XCTAssertEqual(listed, [item])

        let export = try await store.makeTemporaryURL(fileName: item.displayName, kind: .export)
        _ = try await store.decryptItem(id: item.id, rawKey: key, destination: export, kind: .export)
        XCTAssertEqual(try Data(contentsOf: export), original)
        await store.removeTemporaryFiles([export])
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))

        try await store.delete(id: item.id, rawKey: key)
        let remaining = try await store.listItems(rawKey: key)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("blobs/\(item.blobName)").path
        ))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testManifestTamperIsRejectedAndEncryptedStateIsKept() async throws {
        let source = try writeSource(bytes: Data("secret".utf8))
        let store = makeStore()
        _ = try await store.addCopy(from: source, rawKey: key)
        // A successful recovery removes the superseded generation0 fallback.
        _ = try await store.listItems(rawKey: key)

        let manifest = root.appendingPathComponent("manifest.safe")
        var bytes = try Data(contentsOf: manifest)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xFF
        try bytes.write(to: manifest)

        do {
            _ = try await store.listItems(rawKey: key)
            XCTFail("Tampered manifest should not authenticate")
        } catch {
            XCTAssertEqual(error as? PrivateSafeError, .corruptManifest)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testBlobTamperFailsBeforePublishingPlaintext() async throws {
        let source = try writeSource(bytes: Data("authenticated payload".utf8))
        let store = makeStore()
        let item = try await store.addCopy(from: source, rawKey: key)
        let blob = root.appendingPathComponent("blobs/\(item.blobName)")
        var bytes = try Data(contentsOf: blob)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0x01
        try bytes.write(to: blob)

        let destination = try await store.makeTemporaryURL(fileName: "tampered.txt", kind: .export)
        do {
            _ = try await store.decryptItem(
                id: item.id,
                rawKey: key,
                destination: destination,
                kind: .export
            )
            XCTFail("Tampered blob should not decrypt")
        } catch {
            XCTAssertEqual(error as? PrivateSafeError, .corruptBlob)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await store.removeTemporaryFiles([destination])
    }

    func testCancelledAddKeepsSourceAndLeavesNoSafeItem() async throws {
        let source = try writeSource(bytes: Data(repeating: 0x1F, count: PrivateSafeCrypto.chunkSize))
        let original = try Data(contentsOf: source)
        let store = makeStore()
        let rawKey = key
        let task: Task<PrivateSafeItem, Error> = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.addCopy(from: source, rawKey: rawKey)
        }

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled add should not publish an item")
        } catch is CancellationError {
            // Expected.
        }
        let remaining = try await store.listItems(rawKey: key)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testForgedJournalCannotDeleteReferencedBlobOrFollowSourceSymlink() async throws {
        let source = try writeSource(bytes: Data("keep me".utf8))
        let store = makeStore()
        let item = try await store.addCopy(from: source, rawKey: key)
        let blob = root.appendingPathComponent("blobs/\(item.blobName)")
        let before = try Data(contentsOf: blob)

        let operationID = UUID()
        let forged = PrivateSafeTransaction(
            operationID: operationID,
            kind: .add,
            itemID: operationID,
            pendingPath: root.appendingPathComponent("pending/add-\(operationID.uuidString).blob").path,
            finalBlobPath: blob.path,
            stagedBlobPath: nil,
            expectedGeneration: 0,
            stage: .prepared
        )
        let journal = root.appendingPathComponent("transactions/\(operationID.uuidString).json")
        try JSONEncoder().encode(forged).write(to: journal)

        let listed = try await store.listItems(rawKey: key)
        XCTAssertEqual(listed, [item])
        XCTAssertEqual(try Data(contentsOf: blob), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "Unknown journal stays quarantined")

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let symlink = root.deletingLastPathComponent().appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        do {
            _ = try await store.addCopy(from: symlink, rawKey: key)
            XCTFail("A source symlink should not be followed")
        } catch {
            XCTAssertEqual(error as? PrivateSafeError, .invalidSource)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testFirstAddFailureLeavesAuthenticatedEmptyGenerationForRecovery() async throws {
        let source = try writeSource(bytes: Data("unchanged".utf8))
        let store = PrivateSafeStore(root: root, cacheRoot: cacheRoot, fault: .beforeAddEncryption)

        do {
            _ = try await store.addCopy(from: source, rawKey: key)
            XCTFail("Injected failure should throw")
        } catch {
            // Expected.
        }
        let reopened = PrivateSafeStore(root: root, cacheRoot: cacheRoot)
        let recovered = try await reopened.listItems(rawKey: key)
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("unchanged".utf8))
    }

    func testPostCommitFaultDoesNotRollBackAuthenticatedAdd() async throws {
        let source = try writeSource(bytes: Data("durable".utf8))
        let store = PrivateSafeStore(root: root, cacheRoot: cacheRoot, fault: .afterAddManifestCommit)

        do {
            _ = try await store.addCopy(from: source, rawKey: key)
            XCTFail("Injected post-commit failure should throw")
        } catch {
            // The manifest commit is intentionally durable before this fault.
        }
        let items = try await store.listItems(rawKey: key)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data("durable".utf8))
    }

    func testPostCommitFaultDoesNotRestoreDeletedCopy() async throws {
        let source = try writeSource(bytes: Data("delete me".utf8))
        let setup = makeStore()
        let item = try await setup.addCopy(from: source, rawKey: key)
        let store = PrivateSafeStore(
            root: root,
            cacheRoot: cacheRoot,
            fault: .afterDeleteManifestCommit
        )

        do {
            try await store.delete(id: item.id, rawKey: key)
            XCTFail("Injected post-commit delete failure should throw")
        } catch {
            // The authenticated manifest has already removed the copy.
        }

        let reopened = makeStore()
        let items = try await reopened.listItems(rawKey: key)
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("blobs/\(item.blobName)").path
        ))
        XCTAssertEqual(try Data(contentsOf: source), Data("delete me".utf8))
    }

    private func makeStore() -> PrivateSafeStore {
        PrivateSafeStore(root: root, cacheRoot: cacheRoot)
    }

    private func writeSource(bytes: Data) throws -> URL {
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).dat")
        try bytes.write(to: source)
        return source
    }
}
