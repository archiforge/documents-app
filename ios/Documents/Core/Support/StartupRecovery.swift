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
    /// 1. App-owned records (`absolutePath == nil`) whose resolved file no
    ///    longer exists are disowned — trashed ones included, a record
    ///    without a file is a lie. External records are left alone; the
    ///    device library prunes vanished external files on its own pass.
    /// 2. Thumbnail cache entries that no longer match a current record's
    ///    key are swept.
    @MainActor
    static func run(store: DocumentStore, thumbnails: ThumbnailStore = .shared) async {
        do {
            for record in try fetchAll(store) where record.absolutePath == nil {
                let url = store.fileBridge.absoluteURL(forRelativePath: record.relativePath)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                try store.disown(record)
                recoveryLog.info("Disowned \(record.displayName): backing file no longer exists")
            }
        } catch {
            recoveryLog.error("Startup recovery failed: \(error.localizedDescription)")
        }

        do {
            var keep: Set<String> = []
            for record in try fetchAll(store) {
                let url = record.absolutePath.map { URL(fileURLWithPath: $0) }
                    ?? store.fileBridge.absoluteURL(forRelativePath: record.relativePath)
                guard let mtime = ThumbnailStore.modificationDate(at: url) else { continue }
                keep.insert(ThumbnailStore.entryName(recordID: record.id, mtime: mtime))
            }
            await thumbnails.sweep(keeping: keep)
        } catch {
            recoveryLog.error("Thumbnail cache sweep failed: \(error.localizedDescription)")
        }
    }

    /// Every record in the store, trashed or not.
    @MainActor
    private static func fetchAll(_ store: DocumentStore) throws -> [DocumentRecord] {
        try store.fetchRecent() + store.fetchTrash()
    }
}
