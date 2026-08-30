import SwiftData
import XCTest
@testable import Documents

/// Covers the Increment-2 store additions: `saveGeneratedFile` (toolbox,
/// scanner, and converter output) and `adoptFile` (Browse → PDF Tools).
@MainActor
final class StoreGeneratedFileTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreGeneratedFileTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, configurations: configuration)
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        container = nil
        store = nil
        super.tearDown()
    }

    func testSaveGeneratedFileWritesBytesAndRecords() throws {
        let payload = Data("generated pdf bytes".utf8)

        let record = try store.saveGeneratedFile(name: "Scan Result.pdf", data: payload)

        XCTAssertEqual(record.displayName, "Scan Result.pdf")
        XCTAssertEqual(record.kind, .pdf)
        XCTAssertEqual(record.relativePath, "Scan Result.pdf")
        XCTAssertEqual(record.sizeBytes, Int64(payload.count))
        let onDisk = documentsDir.appendingPathComponent("Scan Result.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
        XCTAssertEqual(try Data(contentsOf: onDisk), payload)
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }

    func testSaveGeneratedFileSupportsSubfoldersAndDedupesNames() throws {
        let first = try store.saveGeneratedFile(name: "Images_Report/1.jpg", data: Data([1]))
        let second = try store.saveGeneratedFile(name: "Images_Report/1.jpg", data: Data([2]))

        XCTAssertEqual(first.relativePath, "Images_Report/1.jpg")
        XCTAssertEqual(second.relativePath, "Images_Report/1 (1).jpg")
        XCTAssertEqual(second.displayName, "1 (1).jpg")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: documentsDir.appendingPathComponent("Images_Report/1 (1).jpg").path
        ))
    }

    func testAdoptFileRecordsAnExistingContainerFileWithoutCopying() throws {
        let url = try store.fileBridge.createFile(named: "Existing.pdf", contents: "already here")

        let record = try store.adoptFile(at: url)

        XCTAssertEqual(record.relativePath, "Existing.pdf")
        XCTAssertEqual(record.kind, .pdf)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "already here")
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }
}
