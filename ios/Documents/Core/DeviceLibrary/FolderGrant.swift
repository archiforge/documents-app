import Foundation
import SwiftData

/// SwiftData model for a user-granted folder whose contents the device
/// library indexes in place (no copy).
///
/// iOS grants ongoing read access to a Files-picked folder only through a
/// persisted security-scoped bookmark, so `bookmarkData` is the grant itself;
/// `resolvedPath` is the folder's last resolved absolute location.
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
