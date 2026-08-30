import Foundation
import SwiftData
import XCTest
@testable import Documents

/// Schema migration must be proven against a real on-disk store: in-memory
/// stores never run the migration path. These tests seed a store with the V1
/// schema, drop the container, then reopen it through the V2 container with
/// the migration plan and assert every stored field survived.
@MainActor
final class DocumentsSchemaMigrationTests: XCTestCase {
    private var tempRoot: URL!
    private var storeURL: URL!

    private let documentID = UUID()
    private let grantID = UUID()
    private let lastOpenedAt = Date(timeIntervalSince1970: 1_750_000_000)
    private let importedAt = Date(timeIntervalSince1970: 1_749_000_000)
    private let trashedAt = Date(timeIntervalSince1970: 1_750_500_000)
    private let addedAt = Date(timeIntervalSince1970: 1_748_000_000)
    private let bookmarkData = Data([0x62, 0x6F, 0x6F, 0x6B])

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        storeURL = tempRoot.appendingPathComponent("Documents.store")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        storeURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates an on-disk store with the V1 schema and seeds one of each
    /// model, then drops every reference so the next container open must
    /// load (and migrate) the persisted data.
    private func seedV1Store() throws {
        let configuration = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV1.self),
            configurations: configuration
        )
        let context = ModelContext(container)

        let document = SchemaV1.DocumentRecord(
            id: documentID,
            displayName: "Annual Report.pdf",
            relativePath: "Reports/Annual Report.pdf",
            kind: .pdf,
            sizeBytes: 42_024,
            lastOpenedAt: lastOpenedAt,
            importedAt: importedAt,
            isFavorite: true,
            isTrashed: true,
            trashedAt: trashedAt,
            provenance: .scanned,
            absolutePath: nil
        )
        let grant = SchemaV1.FolderGrant(
            id: grantID,
            displayName: "Paperwork",
            bookmarkData: bookmarkData,
            resolvedPath: "/Users/shared/Paperwork",
            addedAt: addedAt
        )
        context.insert(document)
        context.insert(grant)
        try context.save()
    }

    /// Reopens the seeded store through the V2 schema plus migration plan.
    private func openMigratedStore() throws -> ModelContainer {
        let configuration = ModelConfiguration(url: storeURL)
        return try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            migrationPlan: DocumentsSchemaMigrationPlan.self,
            configurations: configuration
        )
    }

    // MARK: - Migration

    func testV1StoreMigratesToV2PreservingEveryField() throws {
        try seedV1Store()
        let container = try openMigratedStore()
        let context = container.mainContext

        let documents = try context.fetch(FetchDescriptor<DocumentRecord>())
        XCTAssertEqual(documents.count, 1)
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(document.id, documentID)
        XCTAssertEqual(document.displayName, "Annual Report.pdf")
        XCTAssertEqual(document.relativePath, "Reports/Annual Report.pdf")
        XCTAssertEqual(document.kindRaw, DocumentKind.pdf.rawValue)
        XCTAssertEqual(document.kind, .pdf)
        XCTAssertEqual(document.sizeBytes, 42_024)
        XCTAssertEqual(document.lastOpenedAt, lastOpenedAt)
        XCTAssertEqual(document.importedAt, importedAt)
        XCTAssertTrue(document.isFavorite)
        XCTAssertTrue(document.isTrashed)
        XCTAssertEqual(document.trashedAt, trashedAt)
        XCTAssertEqual(document.provenanceRaw, Provenance.scanned.rawValue)
        XCTAssertEqual(document.provenance, .scanned)
        XCTAssertNil(document.absolutePath)
        XCTAssertNil(document.pageCount, "new V2 fields must default to nil after migration")

        let grants = try context.fetch(FetchDescriptor<FolderGrant>())
        XCTAssertEqual(grants.count, 1)
        let grant = try XCTUnwrap(grants.first)
        XCTAssertEqual(grant.id, grantID)
        XCTAssertEqual(grant.displayName, "Paperwork")
        XCTAssertEqual(grant.bookmarkData, bookmarkData)
        XCTAssertEqual(grant.resolvedPath, "/Users/shared/Paperwork")
        XCTAssertEqual(grant.addedAt, addedAt)
    }

    func testMigratedStoreAcceptsV2Writes() throws {
        try seedV1Store()
        let container = try openMigratedStore()
        let context = container.mainContext

        let migrated = try XCTUnwrap(try context.fetch(FetchDescriptor<DocumentRecord>()).first)
        migrated.pageCount = 12

        let fresh = DocumentRecord(
            displayName: "Fresh.pdf",
            relativePath: "Fresh.pdf",
            kind: .pdf,
            sizeBytes: 100,
            lastOpenedAt: importedAt,
            importedAt: importedAt,
            pageCount: 3
        )
        context.insert(fresh)
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<DocumentRecord>())
        XCTAssertEqual(refetched.count, 2)
        XCTAssertEqual(refetched.first { $0.id == documentID }?.pageCount, 12)
        XCTAssertEqual(refetched.first { $0.id == fresh.id }?.pageCount, 3)
    }
}
