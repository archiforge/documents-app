import XCTest
@testable import DocDeck

/// Phase 0 regression: preview/share temp PDFs used to be written straight
/// into the system tmp dir and never removed. The tracker must write,
/// register, and remove them deterministically, and the launch sweep must
/// recover files left by previous runs.
@MainActor
final class TempArtifactTrackerTests: XCTestCase {
    private var root: URL!
    private var tracker: TempArtifactTracker!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocDeckArtifactTests-\(UUID().uuidString)", isDirectory: true)
        tracker = TempArtifactTracker(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        tracker = nil
        super.tearDown()
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testMakeFileWritesAndRegistersArtifact() throws {
        let url = try tracker.makeFile(named: "Scan.pdf", data: Data("%PDF-1.4".utf8))

        XCTAssertEqual(url.deletingLastPathComponent(), root)
        XCTAssertTrue(fileExists(url))
        XCTAssertEqual(tracker.artifacts, [url])
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.4".utf8))
    }

    func testMakeFileDeduplicatesCollidingNames() throws {
        let first = try tracker.makeFile(named: "Scan.pdf", data: Data("a".utf8))
        let second = try tracker.makeFile(named: "Scan.pdf", data: Data("b".utf8))

        XCTAssertEqual(first.lastPathComponent, "Scan.pdf")
        XCTAssertEqual(second.lastPathComponent, "Scan (1).pdf")
        XCTAssertEqual(tracker.artifacts.count, 2)
    }

    func testRemoveDeletesFileAndUnregisters() throws {
        let url = try tracker.makeFile(named: "Preview.pdf", data: Data("x".utf8))

        tracker.remove(url)

        XCTAssertFalse(fileExists(url))
        XCTAssertTrue(tracker.artifacts.isEmpty)
    }

    func testRemoveAllDeletesEveryArtifactOnDisk() throws {
        let a = try tracker.makeFile(named: "A.pdf", data: Data("1".utf8))
        let b = try tracker.makeFile(named: "B.pdf", data: Data("2".utf8))

        tracker.removeAll()

        XCTAssertFalse(fileExists(a))
        XCTAssertFalse(fileExists(b))
        XCTAssertTrue(tracker.artifacts.isEmpty)
    }

    func testFailedWriteRegistersNothing() throws {
        // A read-only container makes the data write fail after the tracker
        // would have registered the artifact.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }

        XCTAssertThrowsError(try tracker.makeFile(named: "X.pdf", data: Data("y".utf8)))
        XCTAssertTrue(tracker.artifacts.isEmpty, "a failed write must not register an artifact")
    }

    func testSweepRemovesOnlyStaleArtifacts() throws {
        let fresh = try tracker.makeFile(named: "Fresh.pdf", data: Data("keep".utf8))
        let stale = root.appendingPathComponent("Stale.pdf")
        try Data("drop".utf8).write(to: stale)
        let staleDate = Date.now.addingTimeInterval(-(TempArtifactTracker.retention + 3600))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: stale.path)

        tracker.sweepStaleArtifacts()

        XCTAssertTrue(fileExists(fresh), "recent artifacts must survive the sweep")
        XCTAssertFalse(fileExists(stale), "stale leftovers must be removed")
        XCTAssertEqual(tracker.artifacts, [fresh])
    }

    func testSweepAtLaunchIsSafeOnAMissingDefaultDirectory() {
        // The default directory may not exist yet; the launch sweep must not
        // throw or create it as a side effect.
        TempArtifactTracker.sweepAtLaunch()
    }
}
