import SwiftData
import XCTest
@testable import Documents

@MainActor
final class DocumentSourceAccessTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!
    private var grants: FolderGrantService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: DocumentRecord.self, FolderGrant.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = DocumentStore(context: container.mainContext,
                              fileBridge: FileBridge(documentsDirectory: root.appendingPathComponent("Owned")))
        grants = FolderGrantService(context: container.mainContext)
    }

    override func tearDown() async throws {
        grants = nil
        store = nil
        container = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOwnedReadUsesInjectedContainerAndPreservesSource() async throws {
        let record = try store.saveGeneratedFile(name: "source.txt", data: Data("owned".utf8))
        let result = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: nil) {
            try Data(contentsOf: $0)
        }
        XCTAssertEqual(result, Data("owned".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Owned/source.txt")), result)
    }

    func testReadableAbsolutePathWithoutGrantIsRejected() async throws {
        let file = root.appendingPathComponent("external.txt")
        try Data("external".utf8).write(to: file)
        let record = try store.adoptFile(at: file, absolutePath: file.path)
        do {
            _ = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: grants) {
                try Data(contentsOf: $0)
            }
            XCTFail("A readable cached path is not a grant")
        } catch is DocumentSourceAccessError {}
    }

    func testBookmarkResolvesExternalChild() async throws {
        let folder = root.appendingPathComponent("Granted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("external.txt")
        try Data("granted".utf8).write(to: file)
        _ = try grants.addGrant(from: folder)
        let record = try store.adoptFile(at: file, absolutePath: file.path)
        let result = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: grants) {
            try Data(contentsOf: $0)
        }
        XCTAssertEqual(result, Data("granted".utf8))
    }

    func testOwnedSymlinkReplacementCannotEscapeContainer() async throws {
        let record = try store.saveGeneratedFile(name: "source.txt", data: Data("owned".utf8))
        let file = root.appendingPathComponent("Owned/source.txt")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do {
            _ = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: nil) {
                try Data(contentsOf: $0)
            }
            XCTFail("Symlink should be rejected")
        } catch is FileBridgeFolderError {}
    }

    func testTrashedSourceIsRejected() async throws {
        let record = try store.saveGeneratedFile(name: "source.txt", data: Data("owned".utf8))
        try store.trash(record)
        do {
            _ = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: nil) {
                try Data(contentsOf: $0)
            }
            XCTFail("Trashed source should be rejected")
        } catch is DocumentSourceAccessError {}
    }

    func testGrantedFolderSymlinkCannotReadOutsideGrant() async throws {
        let folder = root.appendingPathComponent("Granted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("source.txt")
        try Data("granted".utf8).write(to: file)
        _ = try grants.addGrant(from: folder)
        let record = try store.adoptFile(at: file, absolutePath: file.path)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do {
            _ = try await DocumentSourceAccess.withSource(record: record, store: store, grantService: grants) {
                try Data(contentsOf: $0)
            }
            XCTFail("A folder grant does not authorize a linked outside file")
        } catch is FileBridgeFolderError {}
    }

    func testCancellationAfterNonCooperativeReaderDiscardsResult() async throws {
        let record = try store.saveGeneratedFile(name: "source.txt", data: Data("owned".utf8))
        let gate = SourceAccessGate()
        let operation = Task {
            try await DocumentSourceAccess.withSource(record: record, store: store, grantService: nil) { _ in
                await gate.wait()
                return Data("late response".utf8)
            }
        }
        await gate.waitUntilStarted()
        operation.cancel()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("A cancelled source operation must not publish a late result")
        } catch is CancellationError {}
    }
}

private actor SourceAccessGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var reader: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            reader = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        reader?.resume()
        reader = nil
    }
}
