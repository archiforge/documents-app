import SwiftData
import XCTest
@testable import Documents

/// What the device library admits into the index.
final class DeviceLibraryTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceLibraryTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        container = nil
        super.tearDown()
    }

    @MainActor
    private func makeStore() -> DocumentStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, FolderGrant.self, configurations: configuration)
        return DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
    }

    /// Polls until `condition` holds or the timeout expires; sync passes run
    /// detached from `start(store:)`, so adoption cannot be awaited directly.
    @MainActor
    private func waitFor(
        _ condition: @MainActor () throws -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
    }

    func testDocumentTypesAreIndexable() {
        for name in [
            "Report.pdf", "Letter.doc", "Letter.docx", "Sheet.xlsx", "Deck.pptx",
            "Notes.txt", "Readme.md", "Scan 2026-08-30.png", "Backup.zip", "Form.ofd",
        ] {
            XCTAssertTrue(DeviceLibraryService.isIndexable(filename: name), "\(name) should be indexed")
        }
    }

    func testUnknownFilesStayOutOfTheIndex() {
        for name in ["framework.bin", ".DS_Store", "noextension", "database.sqlite"] {
            XCTAssertFalse(DeviceLibraryService.isIndexable(filename: name), "\(name) must not be indexed")
        }
    }

    @MainActor
    func testProvenanceRoundTripsThroughTheStore() throws {
        let store = makeStore()
        let pdf = TestPDF.make(pageCount: 1)
        let record = try store.saveGeneratedFile(name: "Scan X.pdf", data: pdf, provenance: .scanned)
        XCTAssertEqual(record.provenance, .scanned)
        XCTAssertEqual(record.provenance.caption, "From ‘Scan document’")
    }

    @MainActor
    func testAdoptedExternalFilesResolveToTheirAbsolutePath() throws {
        let store = makeStore()
        let external = URL(fileURLWithPath: "/iCloud/Form.ofd")
        let record = try store.adoptFile(at: external, provenance: .cloud, absolutePath: external.path)
        XCTAssertEqual(record.fileURL.path, "/iCloud/Form.ofd")
        XCTAssertEqual(record.provenance, .cloud)
    }

    @MainActor
    func testDefaultProvenanceIsImportedForCompatibility() {
        let record = DocumentRecord(
            displayName: "a.pdf",
            relativePath: "a.pdf",
            kind: .pdf,
            sizeBytes: 1
        )
        XCTAssertEqual(record.provenance, .imported)
        XCTAssertNil(record.provenance.caption)
    }

    @MainActor
    func testGrantedFolderDocumentsJoinTheIndexInPlace() async throws {
        let store = makeStore()
        let granted = tempRoot.appendingPathComponent("Granted", isDirectory: true)
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try TestPDF.make(pageCount: 1).write(to: granted.appendingPathComponent("Report.pdf"))
        try Data("hello".utf8).write(to: granted.appendingPathComponent("Notes.txt"))

        let grants = FolderGrantService(context: container.mainContext)
        _ = try grants.addGrant(from: granted)

        let library = DeviceLibraryService()
        library.grantService = grants
        defer { library.stop() }
        library.start(store: store)

        try await waitFor { try store.fetchRecent().count == 2 }

        let report = try XCTUnwrap(store.fetchRecent().first { $0.displayName == "Report.pdf" })
        XCTAssertEqual(report.provenance, .device)
        XCTAssertEqual(report.fileURL.path, granted.appendingPathComponent("Report.pdf").path)
        XCTAssertEqual(
            try store.fetchRecent().first { $0.displayName == "Notes.txt" }?.kind,
            .text
        )
    }

    @MainActor
    func testVanishedGrantedFilesLeaveTheIndexOnSync() async throws {
        let store = makeStore()
        let granted = tempRoot.appendingPathComponent("Granted", isDirectory: true)
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try TestPDF.make(pageCount: 1).write(to: granted.appendingPathComponent("Report.pdf"))
        try Data("hello".utf8).write(to: granted.appendingPathComponent("Notes.txt"))

        let grants = FolderGrantService(context: container.mainContext)
        _ = try grants.addGrant(from: granted)

        let library = DeviceLibraryService()
        library.grantService = grants
        defer { library.stop() }
        library.start(store: store)

        try await waitFor { try store.fetchRecent().count == 2 }

        try FileManager.default.removeItem(at: granted.appendingPathComponent("Report.pdf"))
        await library.syncNowAndWait()

        try await waitFor { try store.fetchRecent().count == 1 }
        XCTAssertNil(try store.fetchRecent().first { $0.displayName == "Report.pdf" })
        XCTAssertNotNil(try store.fetchRecent().first { $0.displayName == "Notes.txt" })
    }
}
