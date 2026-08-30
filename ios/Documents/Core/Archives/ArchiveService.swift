import Foundation
import ZIPFoundation

/// Errors surfaced by archive operations.
enum ArchiveError: LocalizedError, Equatable {
    case nothingToCompress
    case creationFailed
    case notReadable
    case unsafeEntryPath(String)

    var errorDescription: String? {
        switch self {
        case .nothingToCompress:
            "Pick at least one file to compress."
        case .creationFailed:
            "The archive could not be created."
        case .notReadable:
            "The archive could not be read."
        case .unsafeEntryPath(let path):
            "The archive contains an unsafe entry path: \(path)"
        }
    }
}

/// ZIP compress/extract on top of ZIPFoundation. Everything is synchronous
/// and URL/Data based so it is unit-testable without any UI.
enum ArchiveService {
    /// Compresses the given files into a single ZIP payload (deflate).
    /// Handles security-scoped URLs handed over by the document picker.
    static func zipData(fromFiles urls: [URL]) throws -> Data {
        guard !urls.isEmpty else { throw ArchiveError.nothingToCompress }
        guard let archive = Archive(data: Data(), accessMode: .create) else {
            throw ArchiveError.creationFailed
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            try archive.addEntry(
                with: url.lastPathComponent,
                fileURL: url,
                compressionMethod: .deflate
            )
        }
        guard let data = archive.data else { throw ArchiveError.creationFailed }
        return data
    }

    /// Extracts a ZIP into `directory`, creating subfolders as needed.
    /// Returns the relative paths of every extracted file.
    static func extract(zipAt url: URL, into directory: URL) throws -> [String] {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ArchiveError.notReadable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var files: [String] = []
        for entry in archive {
            guard isSafe(entry.path) else { throw ArchiveError.unsafeEntryPath(entry.path) }
            let destination = directory.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file:
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
                files.append(entry.path)
            case .symlink:
                // Skip symlinks entirely — they are meaningless inside the
                // sandbox and could point outside the extraction folder.
                continue
            }
        }
        return files
    }

    /// Rejects absolute paths and `..` traversal so a hostile archive cannot
    /// write outside the extraction folder.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":") else { return false }
        return !path.components(separatedBy: "/").contains("..")
    }
}
