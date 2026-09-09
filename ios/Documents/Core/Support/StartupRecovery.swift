import Foundation
import OSLog

private let recoveryLog = Logger(subsystem: "com.docdeck.app", category: "startup-recovery")

/// Launch-time reconciliation of the metadata store against the disk.
///
/// Runs after the temp-artifact sweep and before the device library starts
/// indexing, so the index never keeps records that point at nothing.
/// Recovery is silent by design — a recovery screen would surface internal
/// state users cannot act on — so every failure is logged, never surfaced,
/// and never fatal to launch.
///
/// Orphan container files (files without a record) are deliberately NOT
/// adopted here: `DeviceLibraryService` owns adoption during its sync pass,
/// and exactly one owner may adopt.
enum StartupRecovery {
    /// Reconciles records and the thumbnail cache with the disk:
    /// 1. Pending file transactions are reconciled first: rows that survived
    ///    a deletion or move metadata transaction regain their bytes/path,
    ///    while journals whose rows are gone are finalized conservatively.
    /// 2. App-owned records (`absolutePath == nil`) whose resolved file no
    ///    longer exists are disowned — trashed ones included, a record
    ///    without a file is a lie. External records are left alone; the
    ///    device library prunes vanished external files on its own pass.
    /// 3. Thumbnail cache entries that no longer match a current record's
    ///    key are swept.
    /// 4. Records predating the `createdAt` field get the file's real
    ///    creation date backfilled (unknowable ones retry next launch).
    @MainActor
    static func run(store: DocumentStore, thumbnails: ThumbnailStore = .shared) async {
        var transactionProtectedRecordIDs: Set<UUID>?
        do {
            let appOwnedPairs: [(UUID, String)] = try fetchAll(store).compactMap { record in
                guard record.absolutePath == nil else { return nil }
                return (record.id, record.relativePath)
            }
            let appOwnedPaths = Dictionary(uniqueKeysWithValues: appOwnedPairs)
            var protectedIDs = try store.fileBridge.reconcileDeletionStaging(for: appOwnedPaths)
            protectedIDs.formUnion(try store.fileBridge.reconcileMoveJournals(for: appOwnedPaths))
            transactionProtectedRecordIDs = protectedIDs
        } catch {
            // A journal directory that cannot be enumerated leaves the
            // outcome unknown. Preserve every missing app-owned row for this
            // launch rather than risking disowning recoverable bytes.
            transactionProtectedRecordIDs = nil
            recoveryLog.error("File transaction recovery failed: \(error.localizedDescription)")
        }

        if let transactionProtectedRecordIDs {
            do {
                for record in try fetchAll(store)
                    where record.absolutePath == nil && !transactionProtectedRecordIDs.contains(record.id)
                {
                    let url = store.fileBridge.absoluteURL(forRelativePath: record.relativePath)
                    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                    try store.disown(record)
                    recoveryLog.info("Disowned \(record.displayName): backing file no longer exists")
                }
            } catch {
                recoveryLog.error("Startup recovery failed: \(error.localizedDescription)")
            }
        }

        do {
            var keep: Set<String> = []
            var unstatable: Set<UUID> = []
            for record in try fetchAll(store) {
                let url = record.absolutePath.map { URL(fileURLWithPath: $0) }
                    ?? store.fileBridge.absoluteURL(forRelativePath: record.relativePath)
                guard let mtime = ThumbnailStore.modificationDate(at: url) else {
                    // Unknown ≠ vanished: the file may simply be unreadable
                    // right now (e.g. a granted folder whose security scope
                    // has not been restored yet). Keep its entries; the
                    // device library prunes truly vanished files later.
                    unstatable.insert(record.id)
                    continue
                }
                keep.insert(ThumbnailStore.entryName(recordID: record.id, mtime: mtime))
            }
            await thumbnails.sweep(keeping: keep, preservingIDs: unstatable)
        } catch {
            recoveryLog.error("Thumbnail cache sweep failed: \(error.localizedDescription)")
        }

        do {
            for record in try fetchAll(store) where record.createdAt == nil {
                let url = record.absolutePath.map { URL(fileURLWithPath: $0) }
                    ?? store.fileBridge.absoluteURL(forRelativePath: record.relativePath)
                guard let created = FileBridge.creationDate(at: url) else { continue }
                try store.setCreationDate(created, for: record)
            }
        } catch {
            recoveryLog.error("Creation-date backfill failed: \(error.localizedDescription)")
        }
    }

    /// Every record in the store, trashed or not.
    @MainActor
    private static func fetchAll(_ store: DocumentStore) throws -> [DocumentRecord] {
        try store.fetchRecent() + store.fetchTrash()
    }
}
