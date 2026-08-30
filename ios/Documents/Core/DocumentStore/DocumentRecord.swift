import Foundation
import SwiftData

/// SwiftData model describing one document in the store.
///
/// The file itself lives in the app container's Documents directory; only the
/// container-relative path is persisted (`relativePath`).
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

    var kind: DocumentKind {
        DocumentKind(rawValue: kindRaw) ?? .other
    }

    var provenance: Provenance {
        get { Provenance(rawValue: provenanceRaw) ?? .imported }
        set { provenanceRaw = newValue.rawValue }
    }

    /// Absolute URL of the stored file: either an indexed absolute path or
    /// the default app container's Documents directory.
    var fileURL: URL {
        if let absolutePath {
            URL(fileURLWithPath: absolutePath)
        } else {
            FileBridge().absoluteURL(forRelativePath: relativePath)
        }
    }
}
