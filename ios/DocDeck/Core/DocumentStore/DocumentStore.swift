import Foundation
import Observation
import SwiftData

/// The document store service.
///
/// Implemented as a `@MainActor` class (the brief allows actor OR @MainActor
/// class): SwiftData's `ModelContext` is main-actor friendly and every UI
/// caller is main-actor isolated, so this keeps the bridging simple.
@MainActor
@Observable
final class DocumentStore {
    let context: ModelContext
    let fileBridge: FileBridge

    /// Test seam: when non-nil, the next save fails with this error. Lets
    /// regression tests prove that persistence failures surface (and roll
    /// back in-memory state) without relying on store-specific quirks.
    var saveFailureForTesting: (any Error)?

    init(context: ModelContext, fileBridge: FileBridge = FileBridge()) {
        self.context = context
        self.fileBridge = fileBridge
    }

    // MARK: - Import & create

    /// Copies the picked file into the container Documents directory
    /// (deduping the name) and records it.
    @discardableResult
    func importFile(from sourceURL: URL) throws -> DocumentRecord {
        let imported = try fileBridge.importFile(from: sourceURL)
        let record = DocumentRecord(
            displayName: imported.url.lastPathComponent,
            relativePath: fileBridge.relativePath(for: imported.url),
            kind: DocumentKind(filename: imported.url.lastPathComponent),
            sizeBytes: imported.sizeBytes,
            provenance: .imported
        )
        context.insert(record)
        try context.save()
        return record
    }

    /// Saves bytes produced by the toolbox/scanner/converters into the
    /// container and records them. `name` may include subfolders.
    @discardableResult
    func saveGeneratedFile(
        name: String,
        data: Data,
        provenance: Provenance = .created
    ) throws -> DocumentRecord {
        let url = try fileBridge.writeGeneratedFile(named: name, data: data)
        let record = DocumentRecord(
            displayName: url.lastPathComponent,
            relativePath: fileBridge.relativePath(for: url),
            kind: DocumentKind(filename: url.lastPathComponent),
            sizeBytes: FileBridge.fileSize(at: url),
            provenance: provenance
        )
        context.insert(record)
        try context.save()
        return record
    }

    /// Records a file that already lives in the container (e.g. picked from
    /// Browse or discovered by the device library) without copying it again.
    @discardableResult
    func adoptFile(
        at url: URL,
        provenance: Provenance = .imported,
        absolutePath: String? = nil
    ) throws -> DocumentRecord {
        let record = DocumentRecord(
            displayName: url.lastPathComponent,
            relativePath: fileBridge.relativePath(for: url),
            kind: DocumentKind(filename: url.lastPathComponent),
            sizeBytes: FileBridge.fileSize(at: url),
            provenance: provenance,
            absolutePath: absolutePath
        )
        context.insert(record)
        try context.save()
        return record
    }

    /// Creates a brand-new text document in the container and records it.
    /// Used by the "New Document" tool.
    @discardableResult
    func createDocument(named name: String, fileExtension: String, contents: String = "") throws -> DocumentRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed
        let suffix = ".\(fileExtension)"
        let filename = baseName.hasSuffix(suffix) ? baseName : baseName + suffix

        let url = try fileBridge.createFile(named: filename, contents: contents)
        let record = DocumentRecord(
            displayName: url.lastPathComponent,
            relativePath: fileBridge.relativePath(for: url),
            kind: DocumentKind(filename: url.lastPathComponent),
            sizeBytes: FileBridge.fileSize(at: url),
            provenance: .created
        )
        context.insert(record)
        try context.save()
        return record
    }

    /// Every tracked, non-trashed record keyed by resolved file path — the
    /// device library uses this to avoid adopting files twice.
    func trackedFilePaths() throws -> Set<String> {
        let descriptor = FetchDescriptor<DocumentRecord>()
        let records = try context.fetch(descriptor)
        return Set(records.map(\.fileURL.standardizedFileURL.path))
    }

    // MARK: - Lifecycle

    /// Touches `lastOpenedAt` (recents ordering). Persistence failures are
    /// thrown after rolling the in-memory change back, so UI state and disk
    /// state never diverge silently.
    func recordOpen(_ record: DocumentRecord) throws {
        let previous = record.lastOpenedAt
        record.lastOpenedAt = .now
        do {
            try save()
        } catch {
            record.lastOpenedAt = previous
            throw error
        }
    }

    func toggleFavorite(_ record: DocumentRecord) throws {
        let previous = record.isFavorite
        record.isFavorite.toggle()
        do {
            try save()
        } catch {
            record.isFavorite = previous
            throw error
        }
    }

    /// Moves to trash. The on-disk file is kept.
    func trash(_ record: DocumentRecord) throws {
        guard !record.isTrashed else { return }
        let previousTrashed = record.isTrashed
        let previousDate = record.trashedAt
        record.isTrashed = true
        record.trashedAt = .now
        do {
            try save()
        } catch {
            record.isTrashed = previousTrashed
            record.trashedAt = previousDate
            throw error
        }
    }

    func restore(_ record: DocumentRecord) throws {
        let previousTrashed = record.isTrashed
        let previousDate = record.trashedAt
        record.isTrashed = false
        record.trashedAt = nil
        do {
            try save()
        } catch {
            record.isTrashed = previousTrashed
            record.trashedAt = previousDate
            throw error
        }
    }

    /// Removes a record from the index without touching any on-disk file
    /// (used when an indexed external file disappears).
    func disown(_ record: DocumentRecord) throws {
        context.delete(record)
        do {
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Permanently deletes a record and — when the store owns the file — the
    /// file itself, addressed by the record's resolved app URL.
    ///
    /// Ownership rules: an app-owned record's container file is removed via
    /// its container-relative path. A record carrying an `absolutePath` is
    /// *disowned only*: the store never deletes through the relative path of
    /// an external record, because a same-named app-owned file could be hit
    /// instead. The external file itself stays on disk unless a future,
    /// explicitly user-authorized flow removes it.
    func delete(_ record: DocumentRecord) throws {
        if record.absolutePath == nil {
            try fileBridge.deleteFile(atRelativePath: record.relativePath)
        }
        context.delete(record)
        do {
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Deletes every trashed record through `delete(_:)`, so the same
    /// ownership rules apply.
    func emptyTrash() throws {
        for record in try fetchTrash() {
            try delete(record)
        }
    }

    // MARK: - Queries

    func fetchRecent() throws -> [DocumentRecord] {
        let predicate = #Predicate<DocumentRecord> { !$0.isTrashed }
        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchFavorites() throws -> [DocumentRecord] {
        let predicate = #Predicate<DocumentRecord> { $0.isFavorite && !$0.isTrashed }
        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchTrash() throws -> [DocumentRecord] {
        let predicate = #Predicate<DocumentRecord> { $0.isTrashed }
        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Finds the tracked record for a container file, if any (used by Browse).
    func record(forRelativePath path: String) throws -> DocumentRecord? {
        let descriptor = FetchDescriptor<DocumentRecord>(
            predicate: #Predicate { $0.relativePath == path }
        )
        return try context.fetch(descriptor).first
    }

    private func save() throws {
        if let saveFailureForTesting {
            throw saveFailureForTesting
        }
        try context.save()
    }
}
