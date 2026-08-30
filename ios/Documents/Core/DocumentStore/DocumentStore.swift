import Foundation
import Observation
import SwiftData

/// Errors surfaced by `DocumentStore.rename(_:to:)`.
enum DocumentRenameError: LocalizedError, Equatable {
    /// The record indexes a file outside the app container; the store never
    /// mutates files inside granted folders.
    case externalFileNotRenameable
    /// The name is empty after trimming whitespace.
    case emptyName
    /// The final filename exceeds the 255-byte filesystem limit.
    case nameTooLong
    /// The name contains a path separator (`/`) or volume separator (`:`).
    case invalidCharacters
    /// The name starts with a dot, which would hide the file.
    case leadingDot
    /// Another file already has the target name in the same directory.
    case nameAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .externalFileNotRenameable:
            "This document is indexed from another location and can't be renamed here."
        case .emptyName:
            "Enter a name for the document."
        case .nameTooLong:
            "That name is too long."
        case .invalidCharacters:
            "The name can't contain \"/\" or \":\"."
        case .leadingDot:
            "The name can't start with a dot."
        case .nameAlreadyExists:
            "A document with that name already exists."
        }
    }
}

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

    /// Test seam: the clock every mutation reads. Defaults to the wall
    /// clock; tests inject a fixed date so time-dependent behavior (trash
    /// retention, recents) is deterministic.
    var now: () -> Date = Date.init

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
            lastOpenedAt: now(),
            importedAt: now(),
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
            lastOpenedAt: now(),
            importedAt: now(),
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
            lastOpenedAt: now(),
            importedAt: now(),
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
            lastOpenedAt: now(),
            importedAt: now(),
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

    // MARK: - Rename

    /// Renames an app-owned document: moves the file inside its directory,
    /// then persists the record. The new name is the base name — the current
    /// extension is preserved and appended (unless the input already ends
    /// with it). Renaming to the current name is a no-op.
    ///
    /// Order of operations: file move first, record save second. On a save
    /// failure the file is moved back and the record fields restored, so a
    /// failed rename never leaves a half-renamed document.
    func rename(_ record: DocumentRecord, to newBaseName: String) throws {
        guard record.absolutePath == nil else {
            throw DocumentRenameError.externalFileNotRenameable
        }

        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentRenameError.emptyName }
        guard !trimmed.hasPrefix(".") else { throw DocumentRenameError.leadingDot }
        guard !trimmed.contains("/"), !trimmed.contains(":") else { throw DocumentRenameError.invalidCharacters }

        let oldURL = fileBridge.absoluteURL(forRelativePath: record.relativePath)
        let currentName = oldURL.lastPathComponent
        let fileExtension = (currentName as NSString).pathExtension

        var finalName = trimmed
        if !fileExtension.isEmpty && !finalName.lowercased().hasSuffix(".\(fileExtension.lowercased())") {
            finalName += ".\(fileExtension)"
        }
        guard finalName.utf8.count <= 255 else { throw DocumentRenameError.nameTooLong }
        guard finalName != currentName else { return }

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(finalName)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            throw DocumentRenameError.nameAlreadyExists(finalName)
        }

        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let previousDisplayName = record.displayName
        let previousRelativePath = record.relativePath
        record.displayName = finalName
        record.relativePath = Self.relativePath(byReplacingLastComponentOf: record.relativePath, with: finalName)
        do {
            try save()
        } catch {
            try? FileManager.default.moveItem(at: newURL, to: oldURL)
            record.displayName = previousDisplayName
            record.relativePath = previousRelativePath
            throw error
        }
    }

    /// Replaces the last component of a container-relative path, keeping any
    /// subfolders intact ("Folder/Doc.pdf" → "Folder/Renamed.pdf").
    private static func relativePath(byReplacingLastComponentOf path: String, with name: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? name : directory + "/" + name
    }

    // MARK: - Lifecycle

    /// Touches `lastOpenedAt` (recents ordering). Persistence failures are
    /// thrown after rolling the in-memory change back, so UI state and disk
    /// state never diverge silently.
    func recordOpen(_ record: DocumentRecord) throws {
        let previous = record.lastOpenedAt
        record.lastOpenedAt = now()
        do {
            try save()
        } catch {
            record.lastOpenedAt = previous
            throw error
        }
    }

    /// Persists the page count the thumbnail pipeline computed for a PDF, so
    /// rows can badge it without re-parsing the file on every render.
    func setPageCount(_ pageCount: Int, for record: DocumentRecord) throws {
        let previous = record.pageCount
        record.pageCount = pageCount
        do {
            try save()
        } catch {
            record.pageCount = previous
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
        record.trashedAt = now()
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

    /// Permanently deletes trashed records whose retention window
    /// (`TrashPolicy`) has elapsed, and returns how many were purged.
    ///
    /// A record trashed exactly at the boundary survives; only strictly older
    /// records expire. Legacy rows without a `trashedAt` count as expired.
    /// Deletion goes through `delete(_:)`, so external records are disowned
    /// without touching their files.
    @discardableResult
    func purgeExpiredTrash() throws -> Int {
        let cutoff = now().addingTimeInterval(-TrashPolicy.retentionInterval)
        let expired = try fetchTrash().filter { record in
            guard let trashedAt = record.trashedAt else { return true }
            return trashedAt < cutoff
        }
        for record in expired {
            try delete(record)
        }
        return expired.count
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
