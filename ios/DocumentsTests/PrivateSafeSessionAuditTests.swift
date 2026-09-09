import Foundation
import LocalAuthentication
import XCTest
@testable import Documents

@MainActor
final class PrivateSafeSessionAuditTests: XCTestCase {
    private var base: URL!
    private var vault: PrivateSafeStore!
    private let key = Data(repeating: 0x36, count: 32)

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSessionAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        vault = PrivateSafeStore(root: base.appendingPathComponent("vault"), cacheRoot: base.appendingPathComponent("cache"))
    }

    override func tearDown() async throws {
        vault = nil
        try? FileManager.default.removeItem(at: base)
    }

    func testLateAuthenticationCannotUnlockAfterLock() async throws {
        let keychain = AuditSafeKeychain(key: key, blocksRead: true)
        let session = PrivateSafeSession(store: vault, keychain: keychain)
        let unlock = Task { await session.unlock() }
        let started = await keychain.waitForRead()
        XCTAssertTrue(started)
        let locking = Task { await session.lock() }
        for _ in 0..<100 where session.state != .locked { await Task.yield() }
        XCTAssertEqual(session.state, .locked)
        keychain.releaseRead()
        await locking.value
        await unlock.value
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.items.isEmpty)
    }

    func testMissingKeyDoesNotReplaceExistingVaultKey() async throws {
        let item = try await addItem()
        let blob = base.appendingPathComponent("vault/blobs/\(item.blobName)")
        let before = try Data(contentsOf: blob)
        let keychain = AuditSafeKeychain(key: nil)
        let session = PrivateSafeSession(store: vault, keychain: keychain)
        await session.unlock()
        XCTAssertFalse(session.isUnlocked)
        XCTAssertEqual(keychain.creationCount, 0)
        XCTAssertEqual(try Data(contentsOf: blob), before)
    }

    func testInactiveSceneCoversSafeAndLastBackgroundSceneLocks() async throws {
        let session = PrivateSafeSession(
            store: vault,
            keychain: AuditSafeKeychain(key: key),
            sceneSnapshot: { [] }
        )
        await session.unlock()
        XCTAssertTrue(session.isUnlocked)
        session.sceneDidChange(.active, sceneID: "one")
        session.sceneDidChange(.active, sceneID: "two")
        session.sceneDidChange(.inactive, sceneID: "one")
        XCTAssertTrue(session.isPrivacyCovered)
        XCTAssertTrue(session.isUnlocked)
        session.sceneDidChange(.background, sceneID: "one")
        XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(session.isPrivacyCovered)
        session.sceneDidChange(.background, sceneID: "two")
        for _ in 0..<100 where session.isUnlocked { await Task.yield() }
        XCTAssertFalse(session.isUnlocked)
    }

    func testLockRemovesPlaintextExportAndClearsIndex() async throws {
        let item = try await addItem()
        let session = PrivateSafeSession(store: vault, keychain: AuditSafeKeychain(key: key))
        await session.unlock()
        let url = try await session.export(itemID: item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        await session.lock()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertFalse(session.isUnlocked)
    }

    private func addItem() async throws -> PrivateSafeItem {
        let source = base.appendingPathComponent("source.txt")
        try Data("Synthetic private copy".utf8).write(to: source)
        return try await vault.addCopy(from: source, rawKey: key)
    }
}

/// Intentionally noncooperative authentication response for the late-result
/// regression. It ignores LAContext invalidation to test the session lease.
private final class AuditSafeKeychain: PrivateSafeKeychainClient, @unchecked Sendable {
    private let key: Data?
    private let blocksRead: Bool
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let mutex = NSLock()
    private var creations = 0

    init(key: Data?, blocksRead: Bool = false) {
        self.key = key
        self.blocksRead = blocksRead
    }

    var creationCount: Int { mutex.withLock { creations } }

    func read(context: LAContext?) throws -> Data? {
        if blocksRead {
            started.signal()
            guard released.wait(timeout: .now() + 10) == .success else {
                throw PrivateSafeError.operationFailed("Test authentication timed out")
            }
        }
        return key
    }

    func create() throws -> Data {
        mutex.withLock { creations += 1 }
        return Data(repeating: 0x99, count: 32)
    }

    func delete() throws {}

    func waitForRead() async -> Bool {
        await Task.detached { [self] in waitForReadSynchronously() }.value
    }

    private func waitForReadSynchronously() -> Bool {
        started.wait(timeout: .now() + 5) == .success
    }

    func releaseRead() { released.signal() }
}
