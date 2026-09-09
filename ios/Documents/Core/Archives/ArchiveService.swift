import Foundation
import NativeArchives
import ZIPFoundation

/// Errors surfaced by archive operations.
enum ArchiveError: LocalizedError, Equatable {
    case nothingToCompress
    case creationFailed
    case notReadable
    case unsafeEntryPath(String)
    case unsupportedFormat(String)
    case unsupportedEntry(String)
    case destinationExists(String)
    case resourceLimitExceeded

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
        case .unsupportedFormat(let format):
            "Documents cannot extract .\(format) archives."
        case .unsupportedEntry(let path):
            "The archive contains an unsupported entry: \(path)"
        case .destinationExists(let path):
            "An extracted file already exists: \(path)"
        case .resourceLimitExceeded:
            "The archive is too large to extract safely."
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
    static func extract(
        zipAt url: URL,
        into directory: URL,
        limits: NativeArchiveLimits = .init()
    ) throws -> [String] {
        try extractZIP(at: url, into: directory, limits: limits)
    }

    /// Extracts a ZIP, 7-Zip, or RAR archive into `directory`.
    ///
    /// ZIPFoundation remains the writer and ZIP reader for compatibility.
    /// NativeArchives handles 7z/RAR with streaming libarchive extraction.
    static func extract(
        archiveAt url: URL,
        into directory: URL,
        limits: NativeArchiveLimits = .init()
    ) throws -> [String] {
        switch url.pathExtension.lowercased() {
        case "zip":
            return try extractZIP(at: url, into: directory, limits: limits)
        case "7z", "rar":
            do {
                return try NativeArchiveReader.extract(
                    archiveAt: url,
                    into: directory,
                    limits: limits
                )
            } catch let error as NativeArchiveError {
                throw mapNativeError(error)
            }
        case let format where !format.isEmpty:
            throw ArchiveError.unsupportedFormat(format)
        default:
            throw ArchiveError.unsupportedFormat("archive")
        }
    }

    private static func extractZIP(
        at url: URL,
        into directory: URL,
        limits: NativeArchiveLimits
    ) throws -> [String] {
        guard limits.maximumEntryCount > 0,
              limits.maximumEntryBytes >= 0,
              limits.maximumTotalBytes >= 0,
              limits.maximumPathLength > 0 else {
            throw ArchiveError.resourceLimitExceeded
        }
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ArchiveError.notReadable
        }

        let fileManager = FileManager.default
        let root = directory.standardizedFileURL
        let rootWasCreated = try prepareZIPRoot(root, fileManager: fileManager)
        var createdPaths: [URL] = []
        var createdDirectories: Set<String> = []

        do {
            var files: [String] = []
            var totalBytes: Int64 = 0
            var entryCount = 0
            for entry in archive {
                try Task.checkCancellation()
                entryCount += 1
                guard entryCount <= limits.maximumEntryCount else {
                    throw ArchiveError.resourceLimitExceeded
                }
                guard entry.path.utf8.count <= limits.maximumPathLength else {
                    throw ArchiveError.resourceLimitExceeded
                }
                guard isSafe(entry.path) else { throw ArchiveError.unsafeEntryPath(entry.path) }
                let destination = root.appendingPathComponent(entry.path)
                switch entry.type {
                case .directory:
                    try prepareZIPDirectory(
                        destination,
                        relativePath: entry.path,
                        root: root,
                        fileManager: fileManager,
                        createdPaths: &createdPaths,
                        createdDirectories: &createdDirectories
                    )
                case .file:
                    if fileManager.fileExists(atPath: destination.path)
                        || isSymbolicLink(at: destination, fileManager: fileManager) {
                        throw ArchiveError.destinationExists(entry.path)
                    }
                    guard entry.uncompressedSize <= UInt64(limits.maximumEntryBytes),
                          entry.uncompressedSize <= UInt64(Int64.max) else {
                        throw ArchiveError.resourceLimitExceeded
                    }
                    let declaredBytes = Int64(entry.uncompressedSize)
                    guard totalBytes <= limits.maximumTotalBytes,
                          declaredBytes <= limits.maximumTotalBytes - totalBytes else {
                        throw ArchiveError.resourceLimitExceeded
                    }
                    try prepareZIPDirectory(
                        destination.deletingLastPathComponent(),
                        relativePath: entry.path,
                        root: root,
                        fileManager: fileManager,
                        createdPaths: &createdPaths,
                        createdDirectories: &createdDirectories
                    )

                    // Stream each entry into a temporary sibling before publishing it.
                    // This keeps extraction cancellable and prevents a partial file from
                    // being mistaken for a completed document when a limit is exceeded.
                    let temporary = destination
                        .deletingLastPathComponent()
                        .appendingPathComponent(".document-archive-entry-\(UUID().uuidString)")
                    fileManager.createFile(atPath: temporary.path, contents: nil)
                    let fileHandle = try FileHandle(forWritingTo: temporary)
                    var entryBytes: Int64 = 0
                    do {
                        let checksum = try archive.extract(entry, consumer: { chunk in
                            try Task.checkCancellation()
                            let chunkBytes = Int64(chunk.count)
                            guard entryBytes <= limits.maximumEntryBytes,
                                  totalBytes <= limits.maximumTotalBytes,
                                  chunkBytes <= limits.maximumEntryBytes - entryBytes,
                                  chunkBytes <= limits.maximumTotalBytes - totalBytes else {
                                throw ArchiveError.resourceLimitExceeded
                            }
                            try fileHandle.write(contentsOf: chunk)
                            entryBytes += chunkBytes
                            totalBytes += chunkBytes
                        })
                        try Task.checkCancellation()
                        try fileHandle.close()
                        guard entryBytes == declaredBytes, checksum == entry.checksum else {
                            throw ArchiveError.notReadable
                        }
                        try fileManager.moveItem(at: temporary, to: destination)
                        createdPaths.append(destination)
                        try Task.checkCancellation()
                    } catch {
                        try? fileHandle.close()
                        try? fileManager.removeItem(at: temporary)
                        throw error
                    }
                    files.append(entry.path)
                case .symlink:
                    throw ArchiveError.unsupportedEntry(entry.path)
                }
            }
            return files
        } catch {
            if rootWasCreated {
                try? fileManager.removeItem(at: root)
            } else {
                for path in createdPaths.sorted(by: { $0.path.count > $1.path.count }) {
                    try? fileManager.removeItem(at: path)
                }
            }
            throw error
        }
    }

    private static func prepareZIPRoot(
        _ root: URL,
        fileManager: FileManager
    ) throws -> Bool {
        if isSymbolicLink(at: root, fileManager: fileManager) {
            throw ArchiveError.unsupportedEntry(root.path)
        }
        if fileManager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ArchiveError.unsupportedEntry(root.path)
            }
            return false
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return true
        } catch {
            throw ArchiveError.notReadable
        }
    }

    private static func prepareZIPDirectory(
        _ directory: URL,
        relativePath: String,
        root: URL,
        fileManager: FileManager,
        createdPaths: inout [URL],
        createdDirectories: inout Set<String>
    ) throws {
        let directoryPath = directory.path
        let normalizedRootPath = root.path.count > 1 && root.path.hasSuffix("/")
            ? String(root.path.dropLast())
            : root.path
        let rootPath = normalizedRootPath == "/" ? "/" : normalizedRootPath + "/"
        guard directoryPath == normalizedRootPath || directoryPath.hasPrefix(rootPath) else {
            throw ArchiveError.unsafeEntryPath(relativePath)
        }

        let relative = String(directoryPath.dropFirst(normalizedRootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var current = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component), isDirectory: true)
            if createdDirectories.contains(current.path) {
                continue
            }
            if isSymbolicLink(at: current, fileManager: fileManager) {
                throw ArchiveError.unsupportedEntry(relativePath)
            }
            if fileManager.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    throw ArchiveError.unsupportedEntry(relativePath)
                }
                continue
            }
            do {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                createdPaths.append(current)
                createdDirectories.insert(current.path)
            } catch {
                throw ArchiveError.notReadable
            }
        }
    }

    private static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private static func mapNativeError(_ error: NativeArchiveError) -> ArchiveError {
        switch error {
        case .unsafeEntryPath(let path):
            .unsafeEntryPath(path)
        case .unsupportedEntry(let path):
            .unsupportedEntry(path)
        case .destinationExists(let path):
            .destinationExists(path)
        case .resourceLimit:
            .resourceLimitExceeded
        case .cannotOpen, .malformed, .fileSystem, .archiveRead:
            .notReadable
        }
    }

    /// Rejects absolute paths and `..` traversal so a hostile archive cannot
    /// write outside the extraction folder.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains(":"), !path.contains("\\") else { return false }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return false }
        let components = trimmed.components(separatedBy: "/")
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
