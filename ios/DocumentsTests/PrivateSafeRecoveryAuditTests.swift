import Foundation
import XCTest
@testable import Documents

/// Independent recovery regressions: an unauthenticated journal and a stale
/// but valid index must never authorize destruction of another encrypted copy.
final class PrivateSafeRecoveryAuditTests: XCTestCase {
    private var base: URL!
    private var vault: URL!
    private let key = Data(repeating: 0x71, count: 32)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SafeRecoveryAudit-\(UUID().uuidString)")
        vault = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testCorruptActiveManifestFallbackCannotDeleteUnreferencedEncryptedCopy() async throws {
        let store = makeStore()
        let source = try source(named: "source.txt", text: "Must survive index damage")
        let item = try await store.addCopy(from: source, rawKey: key)
        let blob = vault.appendingPathComponent("blobs/\(item.blobName)")
        let encrypted = try Data(contentsOf: blob)
        try PrivateSafeCrypto.sealManifest(PrivateSafeManifest(generation: 0), rawKey: key)
            .write(to: vault.appendingPathComponent("manifest.safe.previous"))
        try Data("damaged current index".utf8).write(to: vault.appendingPathComponent("manifest.safe"))

        _ = try? await store.listItems(rawKey: key)

        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path), "A valid older index cannot prove a newer blob is disposable")
        XCTAssertEqual(try Data(contentsOf: blob), encrypted)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Must survive index damage")
    }

    func testForgedDeleteJournalCannotDeleteAnotherItemsStagedPayload() async throws {
        let store = makeStore()
        let firstSource = try source(named: "first.txt", text: "First item")
        let secondSource = try source(named: "second.txt", text: "Second item must survive")
        let first = try await store.addCopy(from: firstSource, rawKey: key)
        let second = try await store.addCopy(from: secondSource, rawKey: key)
        // The authenticated current generation omits first, but still owns
        // second. A forged journal impersonates a completed first deletion.
        try PrivateSafeCrypto.sealManifest(
            PrivateSafeManifest(generation: 99, items: [first, second]), rawKey: key
        ).write(to: vault.appendingPathComponent("manifest.safe.previous"))
        try PrivateSafeCrypto.sealManifest(
            PrivateSafeManifest(generation: 100, items: [second]), rawKey: key
        ).write(to: vault.appendingPathComponent("manifest.safe"))
        let operation = UUID()
        let staged = vault.appendingPathComponent("transactions/delete-\(operation.uuidString).blob")
        try FileManager.default.moveItem(
            at: vault.appendingPathComponent("blobs/\(second.blobName)"), to: staged
        )
        let encrypted = try Data(contentsOf: staged)
        let journal = PrivateSafeTransaction(
            operationID: operation, kind: .delete, itemID: first.id,
            pendingPath: nil,
            finalBlobPath: vault.appendingPathComponent("blobs/\(first.blobName)").path,
            stagedBlobPath: staged.path, expectedGeneration: 99,
            stage: .manifestCommitted
        )
        try JSONEncoder().encode(journal)
            .write(to: vault.appendingPathComponent("transactions/\(operation.uuidString).json"))

        _ = try? await store.listItems(rawKey: key)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Journal identity does not authenticate the staged blob")
        XCTAssertEqual(try Data(contentsOf: staged), encrypted)
    }

    private func makeStore() -> PrivateSafeStore {
        PrivateSafeStore(root: vault, cacheRoot: base.appendingPathComponent("cache"))
    }

    private func source(named name: String, text: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
