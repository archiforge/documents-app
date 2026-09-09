import Foundation

enum DocumentSourceAccessError: LocalizedError {
    case unavailableGrant
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .unavailableGrant:
            "This document's folder is unavailable. Add or reconnect it in Settings."
        case .invalidSource:
            "The source is unavailable or is not a regular document."
        }
    }
}

/// Keeps source access alive across asynchronous processing without passing
/// SwiftData records to workers. A cached external path only identifies the
/// relative child; a resolved bookmark provides authority to read the folder.
enum DocumentSourceAccess {
    @MainActor
    static func withSource<T: Sendable>(
        record: DocumentRecord,
        store: DocumentStore,
        grantService: FolderGrantService?,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !record.isTrashed else { throw DocumentSourceAccessError.invalidSource }
        if let absolutePath = record.absolutePath {
            guard let grantService else { throw DocumentSourceAccessError.unavailableGrant }
            let sourcePath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
            // Prefer the narrowest grant when nested folders were granted.
            let grants = grantService.allGrants().sorted { $0.resolvedPath.count > $1.resolvedPath.count }
            guard let grant = grants.first(where: {
                let root = URL(fileURLWithPath: $0.resolvedPath).standardizedFileURL.path
                return sourcePath.hasPrefix(root + "/")
            }) else { throw DocumentSourceAccessError.unavailableGrant }
            let cachedRoot = URL(fileURLWithPath: grant.resolvedPath).standardizedFileURL.path
            let relativePath = String(sourcePath.dropFirst(cachedRoot.count + 1))
            var stale = false
            let folder: URL
            do {
                folder = try URL(
                    resolvingBookmarkData: grant.bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                throw DocumentSourceAccessError.unavailableGrant
            }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            // A fresh lease survives removal of the app session's grant while
            // this operation is running. Stale bookmarks may still resolve;
            // FolderGrantService owns persistence of refreshed bookmark data.
            let bridge = FileBridge(documentsDirectory: folder)
            let source = try bridge.validatedURL(
                forRelativePath: relativePath, allowingHiddenFinalComponent: true
            )
            try requireRegularFile(source)
            try Task.checkCancellation()
            let result = try await operation(source)
            try Task.checkCancellation()
            return result
        }
        let source = try store.fileBridge.validatedURL(
            forRelativePath: record.relativePath, allowingHiddenFinalComponent: true
        )
        try requireRegularFile(source)
        let result = try await operation(source)
        try Task.checkCancellation()
        return result
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DocumentSourceAccessError.invalidSource
        }
    }
}
