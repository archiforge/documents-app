import Foundation
import Observation
import SwiftData

/// Persists user-granted folders as security-scoped bookmarks and keeps the
/// grants' read access alive for the app session.
///
/// iOS only lets an app enumerate files it can access, so the device
/// library's reach beyond the app container comes from folders the user
/// picked in the Files interface (Settings → Indexed Folders). A picked
/// folder is stored as a security-scoped bookmark; resolving it on launch
/// restores access, which is then held open so enumeration, Quick Look, and
/// the tools can read the granted subtree without further prompts.
@MainActor
@Observable
final class FolderGrantService {
    private let context: ModelContext

    /// Folders whose bookmarks currently resolve, in grant order. The device
    /// library enumerates these during every sync pass.
    private(set) var resolvedFolders: [URL] = []
    /// Grants whose bookmark could not be resolved this session (folder
    /// deleted, file provider gone). Their records leave the index through
    /// the library's vanished-file pruning; the grant itself stays listed
    /// until the user removes it, because providers can come back.
    private(set) var unavailableIDs: Set<UUID> = []

    /// Fired after a grant is added or removed so the device library can
    /// re-sync immediately.
    var onFoldersChanged: (() -> Void)?

    /// Access started on each resolved folder, held for the app session.
    private var heldAccesses: [UUID: HeldAccess] = [:]

    private struct HeldAccess {
        let url: URL
        let scoped: Bool
    }

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Queries

    func allGrants() -> [FolderGrant] {
        let descriptor = FetchDescriptor<FolderGrant>(sortBy: [SortDescriptor(\.addedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Mutating

    /// Persists a folder picked in the Files interface. The picked URL is
    /// only valid for this session; the stored bookmark recreates the access.
    /// Granting an already-granted folder returns the existing grant.
    @discardableResult
    func addGrant(from pickedURL: URL) throws -> FolderGrant {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { pickedURL.stopAccessingSecurityScopedResource() }
        }
        let data = try pickedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let path = resolved.standardizedFileURL.path
        if let existing = allGrants().first(where: { $0.resolvedPath == path }) {
            return existing
        }

        let grant = FolderGrant(
            displayName: folderName(for: resolved),
            bookmarkData: data,
            resolvedPath: path
        )
        context.insert(grant)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        holdAccess(for: grant, url: resolved)
        resolvedFolders.append(resolved.standardizedFileURL)
        onFoldersChanged?()
        return grant
    }

    /// Removes a grant. Files indexed from the folder leave the index through
    /// the device library's vanished-file pruning on the next sync pass.
    func removeGrant(_ grant: FolderGrant) throws {
        releaseAccess(for: grant.id)
        resolvedFolders.removeAll { $0.standardizedFileURL.path == grant.resolvedPath }
        unavailableIDs.remove(grant.id)
        context.delete(grant)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        onFoldersChanged?()
    }

    /// Resolves every stored bookmark and holds access to the folders for
    /// the app session. Safe to call repeatedly (tab switches restart the
    /// device library): already-held accesses are reused, and stale bookmarks
    /// are refreshed from their resolved URL. Dead bookmarks land in
    /// `unavailableIDs`.
    func restoreAccess() async {
        for grant in allGrants() {
            do {
                let (url, stale) = try await Self.resolveBookmark(grant.bookmarkData)
                holdAccess(for: grant, url: url)
                if stale {
                    // Recreating the bookmark requires access, which is why
                    // `holdAccess` runs first.
                    grant.bookmarkData = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                let path = url.standardizedFileURL.path
                grant.resolvedPath = path
                unavailableIDs.remove(grant.id)
                if !resolvedFolders.contains(where: { $0.standardizedFileURL.path == path }) {
                    resolvedFolders.append(url.standardizedFileURL)
                }
            } catch {
                releaseAccess(for: grant.id)
                resolvedFolders.removeAll { $0.standardizedFileURL.path == grant.resolvedPath }
                unavailableIDs.insert(grant.id)
            }
        }
        try? context.save()
    }

    // MARK: - Access holding

    /// Starts accessing the resolved folder and keeps it open for the
    /// session; Quick Look and the tools read granted files through this
    /// scope. Unscoped URLs (plain local directories, e.g. in tests) need no
    /// access and record `scoped: false`.
    private func holdAccess(for grant: FolderGrant, url: URL) {
        guard heldAccesses[grant.id] == nil else { return }
        heldAccesses[grant.id] = HeldAccess(url: url, scoped: url.startAccessingSecurityScopedResource())
    }

    private func releaseAccess(for id: UUID) {
        guard let held = heldAccesses.removeValue(forKey: id) else { return }
        if held.scoped {
            held.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Bookmark resolution can touch disk and cloud providers; keep it off
    /// the main actor (nonisolated async hops to the global executor).
    nonisolated private static func resolveBookmark(_ data: Data) async throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    private func folderName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? "Folder" : name
    }
}
