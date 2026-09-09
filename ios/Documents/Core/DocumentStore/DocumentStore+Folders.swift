import Foundation
import OSLog
import SwiftData

private let folderStoreLog = Logger(subsystem: "com.docdeck.app", category: "store-folders")

/// Document-level restrictions for app-owned folder moves.
enum DocumentMoveError: LocalizedError, Equatable {
    case externalFileNotMovable

    var errorDescription: String? {
        switch self {
        case .externalFileNotMovable:
            "Documents indexed from another location cannot be moved here."
        }
    }
}

extension DocumentStore {
    /// Creates a folder inside the injected app Documents root.
    @discardableResult
    func createFolder(named name: String, inRelativePath parentPath: String = "") throws -> String {
        try fileBridge.createFolder(named: name, inRelativePath: parentPath)
    }

    /// Finds an indexed external record by its canonical source path. Browse
    /// uses this before adopting a granted-folder PDF for tools, so opening
    /// the same source repeatedly does not create duplicate metadata rows.
    func record(forAbsolutePath path: String) throws -> DocumentRecord? {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let descriptor = FetchDescriptor<DocumentRecord>()
        return try context.fetch(descriptor).first { record in
            guard let absolutePath = record.absolutePath else { return false }
            return URL(fileURLWithPath: absolutePath).standardizedFileURL.path == canonicalPath
        }
    }

    /// Imports a picked source into a selected app-owned folder and records
    /// the resulting metadata atomically with respect to the new file.
    @discardableResult
    func importFile(from sourceURL: URL, intoRelativeFolder relativePath: String) throws -> DocumentRecord {
        let imported = try fileBridge.importFile(
            from: sourceURL,
            intoRelativeFolder: relativePath
        )
        let record = DocumentRecord(
            displayName: imported.url.lastPathComponent,
            relativePath: fileBridge.relativePath(for: imported.url),
            kind: DocumentKind(filename: imported.url.lastPathComponent),
            sizeBytes: imported.sizeBytes,
            lastOpenedAt: now(),
            importedAt: now(),
            provenance: .imported,
            createdAt: FileBridge.creationDate(at: imported.url)
        )
        try insertAndSave(record, cleanupRelativePath: record.relativePath)
        return record
    }

    /// Moves an app-owned record into an existing folder. The file move is
    /// journaled until the new relative path is saved; a save failure reverses
    /// both changes.
    func move(_ record: DocumentRecord, toRelativeFolder destinationFolderPath: String) throws {
        guard record.absolutePath == nil else {
            throw DocumentMoveError.externalFileNotMovable
        }

        guard let transaction = try fileBridge.stageMove(
            recordID: record.id,
            fromRelativePath: record.relativePath,
            toRelativeFolder: destinationFolderPath
        ) else {
            return
        }

        let previousPath = record.relativePath
        record.relativePath = transaction.destinationRelativePath
        do {
            try save()
        } catch {
            context.rollback()
            record.relativePath = previousPath
            do {
                try fileBridge.restoreMove(transaction)
            } catch {
                folderStoreLog.error(
                    "Move rollback could not restore \(previousPath): \(error.localizedDescription)"
                )
            }
            throw error
        }

        do {
            try fileBridge.finalizeMove(transaction)
        } catch {
            // The metadata commit already succeeded. Leave the journal for
            // StartupRecovery, which can safely remove it on the next launch.
            folderStoreLog.error(
                "Move cleanup deferred for \(transaction.destinationRelativePath): \(error.localizedDescription)"
            )
        }
    }

}
