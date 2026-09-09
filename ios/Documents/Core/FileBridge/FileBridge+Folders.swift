import Foundation

/// Filesystem failures specific to the app-owned folder tree.
enum FileBridgeFolderError: LocalizedError, Equatable {
    case invalidFolderName
    case invalidRelativePath(String)
    case folderNotFound(String)
    case pathAlreadyExists(String)
    case destinationOccupied(String)
    case sourceNotFound(String)
    case sourceNotRegular(String)
    case symlinkNotAllowed(String)
    case moveFailed(String)
    case journalConflict

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            "Choose a folder name without a path separator."
        case .invalidRelativePath:
            "That folder path is not inside Documents."
        case .folderNotFound:
            "The destination folder no longer exists."
        case .pathAlreadyExists:
            "A file or folder with that name already exists."
        case .destinationOccupied:
            "A file with that name already exists in the destination folder."
        case .sourceNotFound:
            "The document could not be found."
        case .sourceNotRegular:
            "Only regular documents can be moved."
        case .symlinkNotAllowed:
            "Symbolic links are not supported in the Documents folder."
        case .moveFailed:
            "The document could not be moved."
        case .journalConflict:
            "Another folder move is already being recovered."
        }
    }
}

extension FileBridge {
    /// One visible child in the app-owned folder tree.
    struct FolderEntry: Identifiable, Sendable, Equatable {
        let name: String
        let relativePath: String
        let url: URL
        let isDirectory: Bool

        var id: String { relativePath }
    }

    /// A file move remains recoverable until its metadata save has committed.
    struct MoveTransaction: Sendable, Equatable {
        let recordID: UUID
        let sourceRelativePath: String
        let destinationRelativePath: String
        let journalURL: URL
    }

    /// Copies a picked file into an existing app-owned folder. The source is
    /// never moved, and name collisions use the same deduplication policy as
    /// root imports.
    func importFile(from sourceURL: URL, intoRelativeFolder relativePath: String) throws -> ImportedFile {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try ensureDocumentsDirectory()
        let destinationFolder = try validatedFolderURL(forRelativePath: relativePath)
        let destination = uniqueDestinationURL(
            for: sourceURL.lastPathComponent,
            in: destinationFolder
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return ImportedFile(url: destination, sizeBytes: Self.fileSize(at: destination))
    }

    private struct MoveManifest: Codable {
        let recordID: UUID
        let sourceRelativePath: String
        let destinationRelativePath: String
    }

    private static var moveJournalDirectoryName: String { ".document-move-journal" }
    private static var moveJournalSuffix: String { ".json" }

    /// Lists visible children of an app-owned folder. Hidden entries,
    /// including deletion and move journals, never enter the UI or index.
    func folderContents(relativePath: String) throws -> [FolderEntry] {
        try ensureDocumentsDirectory()
        let folderURL = try validatedFolderURL(forRelativePath: relativePath)
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard !isSymbolicLinkEntry(at: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard values?.isDirectory == true || values?.isRegularFile == true else { return nil }
            let childPath = relativePath.isEmpty
                ? url.lastPathComponent
                : relativePath + "/" + url.lastPathComponent
            return FolderEntry(
                name: url.lastPathComponent,
                relativePath: childPath,
                url: url,
                isDirectory: values?.isDirectory == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Creates one visible folder below an existing app-owned folder.
    @discardableResult
    func createFolder(named name: String, inRelativePath parentPath: String = "") throws -> String {
        try ensureDocumentsDirectory()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFolderName(trimmed) else {
            throw FileBridgeFolderError.invalidFolderName
        }

        let parentURL = try validatedFolderURL(forRelativePath: parentPath)
        let folderURL = parentURL.appendingPathComponent(trimmed, isDirectory: true)
        let relativePath = parentPath.isEmpty ? trimmed : parentPath + "/" + trimmed
        guard !isSymbolicLinkEntry(at: folderURL) else {
            throw FileBridgeFolderError.symlinkNotAllowed(relativePath)
        }
        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
            throw FileBridgeFolderError.pathAlreadyExists(relativePath)
        }

        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: false
            )
        } catch {
            throw FileBridgeFolderError.moveFailed(error.localizedDescription)
        }
        guard isPathInsideDocuments(folderURL) else {
            try? FileManager.default.removeItem(at: folderURL)
            throw FileBridgeFolderError.symlinkNotAllowed(relativePath)
        }
        return relativePath
    }

    /// Returns the container-relative folder path for a URL below the
    /// injected Documents root. The root itself is represented by an empty
    /// string.
    func relativeFolderPath(for url: URL) throws -> String {
        let root = documentsDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path == root.path else {
            guard isPathInsideDocuments(candidate) else {
                throw FileBridgeFolderError.invalidRelativePath(candidate.path)
            }
            return relativePath(for: candidate)
        }
        return ""
    }

    /// Moves one regular, app-owned file and journals the file operation
    /// until the caller persists its new relative path.
    func stageMove(
        recordID: UUID,
        fromRelativePath sourcePath: String,
        toRelativeFolder destinationFolderPath: String
    ) throws -> MoveTransaction? {
        let sourceURL = try validatedFileURL(forRelativePath: sourcePath)
        let destinationFolderURL = try validatedFolderURL(forRelativePath: destinationFolderPath)
        let destinationURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        let destinationPath = destinationFolderPath.isEmpty
            ? sourceURL.lastPathComponent
            : destinationFolderPath + "/" + sourceURL.lastPathComponent

        guard sourceURL.deletingLastPathComponent().standardizedFileURL.path
                != destinationFolderURL.standardizedFileURL.path else {
            return nil
        }
        guard !isSymbolicLinkEntry(at: destinationURL) else {
            throw FileBridgeFolderError.symlinkNotAllowed(destinationPath)
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw FileBridgeFolderError.destinationOccupied(destinationPath)
        }

        let journalDirectory = documentsDirectory.appendingPathComponent(
            Self.moveJournalDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let journalURL = journalDirectory.appendingPathComponent(
            recordID.uuidString + Self.moveJournalSuffix,
            isDirectory: false
        )
        guard !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw FileBridgeFolderError.journalConflict
        }

        let manifest = MoveManifest(
            recordID: recordID,
            sourceRelativePath: sourcePath,
            destinationRelativePath: destinationPath
        )
        do {
            try JSONEncoder().encode(manifest).write(to: journalURL, options: .atomic)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw FileBridgeFolderError.moveFailed(error.localizedDescription)
        }
        return MoveTransaction(
            recordID: recordID,
            sourceRelativePath: sourcePath,
            destinationRelativePath: destinationPath,
            journalURL: journalURL
        )
    }

    /// Reverses a staged move without overwriting a file that appeared at
    /// the original path.
    func restoreMove(_ transaction: MoveTransaction) throws {
        let fileManager = FileManager.default
        let sourceURL = try validatedURL(
            forRelativePath: transaction.sourceRelativePath,
            allowingHiddenFinalComponent: true
        )
        let destinationURL = try validatedURL(
            forRelativePath: transaction.destinationRelativePath,
            allowingHiddenFinalComponent: true
        )
        let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

        if sourceExists && destinationExists {
            throw FileBridgeFolderError.destinationOccupied(transaction.sourceRelativePath)
        }
        if destinationExists {
            do {
                try fileManager.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: destinationURL, to: sourceURL)
            } catch {
                throw FileBridgeFolderError.moveFailed(error.localizedDescription)
            }
        } else if !sourceExists {
            throw FileBridgeFolderError.sourceNotFound(transaction.destinationRelativePath)
        }
        try finalizeMove(transaction)
    }

    /// Completes journal cleanup after the metadata save succeeds.
    func finalizeMove(_ transaction: MoveTransaction) throws {
        if FileManager.default.fileExists(atPath: transaction.journalURL.path) {
            do {
                try FileManager.default.removeItem(at: transaction.journalURL)
            } catch {
                throw FileBridgeFolderError.moveFailed(error.localizedDescription)
            }
        }
        removeEmptyMoveJournalDirectoryIfPossible()
    }

    /// Reconciles move journals before startup checks for missing app-owned
    /// files. Returned IDs are protected when the journal cannot be resolved.
    func reconcileMoveJournals(for appOwnedPaths: [UUID: String]) throws -> Set<UUID> {
        let journalDirectory = documentsDirectory.appendingPathComponent(
            Self.moveJournalDirectoryName,
            isDirectory: true
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: journalDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var pending: Set<UUID> = []
        for journalURL in entries {
            guard journalURL.pathExtension == "json" else {
                throw FileBridgeFolderError.moveFailed("Unexpected move journal entry")
            }
            let filenameID = UUID(uuidString: journalURL.deletingPathExtension().lastPathComponent)
            do {
                let data = try Data(contentsOf: journalURL)
                let manifest = try JSONDecoder().decode(MoveManifest.self, from: data)
                guard filenameID == manifest.recordID else {
                    if let filenameID, appOwnedPaths[filenameID] != nil { pending.insert(filenameID) }
                    if appOwnedPaths[manifest.recordID] != nil { pending.insert(manifest.recordID) }
                    continue
                }
                guard let persistedPath = appOwnedPaths[manifest.recordID] else {
                    // The row is gone; preserve any orphan file for the
                    // device library and only remove the journal.
                    try? fileManager.removeItem(at: journalURL)
                    continue
                }

                let sourceURL = try validatedURL(
                    forRelativePath: manifest.sourceRelativePath,
                    allowingHiddenFinalComponent: true
                )
                let destinationURL = try validatedURL(
                    forRelativePath: manifest.destinationRelativePath,
                    allowingHiddenFinalComponent: true
                )
                if persistedPath == manifest.destinationRelativePath,
                   fileManager.fileExists(atPath: destinationURL.path),
                   !fileManager.fileExists(atPath: sourceURL.path) {
                    try? fileManager.removeItem(at: journalURL)
                    continue
                }
                if persistedPath == manifest.sourceRelativePath,
                   fileManager.fileExists(atPath: sourceURL.path),
                   !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: journalURL)
                    continue
                }
                if persistedPath == manifest.sourceRelativePath,
                   fileManager.fileExists(atPath: destinationURL.path),
                   !fileManager.fileExists(atPath: sourceURL.path) {
                    do {
                        try fileManager.createDirectory(
                            at: sourceURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.moveItem(at: destinationURL, to: sourceURL)
                        try? fileManager.removeItem(at: journalURL)
                    } catch {
                        pending.insert(manifest.recordID)
                    }
                    continue
                }
                pending.insert(manifest.recordID)
            } catch {
                if let filenameID, appOwnedPaths[filenameID] != nil {
                    pending.insert(filenameID)
                } else {
                    // Without a trustworthy UUID there is no safe way to
                    // decide whether a missing row committed. Leave the
                    // malformed journal in place and skip missing-file
                    // disowning for this launch.
                    throw FileBridgeFolderError.moveFailed("Malformed move journal")
                }
            }
        }
        removeEmptyMoveJournalDirectoryIfPossible()
        return pending
    }

    /// Returns paths occupied by a move whose journal is still unresolved.
    /// The device-library index uses this reservation while adopting files
    /// from the app container. A staged destination must never become a
    /// second record while its original row is being recovered.
    ///
    /// Journal enumeration and decoding are intentionally throwing. If the
    /// app cannot establish the reservation set, the caller must defer
    /// app-container adoption for that pass rather than guessing that an
    /// untracked file is safe to index.
    func unresolvedMovePaths() throws -> Set<String> {
        let journalDirectory = documentsDirectory.appendingPathComponent(
            Self.moveJournalDirectoryName,
            isDirectory: true
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: journalDirectory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var reserved: Set<String> = []
        for journalURL in entries {
            guard journalURL.pathExtension == "json" else {
                throw FileBridgeFolderError.moveFailed("Unexpected move journal entry")
            }
            let data = try Data(contentsOf: journalURL)
            let manifest = try JSONDecoder().decode(MoveManifest.self, from: data)
            // Decode success is not enough: rejecting traversal here keeps a
            // malformed-but-decodable manifest from influencing indexing.
            _ = try validatedURL(
                forRelativePath: manifest.sourceRelativePath,
                allowingHiddenFinalComponent: true
            )
            _ = try validatedURL(
                forRelativePath: manifest.destinationRelativePath,
                allowingHiddenFinalComponent: true
            )
            reserved.insert(manifest.sourceRelativePath)
            reserved.insert(manifest.destinationRelativePath)
        }
        return reserved
    }

    private func isValidFolderName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
        guard !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return false }
        return true
    }

    private func validatedFolderURL(forRelativePath path: String) throws -> URL {
        let url = try validatedURL(forRelativePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileBridgeFolderError.folderNotFound(path)
        }
        guard !isSymbolicLinkEntry(at: url) else {
            throw FileBridgeFolderError.symlinkNotAllowed(path)
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw FileBridgeFolderError.invalidRelativePath(path)
        }
        return url
    }

    private func validatedFileURL(forRelativePath path: String) throws -> URL {
        let url = try validatedURL(
            forRelativePath: path,
            allowingHiddenFinalComponent: true
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileBridgeFolderError.sourceNotFound(path)
        }
        guard !isSymbolicLinkEntry(at: url) else {
            throw FileBridgeFolderError.symlinkNotAllowed(path)
        }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw FileBridgeFolderError.sourceNotRegular(path)
        }
        return url
    }

    // Shared with deletion staging so every app-owned file mutation applies
    // the same traversal and symlink checks.
    func validatedURL(
        forRelativePath path: String,
        allowingHiddenFinalComponent: Bool = false
    ) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.isEmpty || (
            !path.hasPrefix("/") &&
            !path.hasSuffix("/") &&
            components.enumerated().allSatisfy { index, component in
                let hiddenFinalComponent = allowingHiddenFinalComponent && index == components.count - 1
                return !component.isEmpty && component != "." && component != ".." &&
                    (!component.hasPrefix(".") || hiddenFinalComponent) && !component.contains(":")
            }
        ) else {
            throw FileBridgeFolderError.invalidRelativePath(path)
        }

        var current = documentsDirectory.standardizedFileURL
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            if isSymbolicLinkEntry(at: current) {
                throw FileBridgeFolderError.symlinkNotAllowed(path)
            }
            if FileManager.default.fileExists(atPath: current.path), !isPathInsideDocuments(current) {
                throw FileBridgeFolderError.symlinkNotAllowed(path)
            }
        }
        guard isPathInsideDocuments(current) else {
            throw FileBridgeFolderError.invalidRelativePath(path)
        }
        return current
    }

    // Shared with deletion staging; the unique name avoids colliding with the
    // archive bridge's private helper on the same FileBridge type.
    func isSymbolicLinkEntry(at url: URL) -> Bool {
        // `attributesOfItem` can fail to classify a dangling link because its
        // destination cannot be followed. URL resource values use lstat-like
        // semantics and still identify that link.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return true
        }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private func isPathInsideDocuments(_ url: URL) -> Bool {
        let root = documentsDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func removeEmptyMoveJournalDirectoryIfPossible() {
        let directory = documentsDirectory.appendingPathComponent(
            Self.moveJournalDirectoryName,
            isDirectory: true
        )
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ),
            entries.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
