import Foundation
import Observation

/// Indexes every document the app is allowed to see, mirroring the Android
/// app's "all documents on the device" view as closely as iOS sandboxes allow:
///
/// - the app container's Documents tree (imports, scans, tool output), and
/// - iCloud Drive's Documents when a ubiquity container is available.
///
/// Arbitrary silent scans of other apps' storage do not exist on iOS; files
/// from other providers enter the index through the Files-app import picker
/// (which copies them into the container, where they are indexed like any
/// other file). A live `NSMetadataQuery` re-syncs whenever the container tree
/// changes, so newly dropped/created files show up without a manual refresh.
@MainActor
@Observable
final class DeviceLibraryService {
    /// True while a sync pass is running (drives UI spinners).
    private(set) var isIndexing = false
    /// Timestamp of the last completed sync pass.
    private(set) var lastSyncAt: Date?
    /// True when an iCloud ubiquity container was reachable at least once.
    private(set) var iCloudAvailable = false

    private var query: NSMetadataQuery?
    private var resyncTask: Task<Void, Never>?
    private weak var store: DocumentStore?

    /// Only document-like files join the index; `other` (unknown extensions)
    /// stay out so system droppings never pollute the Recent list.
    nonisolated static func isIndexable(filename: String) -> Bool {
        DocumentKind(filename: filename) != .other
    }

    /// Starts indexing and keeps the store in sync with container changes.
    func start(store: DocumentStore) {
        self.store = store
        syncNow()
        startQuery()
    }

    /// Stops observing. The service can be restarted with `start(store:)`.
    func stop() {
        resyncTask?.cancel()
        if let query {
            query.stop()
            self.query = nil
        }
    }

    /// Runs one full sync pass: adopt untracked container files, adopt
    /// iCloud Drive documents, prune external records whose file vanished.
    func syncNow() {
        guard let store, !isIndexing else { return }
        isIndexing = true
        let documentsDirectory = store.fileBridge.documentsDirectory

        Task { @MainActor in
            defer {
                isIndexing = false
                lastSyncAt = .now
            }

            // Enumeration and the ubiquity-URL lookup touch the network /
            // disk; keep them off the main actor, then adopt on main.
            let discovered = await Self.enumerateDocuments(in: documentsDirectory)
            let (ubiquityRoot, ubiquityFiles) = await Self.enumerateUbiquityDocuments()
            if ubiquityRoot != nil {
                iCloudAvailable = true
            }

            do {
                let tracked = try store.trackedFilePaths()
                for url in discovered where !tracked.contains(url.standardizedFileURL.path) {
                    guard Self.isIndexable(filename: url.lastPathComponent) else { continue }
                    _ = try store.adoptFile(at: url, provenance: .device)
                }
                for url in ubiquityFiles where !tracked.contains(url.standardizedFileURL.path) {
                    guard Self.isIndexable(filename: url.lastPathComponent) else { continue }
                    _ = try store.adoptFile(
                        at: url,
                        provenance: .cloud,
                        absolutePath: url.standardizedFileURL.path
                    )
                }
                pruneVanishedExternals(store: store)
            } catch {
                // A failed adoption must not break the pass; the next
                // container change re-triggers a sync.
            }
        }
    }

    // MARK: - Live updates

    private func startQuery() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        guard let documentsURL = store?.fileBridge.documentsDirectory else { return }
        query.searchScopes = [documentsURL.path]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        query.start()
        self.query = query
    }

    /// Container changes arrive in bursts; debounce into one sync pass.
    @objc private func queryDidUpdate() {
        resyncTask?.cancel()
        resyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    // MARK: - Enumeration helpers

    /// All files under `root`, skipping hidden entries and package internals.
    nonisolated private static func enumerateDocuments(in root: URL) async -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        // Fast enumeration is unavailable in async contexts; snapshot first.
        let objects = enumerator.allObjects.compactMap { $0 as? URL }
        for url in objects {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Files under the iCloud Drive Documents root, when a ubiquity
    /// container is signed in and entitled. Returns (root, files).
    nonisolated private static func enumerateUbiquityDocuments() async -> (URL?, [URL]) {
        guard
            let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        else { return (nil, []) }
        let documents = container.appendingPathComponent("Documents")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let regular = files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        return (documents, regular)
    }

    /// External records (absolutePath) whose backing file disappeared are
    /// removed; container records are owned by the trash flow and stay.
    /// A failed disown keeps the record; the next prune cycle retries.
    private func pruneVanishedExternals(store: DocumentStore) {
        guard let all = try? store.fetchRecent() else { return }
        for record in all {
            guard let absolutePath = record.absolutePath else { continue }
            if !FileManager.default.fileExists(atPath: absolutePath) {
                try? store.disown(record)
            }
        }
    }
}
