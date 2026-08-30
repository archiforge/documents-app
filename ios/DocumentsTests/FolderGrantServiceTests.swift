import SwiftData
import XCTest
@testable import Documents

/// FolderGrant persistence and the security-scope lifecycle behind it.
final class FolderGrantServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderGrantTests-\(UUID().uuidString)", isDirectory: true)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: DocumentRecord.self, FolderGrant.self,
            configurations: configuration
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        container = nil
        super.tearDown()
    }

    @MainActor
    private func makeService() -> FolderGrantService {
        FolderGrantService(context: container.mainContext)
    }

    @MainActor
    private func makeFolder(named name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testAddGrantPersistsGrantAndResolvesFolder() throws {
        let folder = try makeFolder(named: "Granted")
        let service = makeService()

        let grant = try service.addGrant(from: folder)

        XCTAssertEqual(grant.resolvedPath, service.resolvedFolders.first?.path)
        XCTAssertEqual((grant.resolvedPath as NSString).lastPathComponent, "Granted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: grant.resolvedPath))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<FolderGrant>()).count, 1)
    }

    @MainActor
    func testGrantingTheSameFolderTwiceIsIdempotent() throws {
        let folder = try makeFolder(named: "Granted")
        let service = makeService()

        _ = try service.addGrant(from: folder)
        let second = try service.addGrant(from: folder)

        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<FolderGrant>()).count, 1)
        XCTAssertEqual(service.resolvedFolders.count, 1)
        XCTAssertEqual(second.resolvedPath, service.resolvedFolders.first?.path)
    }

    @MainActor
    func testRestoreAccessResolvesPersistedBookmarks() async throws {
        let folder = try makeFolder(named: "Granted")
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        container.mainContext.insert(FolderGrant(displayName: "Granted", bookmarkData: bookmark, resolvedPath: folder.path))
        try container.mainContext.save()

        let service = makeService()
        await service.restoreAccess()

        XCTAssertEqual(service.resolvedFolders.count, 1)
        XCTAssertEqual(service.resolvedFolders.first?.lastPathComponent, "Granted")
        XCTAssertTrue(service.unavailableIDs.isEmpty)
    }

    @MainActor
    func testRestoreAccessIsIdempotent() async throws {
        let folder = try makeFolder(named: "Granted")
        let service = makeService()
        _ = try service.addGrant(from: folder)

        await service.restoreAccess()
        await service.restoreAccess()

        XCTAssertEqual(service.resolvedFolders.count, 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<FolderGrant>()).count, 1)
    }

    @MainActor
    func testRestoreAccessRecordsDeadGrantsAsUnavailable() async throws {
        container.mainContext.insert(FolderGrant(
            displayName: "Dead",
            bookmarkData: Data([0x0D, 0x0E, 0x0A, 0x0D]),
            resolvedPath: "/gone"
        ))
        try container.mainContext.save()

        let service = makeService()
        await service.restoreAccess()

        XCTAssertTrue(service.resolvedFolders.isEmpty)
        XCTAssertEqual(service.unavailableIDs.count, 1)
    }

    @MainActor
    func testRemoveGrantDeletesTheModel() throws {
        let folder = try makeFolder(named: "Granted")
        let service = makeService()
        let grant = try service.addGrant(from: folder)

        try service.removeGrant(grant)

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<FolderGrant>()).isEmpty)
        XCTAssertTrue(service.resolvedFolders.isEmpty)
        XCTAssertTrue(service.unavailableIDs.isEmpty)
    }
}
