import SwiftData
import XCTest
@testable import DocDeck

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
        container = try! ModelContainer(for: DocumentRecord.self, configurations: configuration)
        return DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
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
}
