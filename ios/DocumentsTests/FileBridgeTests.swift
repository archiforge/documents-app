import XCTest
@testable import Documents

final class FileBridgeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testUniqueDestinationAvoidsCollisions() throws {
        let bridge = FileBridge(documentsDirectory: tempDir)

        let first = bridge.uniqueDestinationURL(for: "Notes.txt", in: tempDir)
        XCTAssertEqual(first.lastPathComponent, "Notes.txt")

        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = bridge.uniqueDestinationURL(for: "Notes.txt", in: tempDir)
        XCTAssertEqual(second.lastPathComponent, "Notes (1).txt")

        try "x".write(to: second, atomically: true, encoding: .utf8)
        let third = bridge.uniqueDestinationURL(for: "Notes.txt", in: tempDir)
        XCTAssertEqual(third.lastPathComponent, "Notes (2).txt")
    }

    func testUniqueDestinationWithoutExtension() throws {
        let bridge = FileBridge(documentsDirectory: tempDir)

        let first = bridge.uniqueDestinationURL(for: "README", in: tempDir)
        XCTAssertEqual(first.lastPathComponent, "README")

        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = bridge.uniqueDestinationURL(for: "README", in: tempDir)
        XCTAssertEqual(second.lastPathComponent, "README (1)")
    }

    func testRelativeAndAbsoluteRoundTrip() {
        let bridge = FileBridge(documentsDirectory: tempDir)
        let url = tempDir.appendingPathComponent("Sub/File.pdf")

        XCTAssertEqual(bridge.relativePath(for: url), "Sub/File.pdf")
        XCTAssertEqual(
            bridge.absoluteURL(forRelativePath: "Sub/File.pdf").standardizedFileURL.path,
            url.standardizedFileURL.path
        )
    }

    func testImportCopiesAndPreservesContents() throws {
        let documents = tempDir.appendingPathComponent("Docs", isDirectory: true)
        let bridge = FileBridge(documentsDirectory: documents)

        let source = tempDir.appendingPathComponent("Original.txt")
        let payload = "hello documents"
        try payload.write(to: source, atomically: true, encoding: .utf8)

        let imported = try bridge.importFile(from: source)

        XCTAssertEqual(imported.url.lastPathComponent, "Original.txt")
        XCTAssertEqual(imported.sizeBytes, Int64(payload.utf8.count))
        XCTAssertEqual(try String(contentsOf: imported.url, encoding: .utf8), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Source must be copied, not moved")
    }

    func testDeleteFileRemovesOnDiskFile() throws {
        let bridge = FileBridge(documentsDirectory: tempDir)
        let url = try bridge.createFile(named: "Doomed.txt", contents: "bye")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try bridge.deleteFile(atRelativePath: "Doomed.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteFileSucceedsWhenFileIsAlreadyGone() throws {
        let bridge = FileBridge(documentsDirectory: tempDir)

        try bridge.deleteFile(atRelativePath: "NeverExisted.txt")
    }

    func testDeleteFileSurfacesRemovalFailure() throws {
        let bridge = FileBridge(documentsDirectory: tempDir)
        _ = try bridge.createFile(named: "Stuck.txt", contents: "cannot go yet")

        // A read-only container makes the removal fail; the error must
        // surface instead of being swallowed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: tempDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempDir.path
            )
        }

        XCTAssertThrowsError(try bridge.deleteFile(atRelativePath: "Stuck.txt")) { error in
            guard case FileBridgeError.deletionFailed(let path, _) = error else {
                return XCTFail("expected FileBridgeError.deletionFailed, got \(error)")
            }
            XCTAssertEqual(path, "Stuck.txt")
        }
    }
}
