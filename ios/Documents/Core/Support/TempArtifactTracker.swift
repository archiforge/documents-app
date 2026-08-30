import Foundation

/// Tracks temporary files created for previews and shares so they are
/// removed deterministically — on share completion, preview dismissal,
/// cancellation, error, and at the next launch — instead of leaking in the
/// system tmp directory.
///
/// The registry is in-memory and confined to the main actor by convention
/// (`@unchecked Sendable` so share-sheet completion handlers can capture
/// it). Artifacts left by a previous run (crash, force quit) are recovered
/// by the launch sweep, which removes anything older than the retention
/// window.
final class TempArtifactTracker: @unchecked Sendable {
    static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DocumentsArtifacts", isDirectory: true)

    /// How long an artifact may survive on disk before the launch sweep
    /// removes it. Generous enough to outlive a slow share extension.
    static let retention: TimeInterval = 7 * 24 * 3600

    private let directory: URL
    private(set) var artifacts: [URL] = []

    // The init runs in a @State default value (nonisolated view init), so it
    // must not touch actor-isolated state.
    nonisolated init(directory: URL = TempArtifactTracker.defaultDirectory) {
        self.directory = directory
    }

    /// Writes `data` under a collision-free name derived from `filename`
    /// and registers the artifact. A failed write registers nothing.
    func makeFile(named filename: String, data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(for: filename)
        try data.write(to: url, options: .atomic)
        artifacts.append(url)
        return url
    }

    func remove(_ url: URL) {
        guard let index = artifacts.firstIndex(of: url) else { return }
        artifacts.remove(at: index)
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() {
        for url in artifacts {
            try? FileManager.default.removeItem(at: url)
        }
        artifacts.removeAll()
    }

    /// Removes on-disk artifacts older than the retention window, tracked or
    /// not. Used at launch for files the registry no longer knows about.
    func sweepStaleArtifacts(now: Date = .now) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .now
            guard now.timeIntervalSince(modified) > Self.retention else { continue }
            try? fileManager.removeItem(at: file)
            artifacts.removeAll { $0 == file }
        }
    }

    /// Launch-time cleanup of artifacts left by previous runs.
    static func sweepAtLaunch() {
        TempArtifactTracker().sweepStaleArtifacts()
    }

    private func uniqueURL(for filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ns = filename as NSString
        var counter = 1
        while true {
            let name = ns.pathExtension.isEmpty
                ? "\(ns.deletingPathExtension) (\(counter))"
                : "\(ns.deletingPathExtension) (\(counter)).\(ns.pathExtension)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            counter += 1
        }
    }
}
