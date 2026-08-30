import SwiftData
import XCTest
@testable import Documents

/// Renames move the file first, then persist the record. Anything short of a
/// fully persisted rename must leave both file and record exactly as they
/// were — a half-renamed document is worse than a failed rename.
@MainActor
final class DocumentStoreRenameTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var sourcesDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsRenameTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        sourcesDir = tempRoot.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

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
        sourcesDir = nil
        container = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private struct InjectedSaveFailure: Error {}

    private func makeSourceFile(named name: String, contents: String = "Documents test file") throws -> URL {
        let url = sourcesDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(relativePath).path)
    }

    // MARK: - Success round-trip

    func testRenameMovesFileAndUpdatesRecord() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Report.pdf", contents: "report bytes"))

        try store.rename(record, to: " Quarterly ")

        XCTAssertFalse(fileExists("Report.pdf"))
        XCTAssertTrue(fileExists("Quarterly.pdf"))
        XCTAssertEqual(
            try String(contentsOf: documentsDir.appendingPathComponent("Quarterly.pdf"), encoding: .utf8),
            "report bytes",
            "the file content must survive the move"
        )
        XCTAssertEqual(record.displayName, "Quarterly.pdf")
        XCTAssertEqual(record.relativePath, "Quarterly.pdf")
        XCTAssertEqual(record.kind, .pdf, "preserving the extension preserves the kind")

        // The renamed record still resolves and opens.
        XCTAssertEqual(try store.record(forRelativePath: "Quarterly.pdf")?.id, record.id)
        try store.recordOpen(record)
        XCTAssertEqual(try store.fetchRecent().map(\.id), [record.id])
    }

    func testRenameKeepsSubfolderOfGeneratedFiles() throws {
        let record = try store.saveGeneratedFile(name: "Folder/Doc.pdf", data: Data("nested".utf8))
        XCTAssertEqual(record.relativePath, "Folder/Doc.pdf")

        try store.rename(record, to: "Renamed")

        XCTAssertEqual(record.relativePath, "Folder/Renamed.pdf")
        XCTAssertTrue(fileExists("Folder/Renamed.pdf"))
        XCTAssertFalse(fileExists("Folder/Doc.pdf"))
    }

    func testRenameAcceptsNameAlreadyCarryingTheExtension() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Report.pdf"))

        try store.rename(record, to: "Quarterly.pdf")

        XCTAssertEqual(record.displayName, "Quarterly.pdf", "no doubled extension")
        XCTAssertTrue(fileExists("Quarterly.pdf"))
    }

    func testRenameToTheSameNameIsANoop() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Report.pdf"))
        // A no-op must not even reach the save, so a poisoned save proves it.
        store.saveFailureForTesting = InjectedSaveFailure()

        try store.rename(record, to: "Report")

        XCTAssertTrue(fileExists("Report.pdf"))
        XCTAssertEqual(record.displayName, "Report.pdf")
        XCTAssertEqual(record.relativePath, "Report.pdf")
        store.saveFailureForTesting = nil
    }

    func testRenameAllowsNameAtThe255ByteLimit() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Report.pdf"))
        let base = String(repeating: "a", count: 251) // + ".pdf" = exactly 255 bytes

        try store.rename(record, to: base)

        XCTAssertTrue(fileExists(base + ".pdf"))
        XCTAssertEqual(record.displayName.utf8.count, 255)
    }

    // MARK: - Validation

    func testRenameRejectsExistingTargetNameAndLeavesFileUntouched() throws {
        _ = try store.importFile(from: makeSourceFile(named: "A.txt"))
        let b = try store.importFile(from: makeSourceFile(named: "B.txt"))

        XCTAssertThrowsError(try store.rename(b, to: "A")) { error in
            XCTAssertEqual(error as? DocumentRenameError, .nameAlreadyExists("A.txt"))
        }

        XCTAssertTrue(fileExists("B.txt"), "a rejected rename must not move the file")
        XCTAssertFalse(fileExists("A (1).txt"), "never dedupe silently")
        XCTAssertEqual(b.displayName, "B.txt")
        XCTAssertEqual(b.relativePath, "B.txt")
    }

    func testRenameRejectsInvalidNames() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Valid.pdf"))
        let cases: [(String, DocumentRenameError)] = [
            ("", .emptyName),
            ("   ", .emptyName),
            ("\t\n", .emptyName),
            ("With/Slash", .invalidCharacters),
            ("With:Colon", .invalidCharacters),
            (".hidden", .leadingDot),
            (String(repeating: "a", count: 256), .nameTooLong), // 256 + ".pdf" > 255
        ]

        for (input, expected) in cases {
            XCTAssertThrowsError(try store.rename(record, to: input)) { error in
                XCTAssertEqual(error as? DocumentRenameError, expected, "input: \(input.debugDescription)")
            }
        }

        XCTAssertTrue(fileExists("Valid.pdf"))
        XCTAssertEqual(record.displayName, "Valid.pdf")
        XCTAssertEqual(record.relativePath, "Valid.pdf")
    }

    func testRenameRejectsExternalRecords() throws {
        let externalURL = try makeSourceFile(named: "External.pdf", contents: "external bytes")
        let record = try store.adoptFile(at: externalURL, absolutePath: externalURL.path)

        XCTAssertThrowsError(try store.rename(record, to: "Mine")) { error in
            XCTAssertEqual(error as? DocumentRenameError, .externalFileNotRenameable)
        }

        XCTAssertEqual(
            try String(contentsOf: externalURL, encoding: .utf8),
            "external bytes",
            "the store never mutates files inside granted folders"
        )
        XCTAssertEqual(record.displayName, "External.pdf")
    }

    // MARK: - Save-failure rollback

    func testRenameRestoresFileAndRecordWhenSaveFails() throws {
        let record = try store.importFile(from: makeSourceFile(named: "Precious.pdf", contents: "precious bytes"))
        store.saveFailureForTesting = InjectedSaveFailure()

        XCTAssertThrowsError(try store.rename(record, to: "Doomed"))

        XCTAssertFalse(fileExists("Doomed.pdf"), "the moved file must be restored")
        XCTAssertTrue(fileExists("Precious.pdf"))
        XCTAssertEqual(
            try String(contentsOf: documentsDir.appendingPathComponent("Precious.pdf"), encoding: .utf8),
            "precious bytes"
        )
        XCTAssertEqual(record.displayName, "Precious.pdf", "record fields must roll back")
        XCTAssertEqual(record.relativePath, "Precious.pdf")

        store.saveFailureForTesting = nil
        try store.rename(record, to: "Recovered")
        XCTAssertTrue(fileExists("Recovered.pdf"), "a failed rename must not poison the next one")
        XCTAssertEqual(record.displayName, "Recovered.pdf")
    }
}
