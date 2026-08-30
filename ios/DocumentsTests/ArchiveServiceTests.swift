import XCTest
import ZIPFoundation
@testable import DocDeck

final class ArchiveServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeFile(named name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Round-trip

    func testZipRoundTripPreservesNamesAndContents() throws {
        let alpha = try makeFile(named: "alpha.txt", contents: "alpha content")
        let beta = try makeFile(named: "beta.txt", contents: "beta content")

        let zipData = try ArchiveService.zipData(fromFiles: [alpha, beta])
        XCTAssertGreaterThan(zipData.count, 0)

        let zipURL = tempDir.appendingPathComponent("bundle.zip")
        try zipData.write(to: zipURL)

        let outDir = tempDir.appendingPathComponent("unpacked", isDirectory: true)
        let names = try ArchiveService.extract(zipAt: zipURL, into: outDir)

        XCTAssertEqual(Set(names), Set(["alpha.txt", "beta.txt"]))
        XCTAssertEqual(
            try String(contentsOf: outDir.appendingPathComponent("alpha.txt"), encoding: .utf8),
            "alpha content"
        )
        XCTAssertEqual(
            try String(contentsOf: outDir.appendingPathComponent("beta.txt"), encoding: .utf8),
            "beta content"
        )
    }

    func testZipDataStartsWithLocalFileHeader() throws {
        let file = try makeFile(named: "one.txt", contents: "x")

        let zipData = try ArchiveService.zipData(fromFiles: [file])

        XCTAssertEqual(Array([UInt8](zipData).prefix(2)), [0x50, 0x4B], "ZIP magic bytes expected")
    }

    // MARK: - Errors & safety

    func testCompressRequiresAtLeastOneFile() {
        XCTAssertThrowsError(try ArchiveService.zipData(fromFiles: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .nothingToCompress)
        }
    }

    func testUnsafeEntryPathsAreRejected() throws {
        let payload = try makeFile(named: "payload.txt", contents: "x")
        let archive = try XCTUnwrap(Archive(data: Data(), accessMode: .create))
        try archive.addEntry(with: "../evil.txt", fileURL: payload, compressionMethod: .deflate)
        let maliciousZip = tempDir.appendingPathComponent("evil.zip")
        try XCTUnwrap(archive.data).write(to: maliciousZip)

        let outDir = tempDir.appendingPathComponent("guarded", isDirectory: true)
        XCTAssertThrowsError(try ArchiveService.extract(zipAt: maliciousZip, into: outDir)) { error in
            guard case ArchiveError.unsafeEntryPath = error else {
                return XCTFail("Expected unsafeEntryPath, got \(error)")
            }
        }
    }

    func testIsSafePathRules() {
        XCTAssertTrue(ArchiveService.isSafe("folder/file.txt"))
        XCTAssertTrue(ArchiveService.isSafe("file.txt"))
        XCTAssertFalse(ArchiveService.isSafe("../up.txt"))
        XCTAssertFalse(ArchiveService.isSafe("a/../../b.txt"))
        XCTAssertFalse(ArchiveService.isSafe("/absolute.txt"))
        XCTAssertFalse(ArchiveService.isSafe(""))
    }
}
