import Foundation
import LocalAuthentication
import UIKit
import XCTest
@testable import Documents

final class PrivateSafeFinalAuditTests: XCTestCase {
    private var base: URL!
    private let key = Data(repeating: 0x4C, count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSafeFinalAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        base = nil
        try super.tearDownWithError()
    }

    func testCacheRootSymlinkCannotCreateOrDeleteOutsideCache() async throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cacheLink = base.appendingPathComponent("cache-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cacheLink, withDestinationURL: outside)

        let marker = outside
            .appendingPathComponent("views", isDirectory: true)
            .appendingPathComponent("plaintext-\(UUID().uuidString)", isDirectory: true)
        let plaintext = marker.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: plaintext)

        let store = PrivateSafeStore(
            root: base.appendingPathComponent("vault", isDirectory: true),
            cacheRoot: cacheLink
        )
        do {
            _ = try await store.makeTemporaryURL(fileName: "copy.txt", kind: .export)
            XCTFail("A symlinked cache root must reject temporary allocation")
        } catch {
            XCTAssertEqual(error as? PrivateSafeError, .invalidDestination)
        }

        PrivateSafeStore.sweepPlaintextCaches(cacheRoot: cacheLink)
        await store.removeTemporaryFiles([plaintext])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plaintext.path))
    }

    func testCacheParentSymlinkCannotSweepOrCreateOutsideCache() async throws {
        let outside = base.appendingPathComponent("outside-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let parentLink = base.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: outside)
        let cacheRoot = parentLink.appendingPathComponent("cache", isDirectory: true)

        let marker = outside
            .appendingPathComponent("cache/views/plaintext-\(UUID().uuidString)", isDirectory: true)
        let plaintext = marker.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: plaintext)

        let store = PrivateSafeStore(
            root: base.appendingPathComponent("vault", isDirectory: true),
            cacheRoot: cacheRoot
        )
        do {
            _ = try await store.makeTemporaryURL(fileName: "copy.txt", kind: .view)
            XCTFail("A symlinked cache parent must reject temporary allocation")
        } catch {
            XCTAssertEqual(error as? PrivateSafeError, .invalidDestination)
        }
        PrivateSafeStore.sweepPlaintextCaches(cacheRoot: cacheRoot)
        await store.removeTemporaryFiles([plaintext])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plaintext.path))
    }

    func testVaultRootSymlinkFailsClosedForCreateAndReset() async throws {
        let outside = base.appendingPathComponent("outside-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.bin")
        try Data("preserve".utf8).write(to: sentinel)
        let rootLink = base.appendingPathComponent("vault-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        let source = base.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)

        let store = PrivateSafeStore(
            root: rootLink,
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let hasState = await store.hasEncryptedState()
        XCTAssertTrue(hasState)
        do {
            _ = try await store.addCopy(from: source, rawKey: key)
            XCTFail("A symlinked vault root must reject writes")
        } catch {
            // Expected fail-closed write.
        }
        do {
            try await store.reset()
            XCTFail("A symlinked vault root must reject reset")
        } catch {
            // Expected fail-closed reset.
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }

    func testEncryptedBlobKeepsProtectionAfterCanonicalRename() async throws {
        let store = makeStore()
        let source = base.appendingPathComponent("source.bin")
        try Data(repeating: 0x2A, count: 97).write(to: source)
        let item = try await store.addCopy(from: source, rawKey: key)
        let blob = base.appendingPathComponent("vault/blobs/\(item.blobName)")

        let values = try blob.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        if let protection = try FileManager.default.attributesOfItem(atPath: blob.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
    }

    @MainActor
    func testResetClearsSessionWhenKeychainDeletionFails() async throws {
        let store = makeStore()
        let source = base.appendingPathComponent("source.txt")
        try Data("encrypted".utf8).write(to: source)
        _ = try await store.addCopy(from: source, rawKey: key)

        let session = PrivateSafeSession(
            store: store,
            keychain: FinalAuditKeychain(key: key, failDelete: true),
            sceneSnapshot: { [] }
        )
        await session.unlock()
        XCTAssertTrue(session.isUnlocked)

        do {
            try await session.resetVault()
            XCTFail("Keychain deletion should fail")
        } catch {
            // The session must remain locked even though reset reported a
            // failure after the vault was removed.
        }
        XCTAssertFalse(session.isUnlocked)
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.items.isEmpty)
    }

    @MainActor
    func testUnavailableResetFailureDoesNotRetainAuthenticatedState() async throws {
        let setup = makeStore()
        let source = base.appendingPathComponent("source.txt")
        try Data("encrypted".utf8).write(to: source)
        _ = try await setup.addCopy(from: source, rawKey: key)

        let outside = base.appendingPathComponent("outside-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cacheLink = base.appendingPathComponent("cache-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: cacheLink, withDestinationURL: outside)
        let session = PrivateSafeSession(
            store: PrivateSafeStore(
                root: base.appendingPathComponent("vault", isDirectory: true),
                cacheRoot: cacheLink
            ),
            keychain: FinalAuditKeychain(key: nil),
            sceneSnapshot: { [] }
        )
        await session.unlock()
        guard case .unavailable = session.state else {
            return XCTFail("A missing key with encrypted state should be unavailable")
        }

        do {
            try await session.resetUnavailableVault()
            XCTFail("The unsafe cache root should reject reset")
        } catch {
            // The unavailable state remains retryable, with no in-memory key
            // or item index left behind.
        }
        XCTAssertFalse(session.isUnlocked)
        XCTAssertTrue(session.items.isEmpty)
        if case .unavailable = session.state {
            // Expected.
        } else {
            XCTFail("Reset failure must not make an unavailable vault appear unlocked")
        }
    }

    @MainActor
    func testProtectedDataAvailableRecomputesPrivacyCover() async throws {
        let session = PrivateSafeSession(
            store: makeStore(),
            keychain: FinalAuditKeychain(key: key),
            sceneSnapshot: {
                [PrivateSafeSceneSnapshot(id: "scene", activation: .active)]
            }
        )
        await session.unlock()
        XCTAssertTrue(session.isUnlocked)

        session.protectedDataBecameUnavailable()
        XCTAssertTrue(session.isPrivacyCovered)
        for _ in 0..<100 where session.isUnlocked {
            await Task.yield()
        }

        NotificationCenter.default.post(
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        for _ in 0..<100 where session.isPrivacyCovered {
            await Task.yield()
        }
        XCTAssertFalse(session.isPrivacyCovered)
    }

    private func makeStore() -> PrivateSafeStore {
        PrivateSafeStore(
            root: base.appendingPathComponent("vault", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
    }
}

private final class FinalAuditKeychain: PrivateSafeKeychainClient, @unchecked Sendable {
    let key: Data?
    let failDelete: Bool

    init(key: Data?, failDelete: Bool = false) {
        self.key = key
        self.failDelete = failDelete
    }

    func read(context: LAContext?) throws -> Data? {
        key
    }

    func create() throws -> Data {
        key ?? Data(repeating: 0xA7, count: 32)
    }

    func delete() throws {
        if failDelete {
            throw PrivateSafeError.operationFailed("Injected Keychain deletion failure.")
        }
    }
}
