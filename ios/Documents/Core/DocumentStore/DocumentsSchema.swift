import Foundation
import SwiftData

// MARK: - Schema V1

/// The original shipped schema: documents indexed in the app container plus
/// user-granted folders. Field layout is frozen — it is the migration source
/// for every store created before schema versioning existed.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [DocumentRecord.self, FolderGrant.self] }

    /// One document in the store, exactly as persisted before versioning.
    @Model
    final class DocumentRecord {
        @Attribute(.unique) var id: UUID
        var displayName: String
        /// Container-relative path inside the Documents directory.
        var relativePath: String
        /// Stored as the raw enum value so the schema stays migration-friendly.
        var kindRaw: String
        var sizeBytes: Int64
        var lastOpenedAt: Date
        var importedAt: Date
        var isFavorite: Bool
        var isTrashed: Bool
        var trashedAt: Date?
        /// Origin of the file (scanner, import, converter, device index).
        /// Defaults keep SwiftData's lightweight migration happy for stores
        /// created before the field existed.
        var provenanceRaw: String = Provenance.imported.rawValue
        /// Absolute path for files indexed outside the app container
        /// (e.g. iCloud Drive). nil = `relativePath` is container-relative.
        var absolutePath: String? = nil

        init(
            id: UUID = UUID(),
            displayName: String,
            relativePath: String,
            kind: DocumentKind,
            sizeBytes: Int64,
            lastOpenedAt: Date = .now,
            importedAt: Date = .now,
            isFavorite: Bool = false,
            isTrashed: Bool = false,
            trashedAt: Date? = nil,
            provenance: Provenance = .imported,
            absolutePath: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.relativePath = relativePath
            self.kindRaw = kind.rawValue
            self.sizeBytes = sizeBytes
            self.lastOpenedAt = lastOpenedAt
            self.importedAt = importedAt
            self.isFavorite = isFavorite
            self.isTrashed = isTrashed
            self.trashedAt = trashedAt
            self.provenanceRaw = provenance.rawValue
            self.absolutePath = absolutePath
        }
    }

    /// A user-granted folder whose contents the device library indexes in
    /// place (no copy), persisted exactly as before versioning.
    @Model
    final class FolderGrant {
        @Attribute(.unique) var id: UUID
        var displayName: String
        /// Security-scoped bookmark data recreating access to the folder.
        var bookmarkData: Data
        /// Absolute path the bookmark last resolved to. Refreshed on every
        /// successful resolve; the bookmark, not this path, is the access grant.
        var resolvedPath: String
        var addedAt: Date

        init(
            id: UUID = UUID(),
            displayName: String,
            bookmarkData: Data,
            resolvedPath: String,
            addedAt: Date = .now
        ) {
            self.id = id
            self.displayName = displayName
            self.bookmarkData = bookmarkData
            self.resolvedPath = resolvedPath
            self.addedAt = addedAt
        }
    }
}

// MARK: - Schema V2

/// Current schema. Adds `pageCount` to documents so PDF rows can badge their
/// page count without re-parsing the file on every render.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [DocumentRecord.self, FolderGrant.self] }

    /// SwiftData model describing one document in the store.
    ///
    /// The file itself lives in the app container's Documents directory; only
    /// the container-relative path is persisted (`relativePath`).
    @Model
    final class DocumentRecord {
        @Attribute(.unique) var id: UUID
        var displayName: String
        /// Container-relative path inside the Documents directory.
        var relativePath: String
        /// Stored as the raw enum value so the schema stays migration-friendly.
        var kindRaw: String
        var sizeBytes: Int64
        var lastOpenedAt: Date
        var importedAt: Date
        var isFavorite: Bool
        var isTrashed: Bool
        var trashedAt: Date?
        /// Origin of the file (scanner, import, converter, device index).
        /// Defaults keep SwiftData's lightweight migration happy for stores
        /// created before the field existed.
        var provenanceRaw: String = Provenance.imported.rawValue
        /// Absolute path for files indexed outside the app container
        /// (e.g. iCloud Drive). nil = `relativePath` is container-relative.
        var absolutePath: String? = nil
        /// PDF page count, filled once by the thumbnail pipeline so rows can
        /// badge without re-parsing the file. nil = not a PDF or not yet known.
        var pageCount: Int? = nil

        init(
            id: UUID = UUID(),
            displayName: String,
            relativePath: String,
            kind: DocumentKind,
            sizeBytes: Int64,
            lastOpenedAt: Date = .now,
            importedAt: Date = .now,
            isFavorite: Bool = false,
            isTrashed: Bool = false,
            trashedAt: Date? = nil,
            provenance: Provenance = .imported,
            absolutePath: String? = nil,
            pageCount: Int? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.relativePath = relativePath
            self.kindRaw = kind.rawValue
            self.sizeBytes = sizeBytes
            self.lastOpenedAt = lastOpenedAt
            self.importedAt = importedAt
            self.isFavorite = isFavorite
            self.isTrashed = isTrashed
            self.trashedAt = trashedAt
            self.provenanceRaw = provenance.rawValue
            self.absolutePath = absolutePath
            self.pageCount = pageCount
        }

        var kind: DocumentKind {
            DocumentKind(rawValue: kindRaw) ?? .other
        }

        var provenance: Provenance {
            get { Provenance(rawValue: provenanceRaw) ?? .imported }
            set { provenanceRaw = newValue.rawValue }
        }

        /// Absolute URL of the stored file: either an indexed absolute path
        /// or the default app container's Documents directory.
        var fileURL: URL {
            if let absolutePath {
                URL(fileURLWithPath: absolutePath)
            } else {
                FileBridge().absoluteURL(forRelativePath: relativePath)
            }
        }
    }

    /// SwiftData model for a user-granted folder whose contents the device
    /// library indexes in place (no copy).
    ///
    /// iOS grants ongoing read access to a Files-picked folder only through a
    /// persisted security-scoped bookmark, so `bookmarkData` is the grant
    /// itself; `resolvedPath` is the folder's last resolved absolute location.
    @Model
    final class FolderGrant {
        @Attribute(.unique) var id: UUID
        var displayName: String
        /// Security-scoped bookmark data recreating access to the folder.
        var bookmarkData: Data
        /// Absolute path the bookmark last resolved to. Refreshed on every
        /// successful resolve; the bookmark, not this path, is the access grant.
        var resolvedPath: String
        var addedAt: Date

        init(
            id: UUID = UUID(),
            displayName: String,
            bookmarkData: Data,
            resolvedPath: String,
            addedAt: Date = .now
        ) {
            self.id = id
            self.displayName = displayName
            self.bookmarkData = bookmarkData
            self.resolvedPath = resolvedPath
            self.addedAt = addedAt
        }
    }
}

// MARK: - Migration plan

/// Moves stores from the original schema to the current one.
enum DocumentsSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}

// MARK: - Compatibility aliases

/// The current document model. Call sites stay version-agnostic; only the
/// container and migration plan name schema versions explicitly.
typealias DocumentRecord = SchemaV2.DocumentRecord

/// The current folder-grant model (see `DocumentRecord` alias).
typealias FolderGrant = SchemaV2.FolderGrant
