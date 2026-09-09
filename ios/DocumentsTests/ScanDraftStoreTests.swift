import Foundation
import XCTest
@testable import Documents

final class ScanDraftStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ScanDraftStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentsScanDraftTests-\(UUID().uuidString)", isDirectory: true)
        store = ScanDraftStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testDraftRestoresPagesAndEditsAcrossStoreInstances() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = Data("front".utf8)
        let second = Data("back".utf8)
        let draft = ScanDraft(
            mode: .idCard,
            pages: [ScanDraftPage(id: firstID, fileName: "page-\(firstID.uuidString).jpg", edit: ScanPageEdit(rotationDegrees: 90))],
            frontPages: [ScanDraftPage(id: secondID, fileName: "page-\(secondID.uuidString).jpg")],
            revision: 1
        )

        let generation = await store.currentGeneration()
        try await store.save(draft, pageData: [firstID: first, secondID: second], generation: generation)
        let restored = try await ScanDraftStore(directory: directory).load()

        XCTAssertEqual(restored?.draft.id, draft.id)
        XCTAssertEqual(restored?.draft.mode, draft.mode)
        XCTAssertEqual(restored?.draft.pages.map(\.id), draft.pages.map(\.id))
        XCTAssertEqual(restored?.draft.frontPages.map(\.id), draft.frontPages.map(\.id))
        XCTAssertEqual(restored?.pageData[firstID], first)
        XCTAssertEqual(restored?.pageData[secondID], second)
        XCTAssertEqual(restored?.pages.first?.edit.rotationDegrees, 90)
    }

    func testFailedUpdateRetainsPreviousManifestAndBytes() async throws {
        let id = UUID()
        let page = ScanDraftPage(id: id, fileName: "page-\(id.uuidString).jpg")
        let original = ScanDraft(mode: .document, pages: [page], revision: 1)
        let generation = await store.currentGeneration()
        try await store.save(original, pageData: [id: Data("original".utf8)], generation: generation)

        var newer = original
        newer.revision = 2
        newer.pages[0].edit.rotateClockwise()

        do {
            try await store.save(newer, pageData: [:], generation: generation)
            XCTFail("Expected a missing page error")
        } catch {
            // expected
        }

        let restored = try await store.load()
        XCTAssertEqual(restored?.draft.id, original.id)
        XCTAssertEqual(restored?.draft.revision, original.revision)
        XCTAssertEqual(restored?.draft.pages.first?.edit, original.pages.first?.edit)
        XCTAssertEqual(restored?.pageData[id], Data("original".utf8))
    }

    func testDiscardRemovesManifestAndPageFiles() async throws {
        let id = UUID()
        let draft = ScanDraft(
            mode: .testPaper,
            pages: [ScanDraftPage(id: id, fileName: "page-\(id.uuidString).jpg")],
            revision: 1
        )
        let generation = await store.currentGeneration()
        try await store.save(draft, pageData: [id: Data("page".utf8)], generation: generation)
        let loaded = try await store.load()
        XCTAssertNotNil(loaded)

        try await store.discard()

        let discarded = try await store.load()
        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDiscardInvalidatesPendingSaveFromPreviousSessionAndProtectsNewSession() async throws {
        let staleGeneration = await store.currentGeneration()
        try await store.discard()

        let staleID = UUID()
        let staleDraft = ScanDraft(
            mode: .document,
            pages: [ScanDraftPage(id: staleID, fileName: "page-\(staleID.uuidString).jpg")],
            revision: 99
        )

        let freshGeneration = await store.currentGeneration()
        let freshID = UUID()
        let freshDraft = ScanDraft(
            mode: .document,
            pages: [ScanDraftPage(id: freshID, fileName: "page-\(freshID.uuidString).jpg")],
            revision: 1
        )
        try await store.save(
            freshDraft,
            pageData: [freshID: Data("fresh".utf8)],
            generation: freshGeneration
        )
        try await store.save(
            staleDraft,
            pageData: [staleID: Data("stale".utf8)],
            generation: staleGeneration
        )

        let restored = try await store.load()
        XCTAssertEqual(restored?.draft.id, freshDraft.id)
        XCTAssertEqual(restored?.pageData[freshID], Data("fresh".utf8))
        XCTAssertNil(restored?.pageData[staleID])
    }

    func testDifferentDraftIDCannotOverwriteTheCurrentSession() async throws {
        let firstID = UUID()
        let firstDraft = ScanDraft(
            id: UUID(),
            mode: .document,
            pages: [ScanDraftPage(id: firstID, fileName: "first.jpg")],
            revision: 1
        )
        let generation = await store.currentGeneration()
        try await store.save(firstDraft, pageData: [firstID: Data("first".utf8)], generation: generation)

        let secondID = UUID()
        let secondDraft = ScanDraft(
            id: UUID(),
            mode: .document,
            pages: [ScanDraftPage(id: secondID, fileName: "second.jpg")],
            revision: 2
        )
        do {
            try await store.save(
                secondDraft,
                pageData: [secondID: Data("second".utf8)],
                generation: generation
            )
            XCTFail("Expected a different draft identity to be rejected")
        } catch {
            XCTAssertEqual(error as? ScanDraftError, .draftIdentityMismatch)
        }

        let restored = try await store.load()
        XCTAssertEqual(restored?.draft.id, firstDraft.id)
        XCTAssertEqual(restored?.pageData[firstID], Data("first".utf8))
    }

    func testLateOldIDAndHighRevisionCannotResurrectAfterNewSession() async throws {
        let oldPageID = UUID()
        let oldDraft = ScanDraft(
            id: UUID(),
            mode: .document,
            pages: [ScanDraftPage(id: oldPageID, fileName: "old.jpg")],
            revision: 1
        )
        let oldGeneration = await store.currentGeneration()
        try await store.save(
            oldDraft,
            pageData: [oldPageID: Data("old".utf8)],
            generation: oldGeneration
        )

        try await store.discard()

        let newPageID = UUID()
        let newDraft = ScanDraft(
            id: UUID(),
            mode: .idCard,
            pages: [ScanDraftPage(id: newPageID, fileName: "new.jpg")],
            revision: 1
        )
        let newGeneration = await store.currentGeneration()
        try await store.save(
            newDraft,
            pageData: [newPageID: Data("new".utf8)],
            generation: newGeneration
        )

        var lateOldDraft = oldDraft
        lateOldDraft.revision = 999
        try await store.save(
            lateOldDraft,
            pageData: [oldPageID: Data("late old".utf8)],
            generation: oldGeneration
        )

        let restored = try await store.load()
        XCTAssertEqual(restored?.draft.id, newDraft.id)
        XCTAssertEqual(restored?.draft.mode, .idCard)
        XCTAssertEqual(restored?.pageData[newPageID], Data("new".utf8))
        XCTAssertNil(restored?.pageData[oldPageID])
    }

    func testPartialValidationFailureLeavesPreviousSnapshotUntouched() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let original = ScanDraft(
            mode: .document,
            pages: [
                ScanDraftPage(id: firstID, fileName: "first.jpg"),
                ScanDraftPage(id: secondID, fileName: "second.jpg")
            ],
            revision: 1
        )
        let initialGeneration = await store.currentGeneration()
        try await store.save(
            original,
            pageData: [firstID: Data("first".utf8), secondID: Data("second".utf8)],
            generation: initialGeneration
        )

        var newer = original
        newer.revision = 2
        newer.pages[0].edit.rotateClockwise()
        do {
            let updateGeneration = await store.currentGeneration()
            try await store.save(
                newer,
                pageData: [firstID: Data("new first".utf8)],
                generation: updateGeneration
            )
            XCTFail("Expected the missing second page to fail before any write")
        } catch ScanDraftError.missingPage(let missingID) {
            XCTAssertEqual(missingID, secondID)
        }

        let restored = try await store.load()
        XCTAssertEqual(restored?.draft.revision, 1)
        XCTAssertEqual(restored?.draft.pages.first?.edit, original.pages.first?.edit)
        XCTAssertEqual(restored?.pageData[firstID], Data("first".utf8))
        XCTAssertEqual(restored?.pageData[secondID], Data("second".utf8))
    }

    func testMetadataOnlyRevisionReusesImmutablePageFiles() async throws {
        let id = UUID()
        let page = ScanDraftPage(id: id, fileName: "page-\(id.uuidString).jpg")
        let original = ScanDraft(mode: .document, pages: [page], revision: 1)
        let bytes = Data("unchanged source".utf8)
        let generation = await store.currentGeneration()
        try await store.save(original, pageData: [id: bytes], generation: generation)

        let firstLoaded = try await store.load()
        let firstSnapshot = try XCTUnwrap(firstLoaded)
        let firstFiles = try pageFiles(in: directory)
        let firstFileBytes = try firstFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }

        var metadataOnly = original
        for revision in 2...5 {
            metadataOnly.revision = revision
            metadataOnly.pages[0].edit.rotateClockwise()
            let metadataGeneration = await store.currentGeneration()
            try await store.save(
                metadataOnly,
                pageData: [id: bytes],
                generation: metadataGeneration
            )
        }

        let secondLoaded = try await store.load()
        let secondSnapshot = try XCTUnwrap(secondLoaded)
        let secondFiles = try pageFiles(in: directory)
        let secondFileBytes = try secondFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }

        XCTAssertEqual(firstSnapshot.draft.pages.first?.fileName, secondSnapshot.draft.pages.first?.fileName)
        XCTAssertEqual(firstFiles.map(\.lastPathComponent), secondFiles.map(\.lastPathComponent))
        XCTAssertEqual(firstFileBytes.map { $0.0 }, secondFileBytes.map { $0.0 })
        XCTAssertEqual(firstFileBytes.map { $0.1 }, secondFileBytes.map { $0.1 })
    }

    private func pageFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("page-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
