import XCTest
import NativeArchives
import ZIPFoundation
@testable import Documents

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

    private func fixture(named name: String, fileExtension: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let subdirectories: [String?] = ["Fixtures/Archives", "Archives", nil]
        for subdirectory in subdirectories {
            if let bundled = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return bundled
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Archives", isDirectory: true)
            .appendingPathComponent("\(name).\(fileExtension)")
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
        XCTAssertTrue(ArchiveService.isSafe("folder/"))
        XCTAssertTrue(ArchiveService.isSafe("file.txt"))
        XCTAssertFalse(ArchiveService.isSafe("folder//"))
        XCTAssertFalse(ArchiveService.isSafe("../up.txt"))
        XCTAssertFalse(ArchiveService.isSafe("a/../../b.txt"))
        XCTAssertFalse(ArchiveService.isSafe("/absolute.txt"))
        XCTAssertFalse(ArchiveService.isSafe(""))
    }

    // MARK: - Native formats

    func testSevenZipLZMA2ExtractionPreservesBytes() throws {
        let archive = try fixture(named: "lzma2", fileExtension: "7z")
        let output = tempDir.appendingPathComponent("sevenzip", isDirectory: true)

        let names = try ArchiveService.extract(archiveAt: archive, into: output)

        XCTAssertEqual(names, ["container"])
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("container")),
            Data("#!/bin/sh\nexit 0\n".utf8)
        )
    }

    func testRAR4ExtractionPreservesBytes() throws {
        let archive = try fixture(named: "rar4", fileExtension: "rar")
        let output = tempDir.appendingPathComponent("rar4", isDirectory: true)

        let names = try ArchiveService.extract(archiveAt: archive, into: output)

        XCTAssertEqual(names, ["container"])
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("container")),
            Data("#!/bin/sh\nexit 0\n".utf8)
        )
    }

    func testRAR5ExtractionReadsAllRegularEntries() throws {
        let archive = try fixture(named: "rar5", fileExtension: "rar")
        let output = tempDir.appendingPathComponent("rar5", isDirectory: true)

        let names = try ArchiveService.extract(archiveAt: archive, into: output)

        XCTAssertEqual(names.count, 7)
        XCTAssertTrue(names.contains("test.bin"))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("test.bin")).count, 1_200)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("test1.bin")).count, 4_096)
    }

    func testNativeExtractionRejectsOverwriteAndKeepsOriginalBytes() throws {
        let archive = try fixture(named: "lzma2", fileExtension: "7z")
        let output = tempDir.appendingPathComponent("overwrite", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent("container")
        let original = Data("keep me".utf8)
        try original.write(to: destination)

        XCTAssertThrowsError(try ArchiveService.extract(archiveAt: archive, into: output)) { error in
            XCTAssertEqual(error as? ArchiveError, .destinationExists("container"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testNativeExtractionRejectsDanglingSymlinkWithoutFollowingIt() throws {
        let archive = try fixture(named: "lzma2", fileExtension: "7z")
        let output = tempDir.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent("container")
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: "missing-target"
        )

        XCTAssertThrowsError(try ArchiveService.extract(archiveAt: archive, into: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path) == false)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            "missing-target"
        )
    }

    func testNativeExtractionDoesNotOverwriteSymlinkTargetOutsideDestination() throws {
        let archive = try fixture(named: "lzma2", fileExtension: "7z")
        let output = tempDir.appendingPathComponent("symlink-target", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let outside = tempDir.appendingPathComponent("outside.txt")
        let original = Data("keep outside".utf8)
        try original.write(to: outside)
        let destination = output.appendingPathComponent("container")
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try ArchiveService.extract(archiveAt: archive, into: output))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testNativeReaderRejectsUnsafePathInCraftedZIP() throws {
        let archive = try XCTUnwrap(Archive(data: Data(), accessMode: .create))
        try archive.addEntry(
            with: "../escape.txt",
            type: .file,
            uncompressedSize: Int64(1),
            provider: { (_: Int64, size: Int) in Data(repeating: 0x78, count: size) }
        )
        let archiveURL = tempDir.appendingPathComponent("unsafe-native.zip")
        try XCTUnwrap(archive.data).write(to: archiveURL)
        let output = tempDir.appendingPathComponent("unsafe-native-output", isDirectory: true)
        let outside = tempDir.appendingPathComponent("escape.txt")

        XCTAssertThrowsError(try NativeArchiveReader.extract(archiveAt: archiveURL, into: output)) { error in
            guard case NativeArchiveError.unsafeEntryPath("../escape.txt") = error else {
                return XCTFail("Expected native unsafeEntryPath, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testNativeReaderRejectsSymlinkInCraftedZIP() throws {
        let archive = try XCTUnwrap(Archive(data: Data(), accessMode: .create))
        try archive.addEntry(
            with: "link",
            type: .symlink,
            uncompressedSize: Int64(6),
            provider: { (_: Int64, size: Int) in Data(repeating: 0x6f, count: size) }
        )
        let archiveURL = tempDir.appendingPathComponent("symlink-native.zip")
        try XCTUnwrap(archive.data).write(to: archiveURL)
        let output = tempDir.appendingPathComponent("symlink-native-output", isDirectory: true)

        XCTAssertThrowsError(try NativeArchiveReader.extract(archiveAt: archiveURL, into: output)) { error in
            guard case NativeArchiveError.unsupportedEntry("link") = error else {
                return XCTFail("Expected native unsupportedEntry, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNativeReaderRejectsHardLinkAndCleansOutput() throws {
        let archive = try fixture(named: "hardlink", fileExtension: "tar")
        let output = tempDir.appendingPathComponent("hardlink-output", isDirectory: true)

        XCTAssertThrowsError(try NativeArchiveReader.extract(archiveAt: archive, into: output)) { error in
            guard case NativeArchiveError.unsupportedEntry("alias.txt") = error else {
                return XCTFail("Expected native hard-link rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testArchivePublishDestinationIsUniqueAndStagingIsHidden() throws {
        let documents = tempDir.appendingPathComponent("documents", isDirectory: true)
        let bridge = FileBridge(documentsDirectory: documents)
        let first = try bridge.makeArchiveExtractionDestination(named: "bundle")
        try FileManager.default.createDirectory(at: first.url, withIntermediateDirectories: false)

        let second = try bridge.makeArchiveExtractionDestination(named: "bundle")
        XCTAssertEqual(first.relativePath, "Extracted/bundle")
        XCTAssertEqual(second.relativePath, "Extracted/bundle (1)")

        let staging = try bridge.makeArchiveStagingDirectory()
        XCTAssertTrue(staging.path.contains("/.document-extraction-staging/"))
        try Data("partial".utf8).write(to: staging.appendingPathComponent("partial.txt"))
        bridge.sweepArchiveStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testNativeExtractionCleansUpWhenResourceLimitFails() throws {
        let archive = try fixture(named: "lzma2", fileExtension: "7z")
        let output = tempDir.appendingPathComponent("limited", isDirectory: true)

        XCTAssertThrowsError(try NativeArchiveReader.extract(
            archiveAt: archive,
            into: output,
            limits: NativeArchiveLimits(maximumEntryBytes: 1)
        )) { error in
            guard case NativeArchiveError.resourceLimit = error else {
                return XCTFail("Expected resource limit, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testNativeExtractionRejectsMalformedArchiveAndCleansUp() throws {
        let archive = tempDir.appendingPathComponent("malformed.7z")
        try Data("not a 7-Zip archive".utf8).write(to: archive)
        let output = tempDir.appendingPathComponent("malformed-output", isDirectory: true)

        XCTAssertThrowsError(try ArchiveService.extract(archiveAt: archive, into: output)) { error in
            XCTAssertEqual(error as? ArchiveError, .notReadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
