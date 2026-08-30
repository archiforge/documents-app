import SwiftData
import UIKit
import XCTest
@testable import Documents

/// Generation, caching, sweep, and eviction behavior of the thumbnail cache.
@MainActor
final class ThumbnailStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var documentsDir: URL!
    private var cacheDir: URL!
    private var container: ModelContainer!
    private var store: DocumentStore!
    private var thumbnails: ThumbnailStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailStoreTests-\(UUID().uuidString)", isDirectory: true)
        documentsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        cacheDir = tempRoot.appendingPathComponent("Cache", isDirectory: true)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: DocumentRecord.self, configurations: configuration)
        store = DocumentStore(
            context: container.mainContext,
            fileBridge: FileBridge(documentsDirectory: documentsDir)
        )
        thumbnails = ThumbnailStore(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        documentsDir = nil
        cacheDir = nil
        container = nil
        store = nil
        thumbnails = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeRecord(named name: String, data: Data) throws -> DocumentRecord {
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let url = documentsDir.appendingPathComponent(name)
        try data.write(to: url)
        return try store.adoptFile(at: url)
    }

    private func cacheEntries() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )
    }

    private func sourceURL(_ name: String) -> URL {
        documentsDir.appendingPathComponent(name)
    }

    // MARK: - Generation

    func testPDFGeneratesThumbnailAndPageCountPersists() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 3))

        let image = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        let generated = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(generated.size.width, generated.size.height), 400)
        XCTAssertEqual(try cacheEntries().count, 1, "Generation writes exactly one cache entry")

        let pageCount = await thumbnails.generatedPageCount(for: record.id)
        XCTAssertEqual(pageCount, 3)
        try store.setPageCount(try XCTUnwrap(pageCount), for: record)
        XCTAssertEqual(record.pageCount, 3)
    }

    func testImageGeneratesThumbnail() async throws {
        let png = try XCTUnwrap(
            TestPDF.solidImage(size: CGSize(width: 800, height: 600), color: .red).pngData()
        )
        let record = try makeRecord(named: "Photo.png", data: png)

        let image = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        let generated = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(generated.size.width, generated.size.height), 400)
        XCTAssertEqual(try cacheEntries().count, 1)
    }

    func testNonRenderableKindsReturnNil() async throws {
        let record = try makeRecord(named: "Notes.txt", data: Data("hello".utf8))

        let image = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        XCTAssertNil(image, "Rows keep the SF Symbol glyph for non-renderable kinds")
        XCTAssertEqual(try cacheEntries().count, 0)
    }

    func testMissingFileReturnsNil() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 1))
        try FileManager.default.removeItem(at: sourceURL("Doc.pdf"))

        let image = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        XCTAssertNil(image)
    }

    // MARK: - Cache behavior

    func testCacheHitReturnsWithoutRegenerating() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 1))

        _ = await thumbnails.image(for: record, documentsDirectory: documentsDir)
        let entriesBefore = try cacheEntries()
        XCTAssertEqual(entriesBefore.count, 1)
        let mtimeBefore = try XCTUnwrap(
            ThumbnailStore.modificationDate(at: try XCTUnwrap(entriesBefore.first))
        )

        try await Task.sleep(for: .milliseconds(20))
        let second = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        XCTAssertNotNil(second)
        let entriesAfter = try cacheEntries()
        XCTAssertEqual(entriesAfter.count, 1, "A cache hit must not write a second entry")
        let mtimeAfter = try XCTUnwrap(
            ThumbnailStore.modificationDate(at: try XCTUnwrap(entriesAfter.first))
        )
        XCTAssertEqual(mtimeBefore, mtimeAfter, "A cache hit must not rewrite the entry")
    }

    func testMtimeBumpInvalidatesTheEntry() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 1))
        _ = await thumbnails.image(for: record, documentsDirectory: documentsDir)
        XCTAssertEqual(try cacheEntries().count, 1)

        let bumped = Date().addingTimeInterval(3600)
        try FileManager.default.setAttributes(
            [.modificationDate: bumped],
            ofItemAtPath: sourceURL("Doc.pdf").path
        )
        _ = await thumbnails.image(for: record, documentsDirectory: documentsDir)

        let entries = try cacheEntries()
        XCTAssertEqual(entries.count, 2, "A changed mtime produces a new key; sweep removes the old one")
        let mtime = try XCTUnwrap(ThumbnailStore.modificationDate(at: sourceURL("Doc.pdf")))
        let newKey = ThumbnailStore.entryName(recordID: record.id, mtime: mtime)
        XCTAssertTrue(entries.contains { $0.lastPathComponent == newKey })
    }

    // MARK: - Sweep & eviction

    func testSweepRemovesStaleEntriesAndKeepsCurrentOnes() async throws {
        let record = try makeRecord(named: "Doc.pdf", data: TestPDF.make(pageCount: 1))
        _ = await thumbnails.image(for: record, documentsDirectory: documentsDir)
        let stale = cacheDir.appendingPathComponent("stale-entry-1.png")
        try Data("stale".utf8).write(to: stale)
        XCTAssertEqual(try cacheEntries().count, 2)

        let mtime = try XCTUnwrap(ThumbnailStore.modificationDate(at: sourceURL("Doc.pdf")))
        let currentKey = ThumbnailStore.entryName(recordID: record.id, mtime: mtime)
        await thumbnails.sweep(keeping: [currentKey])

        let entries = try cacheEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries.contains { $0.lastPathComponent == "stale-entry-1.png" })
    }

    func testEvictionKeepsTheCacheWithinTheCap() async throws {
        let tiny = ThumbnailStore(cacheDirectory: cacheDir, maxCacheBytes: 7500)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Three synthetic entries, 9000 bytes total, staggered mtimes.
        for (name, age) in [("a-1.png", 300.0), ("b-2.png", 200.0), ("c-3.png", 100.0)] {
            let url = cacheDir.appendingPathComponent(name)
            try Data(repeating: 7, count: 3000).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }

        let png = try XCTUnwrap(
            TestPDF.solidImage(size: CGSize(width: 800, height: 600), color: .blue).pngData()
        )
        let record = try makeRecord(named: "Photo.png", data: png)
        _ = await tiny.image(for: record, documentsDirectory: documentsDir)

        var total: Int64 = 0
        var names: Set<String> = []
        for entry in try cacheEntries() {
            total += FileBridge.fileSize(at: entry)
            names.insert(entry.lastPathComponent)
        }
        XCTAssertLessThanOrEqual(total, 7500, "Eviction must bring the cache back under the cap")
        XCTAssertFalse(names.contains("a-1.png"), "The oldest entry is evicted first")
        XCTAssertTrue(names.contains("c-3.png"), "Newer entries survive")
    }
}
