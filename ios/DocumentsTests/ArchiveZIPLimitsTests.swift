import XCTest
import NativeArchives
import ZIPFoundation
@testable import Documents

final class ArchiveZIPLimitsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveZIPLimitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private struct EntrySpec {
        let path: String
        let payload: Data
        let declaredSize: Int64
        let providerReturnsWholePayload: Bool
    }

    private func makeArchive(_ entries: [EntrySpec], named name: String = "fixture.zip") throws -> URL {
        let archive = try XCTUnwrap(Archive(data: Data(), accessMode: .create))
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: entry.declaredSize,
                compressionMethod: .none,
                provider: { position, size in
                    if entry.providerReturnsWholePayload {
                        return entry.payload
                    }
                    let start = Int(position)
                    let end = min(start + size, entry.payload.count)
                    guard start < end else { return Data() }
                    return entry.payload.subdata(in: start..<end)
                }
            )
        }
        let url = tempDirectory.appendingPathComponent(name)
        try XCTUnwrap(archive.data).write(to: url)
        return url
    }

    private func limits(
        maximumEntryCount: Int = 10_000,
        maximumEntryBytes: Int64 = 256 * 1024 * 1024,
        maximumTotalBytes: Int64 = 512 * 1024 * 1024,
        maximumPathLength: Int = 4_096
    ) -> NativeArchiveLimits {
        NativeArchiveLimits(
            maximumEntryCount: maximumEntryCount,
            maximumEntryBytes: maximumEntryBytes,
            maximumTotalBytes: maximumTotalBytes,
            maximumPathLength: maximumPathLength
        )
    }

    func testEntryCountLimitRejectsArchiveAndCleansNewRoot() throws {
        let archive = try makeArchive([
            EntrySpec(path: "one.txt", payload: Data("one".utf8), declaredSize: 3, providerReturnsWholePayload: false),
            EntrySpec(path: "two.txt", payload: Data("two".utf8), declaredSize: 3, providerReturnsWholePayload: false)
        ])
        let output = tempDirectory.appendingPathComponent("entry-count", isDirectory: true)

        XCTAssertThrowsError(try ArchiveService.extract(
            zipAt: archive,
            into: output,
            limits: limits(maximumEntryCount: 1)
        )) { error in
            XCTAssertEqual(error as? ArchiveError, .resourceLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPathLengthLimitRejectsArchiveAndCleansNewRoot() throws {
        let archive = try makeArchive([
            EntrySpec(path: "long-name.txt", payload: Data("x".utf8), declaredSize: 1, providerReturnsWholePayload: false)
        ])
        let output = tempDirectory.appendingPathComponent("path-length", isDirectory: true)

        XCTAssertThrowsError(try ArchiveService.extract(
            zipAt: archive,
            into: output,
            limits: limits(maximumPathLength: 8)
        )) { error in
            XCTAssertEqual(error as? ArchiveError, .resourceLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPerEntryLimitRejectsArchiveAndCleansNewRoot() throws {
        let archive = try makeArchive([
            EntrySpec(path: "large.txt", payload: Data(repeating: 0x41, count: 12), declaredSize: 12, providerReturnsWholePayload: false)
        ])
        let output = tempDirectory.appendingPathComponent("entry-bytes", isDirectory: true)

        XCTAssertThrowsError(try ArchiveService.extract(
            zipAt: archive,
            into: output,
            limits: limits(maximumEntryBytes: 8)
        )) { error in
            XCTAssertEqual(error as? ArchiveError, .resourceLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTotalLimitRemovesEarlierPublishedEntriesButKeepsExistingFiles() throws {
        let archive = try makeArchive([
            EntrySpec(path: "first.txt", payload: Data(repeating: 0x31, count: 5), declaredSize: 5, providerReturnsWholePayload: false),
            EntrySpec(path: "second.txt", payload: Data(repeating: 0x32, count: 5), declaredSize: 5, providerReturnsWholePayload: false)
        ])
        let output = tempDirectory.appendingPathComponent("total-bytes", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("keep.txt")
        let original = Data("leave this file alone".utf8)
        try original.write(to: existing)

        XCTAssertThrowsError(try ArchiveService.extract(
            zipAt: archive,
            into: output,
            limits: limits(maximumTotalBytes: 6)
        )) { error in
            XCTAssertEqual(error as? ArchiveError, .resourceLimitExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("first.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("second.txt").path))
    }

    func testCancelledTaskCleansExtractionAndPreservesExistingFiles() async throws {
        let archive = try makeArchive([
            EntrySpec(path: "cancelled.txt", payload: Data(repeating: 0x43, count: 64 * 1024), declaredSize: 64 * 1024, providerReturnsWholePayload: false)
        ])
        let output = tempDirectory.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("outside.txt")
        let original = Data("pre-existing".utf8)
        try original.write(to: existing)

        let extraction = Task<[String], Error> {
            // Cancel before entering the synchronous ZIPFoundation loop so
            // this regression cannot race a tiny fixture to completion.
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try ArchiveService.extract(zipAt: archive, into: output)
        }
        extraction.cancel()

        do {
            _ = try await extraction.value
            XCTFail("A cancelled extraction should not publish files")
        } catch is CancellationError {
            // Expected: ArchiveService checks cancellation before reading entries.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("cancelled.txt").path))
    }

    func testHeaderSizeMismatchIsRejectedBeforePublishing() throws {
        let payload = Data("more bytes than declared".utf8)
        let archive = try makeArchive([
            EntrySpec(
                path: "mismatch.bin",
                payload: payload,
                declaredSize: 4,
                providerReturnsWholePayload: true
            )
        ])
        let output = tempDirectory.appendingPathComponent("header-mismatch", isDirectory: true)

        XCTAssertThrowsError(try ArchiveService.extract(zipAt: archive, into: output)) { error in
            XCTAssertEqual(error as? ArchiveError, .notReadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSameLengthCorruptedPayloadIsRejectedByCRC() throws {
        let filename = "corrupted.bin"
        let archive = try makeArchive([
            EntrySpec(path: filename, payload: Data("original".utf8), declaredSize: 8, providerReturnsWholePayload: false)
        ])
        var bytes = try Data(contentsOf: archive)
        guard bytes.count >= 30 else {
            XCTFail("ZIP fixture is missing its local file header")
            return
        }
        let filenameLength = Int(bytes[26]) + Int(bytes[27]) * 256
        let extraLength = Int(bytes[28]) + Int(bytes[29]) * 256
        let payloadOffset = 30 + filenameLength + extraLength
        guard payloadOffset < bytes.count else {
            XCTFail("ZIP fixture is missing its local file payload")
            return
        }
        bytes[payloadOffset] ^= 0xFF
        try bytes.write(to: archive, options: .atomic)

        let output = tempDirectory.appendingPathComponent("corrupt-payload", isDirectory: true)
        let existing = output.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing)

        XCTAssertThrowsError(try ArchiveService.extract(zipAt: archive, into: output)) { error in
            XCTAssertEqual(error as? ArchiveError, .notReadable)
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent(filename).path))
    }
}
