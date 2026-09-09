import SwiftData
import UIKit
import XCTest
@testable import Documents

/// Exercises the durable scanner boundary without requiring VisionKit or a
/// Photos library grant. The synthetic JPEGs stand in for already-delivered
/// page bytes; this deliberately bypasses camera/gallery capture while still
/// exercising edits, manifest replacement, relaunch restore, rendering, and
/// generated-document cleanup.
@MainActor
final class ScannerWorkflowTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerWorkflowTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
        try await super.tearDown()
    }

    func testEditedRenamedDraftSurvivesRelaunchAndSuccessfulSaveRemovesRecovery() async throws {
        let draftDirectory = temporaryRoot.appendingPathComponent("Draft", isDirectory: true)
        let firstID = UUID()
        let frontID = UUID()
        let firstBytes = syntheticPageData(label: "BACK", color: .systemBlue)
        let frontBytes = syntheticPageData(label: "FRONT", color: .systemOrange)
        let firstPage = ScanDraftPage(id: firstID, fileName: "back.jpg")
        let frontPage = ScanDraftPage(id: frontID, fileName: "front.jpg")
        var seeded = ScanDraft(
            id: UUID(),
            mode: .idCard,
            pages: [firstPage],
            frontPages: [frontPage],
            revision: 1
        )
        let initialStore = ScanDraftStore(directory: draftDirectory)
        let generation = await initialStore.currentGeneration()
        try await initialStore.save(
            seeded,
            pageData: [firstID: firstBytes, frontID: frontBytes],
            generation: generation
        )

        seeded.pages[0].edit.rotateClockwise()
        seeded.pages[0].edit.crop = ScanCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        seeded.renamedBase = "Travel ID"
        seeded.revision = 2
        try await initialStore.save(
            seeded,
            pageData: [firstID: firstBytes, frontID: frontBytes],
            generation: generation
        )

        // A new actor models a relaunch: the manifest and immutable page
        // files are the only state available to the resumed flow.
        let relaunchedStore = ScanDraftStore(directory: draftDirectory)
        guard let restored = try await relaunchedStore.load() else {
            XCTFail("The saved draft was not recoverable after relaunch")
            return
        }
        XCTAssertEqual(restored.draft.mode, .idCard)
        XCTAssertEqual(restored.draft.renamedBase, "Travel ID")
        XCTAssertEqual(restored.draft.pages.map(\.id), [firstID])
        XCTAssertEqual(restored.draft.frontPages.map(\.id), [frontID])
        XCTAssertEqual(restored.draft.pages.first?.edit.rotationDegrees, 90)
        XCTAssertEqual(
            restored.draft.pages.first?.edit.crop,
            ScanCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        )
        XCTAssertEqual(restored.pageData[firstID], firstBytes)
        XCTAssertEqual(restored.pageData[frontID], frontBytes)

        let documentsDirectory = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: DocumentRecord.self, configurations: configuration)
        let documentStore = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDirectory)
        )
        let renderPages = restored.frontPages + restored.pages
        let pdf = try await ScanRenderPipeline.pdfData(from: renderPages)
        let record = try documentStore.saveGeneratedFile(
            name: "Travel ID.pdf",
            data: pdf,
            provenance: .scanned
        )
        XCTAssertEqual(record.displayName, "Travel ID.pdf")
        let savedPDF = try Data(contentsOf: documentsDirectory.appendingPathComponent(record.relativePath))
        XCTAssertEqual(savedPDF, pdf)

        // Successful generated-document persistence is the explicit point at
        // which the recoverable draft is discarded.
        try await relaunchedStore.discard()
        let afterSave = try await ScanDraftStore(directory: draftDirectory).load()
        XCTAssertNil(afterSave)
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: afterSave != nil, cameraAvailable: false),
            .galleryFlow
        )
    }

    func testCancelledConversionKeepsRecoverableDraft() async throws {
        let draftDirectory = temporaryRoot.appendingPathComponent("CancelledDraft", isDirectory: true)
        let pageID = UUID()
        let bytes = syntheticPageData(label: "RECOVER", color: .systemPurple)
        let draft = ScanDraft(
            mode: .testPaper,
            pages: [ScanDraftPage(id: pageID, fileName: "page.jpg")],
            renamedBase: "Recover Me",
            revision: 1
        )
        let store = ScanDraftStore(directory: draftDirectory)
        let generation = await store.currentGeneration()
        try await store.save(draft, pageData: [pageID: bytes], generation: generation)

        let gate = ConversionGate()
        let conversion = Task { () throws -> Data in
            let rendered = try await ScanRenderPipeline.pdfData(
                from: [ScanPageBuffer(id: pageID, data: bytes)]
            )
            await gate.markReady()
            await gate.waitForRelease()
            try Task.checkCancellation()
            return rendered
        }
        await gate.waitUntilReady()
        conversion.cancel()
        await gate.release()

        do {
            _ = try await conversion.value
            XCTFail("Expected cancellation before generated-file mutation")
        } catch is CancellationError {
            // Expected: the flow's cancellation gate runs before saving a
            // generated document or discarding the draft.
        }

        let recovered = try await ScanDraftStore(directory: draftDirectory).load()
        XCTAssertEqual(recovered?.draft.id, draft.id)
        XCTAssertEqual(recovered?.draft.mode, .testPaper)
        XCTAssertEqual(recovered?.draft.renamedBase, "Recover Me")
        XCTAssertEqual(recovered?.pageData[pageID], bytes)
    }

    func testMultiPageRenderingPerformance() throws {
        let pages = (0..<6).map { index in
            ScanPageBuffer(data: syntheticPageData(label: "PAGE \(index + 1)", color: pageColors[index]))
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do {
                let rendered = try pages.map { try ScanPageRenderer.imageData(for: $0) }
                XCTAssertEqual(rendered.count, pages.count)
                XCTAssertTrue(rendered.allSatisfy { !$0.isEmpty })
            } catch {
                XCTFail("Synthetic multi-page rendering failed: \(error.localizedDescription)")
            }
        }
    }

    private var pageColors: [UIColor] {
        [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed, .systemTeal]
    }

    private func syntheticPageData(label: String, color: UIColor) -> Data {
        let size = CGSize(width: 1_200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 60, width: 420, height: 120))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 60),
                .foregroundColor: UIColor.black,
            ]
            (label as NSString).draw(at: CGPoint(x: 80, y: 84), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9)!
    }
}

private actor ConversionGate {
    private var isReady = false
    private var isReleased = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markReady() {
        isReady = true
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
