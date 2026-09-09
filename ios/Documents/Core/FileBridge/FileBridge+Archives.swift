import Foundation

/// Failures while preparing an app-owned extraction destination.
enum FileBridgeArchiveError: LocalizedError, Equatable {
    case invalidFolderName
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            "The archive name cannot be used as a folder name."
        case .destinationUnavailable:
            "The extraction folder could not be prepared."
        }
    }
}

extension FileBridge {
    struct ArchiveExtractionDestination: Sendable {
        let url: URL
        let relativePath: String
    }

    /// Creates a private, hidden staging directory inside the app container.
    /// Device-library enumeration skips this directory while extraction is in
    /// progress, so partial files cannot become visible documents.
    func makeArchiveStagingDirectory() throws -> URL {
        try ensureDocumentsDirectory()
        let fileManager = FileManager.default
        let stagingRoot = documentsDirectory.appendingPathComponent(
            ".document-extraction-staging",
            isDirectory: true
        )
        guard !isSymbolicLink(at: stagingRoot) else {
            throw FileBridgeArchiveError.destinationUnavailable
        }
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )

        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        } catch {
            throw FileBridgeArchiveError.destinationUnavailable
        }
    }

    /// Selects a safe, unique destination folder below `Documents/Extracted`.
    /// The caller publishes a completed staging directory there with one
    /// atomic move, so an existing user's extraction is never overwritten.
    func makeArchiveExtractionDestination(
        named requestedName: String
    ) throws -> ArchiveExtractionDestination {
        let folderName = try validatedArchiveFolderName(requestedName)
        try ensureDocumentsDirectory()

        let fileManager = FileManager.default
        let extractedRoot = documentsDirectory.appendingPathComponent(
            "Extracted",
            isDirectory: true
        )
        guard !isSymbolicLink(at: extractedRoot) else {
            throw FileBridgeArchiveError.destinationUnavailable
        }
        do {
            try fileManager.createDirectory(
                at: extractedRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw FileBridgeArchiveError.destinationUnavailable
        }

        var candidateName = folderName
        var counter = 1
        while true {
            let candidate = extractedRoot.appendingPathComponent(candidateName, isDirectory: true)
            guard !isSymbolicLink(at: candidate) else {
                candidateName = "\(folderName) (\(counter))"
                counter += 1
                continue
            }
            guard !fileManager.fileExists(atPath: candidate.path) else {
                candidateName = "\(folderName) (\(counter))"
                counter += 1
                continue
            }
            return ArchiveExtractionDestination(
                url: candidate,
                relativePath: "Extracted/\(candidateName)"
            )
        }
    }

    func removeArchiveStagingDirectory(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    /// Removes staging entries left by a crash or force quit. The directory is
    /// app-owned and hidden from normal indexing; its contents are safe to
    /// discard before the next extraction starts. A symlink at the staging
    /// root is never followed.
    func sweepArchiveStaging() {
        let fileManager = FileManager.default
        let stagingRoot = documentsDirectory.appendingPathComponent(
            ".document-extraction-staging",
            isDirectory: true
        )
        guard !isSymbolicLink(at: stagingRoot) else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
        try? fileManager.removeItem(at: stagingRoot)
    }

    private func validatedArchiveFolderName(_ requestedName: String) throws -> String {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(":")
        else {
            throw FileBridgeArchiveError.invalidFolderName
        }
        return name
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeSymbolicLink
    }
}
