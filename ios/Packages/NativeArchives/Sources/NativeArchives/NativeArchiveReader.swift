import Foundation
import Darwin
import NativeArchivesC

/// Resource limits applied while extracting a native archive.
public struct NativeArchiveLimits: Sendable, Equatable {
    public var maximumEntryCount: Int
    public var maximumEntryBytes: Int64
    public var maximumTotalBytes: Int64
    public var maximumPathLength: Int

    public init(
        maximumEntryCount: Int = 10_000,
        maximumEntryBytes: Int64 = 256 * 1024 * 1024,
        maximumTotalBytes: Int64 = 512 * 1024 * 1024,
        maximumPathLength: Int = 4_096
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPathLength = maximumPathLength
    }
}

public enum NativeArchiveError: LocalizedError, Equatable, Sendable {
    case cannotOpen(String)
    case malformed(String)
    case unsafeEntryPath(String)
    case unsupportedEntry(String)
    case destinationExists(String)
    case resourceLimit(String)
    case fileSystem(String)
    case archiveRead(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let message):
            "The archive could not be opened. " + message
        case .malformed(let message):
            "The archive is malformed or incomplete. " + message
        case .unsafeEntryPath(let path):
            "The archive contains an unsafe entry path: " + path
        case .unsupportedEntry(let path):
            "The archive contains an unsupported entry: " + path
        case .destinationExists(let path):
            "An extracted file already exists: " + path
        case .resourceLimit(let message):
            "The archive exceeds the extraction limits. " + message
        case .fileSystem(let message):
            "The extracted file could not be written. " + message
        case .archiveRead(let message):
            "The archive could not be read. " + message
        }
    }
}

/// Small Swift facade over the checked-in C ABI built from libarchive.
///
/// Extraction is deliberately streaming and rejects links and special files.
/// The caller supplies a new or otherwise controlled destination directory;
/// existing files are never overwritten.
public enum NativeArchiveReader {
    public static let `default` = NativeArchiveLimits()

    private static let bufferSize = 64 * 1024
    private static let errorBufferSize = 512

    public static func extract(
        archiveAt archiveURL: URL,
        into directoryURL: URL,
        limits: NativeArchiveLimits = Self.default
    ) throws -> [String] {
        guard limits.maximumEntryCount > 0,
              limits.maximumEntryBytes >= 0,
              limits.maximumTotalBytes >= 0,
              limits.maximumPathLength > 0 else {
            throw NativeArchiveError.resourceLimit("The configured limits are invalid.")
        }

        let fileManager = FileManager.default
        let directory = directoryURL.standardizedFileURL
        let rootWasCreated = try prepareRoot(directory, fileManager: fileManager)
        var createdPaths: [URL] = []
        var createdDirectories: Set<String> = []
        var extractedNames: [String] = []
        var totalBytes: Int64 = 0
        var entryCount = 0

        do {
            var errorBuffer = [CChar](repeating: 0, count: errorBufferSize)
            let reader = archiveURL.path.withCString { path in
                na_archive_open(path, &errorBuffer, errorBuffer.count)
            }
            guard let reader else {
                throw NativeArchiveError.cannotOpen(Self.message(from: errorBuffer))
            }
            defer { na_archive_close(reader) }

            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                try Task.checkCancellation()
                var entryPathPointer: UnsafePointer<CChar>?
                var entryKind: Int32 = 0
                var declaredSize: Int64 = 0
                errorBuffer = [CChar](repeating: 0, count: errorBufferSize)
                let status = na_archive_next(
                    reader,
                    &entryPathPointer,
                    &entryKind,
                    &declaredSize,
                    &errorBuffer,
                    errorBuffer.count
                )
                if status == 1 {
                    break
                }
                guard status == 0 else {
                    throw NativeArchiveError.malformed(Self.message(from: errorBuffer))
                }
                try Task.checkCancellation()
                guard let entryPathPointer else {
                    throw NativeArchiveError.malformed("An entry had no path.")
                }

                let rawPath = String(cString: entryPathPointer)
                let components = try safeComponents(
                    rawPath,
                    maximumLength: limits.maximumPathLength
                )
                let destination = components.reduce(directory) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: false)
                }

                entryCount += 1
                guard entryCount <= limits.maximumEntryCount else {
                    throw NativeArchiveError.resourceLimit("Too many entries.")
                }

                switch entryKind {
                case 2:
                    try prepareDirectory(
                        destination,
                        relativePath: rawPath,
                        root: directory,
                        fileManager: fileManager,
                        createdPaths: &createdPaths,
                        createdDirectories: &createdDirectories
                    )
                    try skipCurrentEntry(
                        reader,
                        errorBuffer: &errorBuffer
                    )
                case 1:
                    guard declaredSize >= 0 else {
                        throw NativeArchiveError.malformed("The entry size is invalid for \(rawPath).")
                    }
                    guard declaredSize <= limits.maximumEntryBytes else {
                        throw NativeArchiveError.resourceLimit("Entry \(rawPath) is too large.")
                    }
                    guard totalBytes <= limits.maximumTotalBytes - declaredSize else {
                        throw NativeArchiveError.resourceLimit("The uncompressed data is too large.")
                    }
                    try prepareParentDirectory(
                        for: destination,
                        root: directory,
                        fileManager: fileManager,
                        createdPaths: &createdPaths,
                        createdDirectories: &createdDirectories
                    )
                    let fileHandle = try createExclusiveFile(
                        at: destination,
                        path: rawPath,
                        fileManager: fileManager
                    )
                    createdPaths.append(destination)
                    do {
                        defer { try? fileHandle.close() }

                        var entryBytes: Int64 = 0
                        while true {
                            try Task.checkCancellation()
                            var bytesRead = 0
                            errorBuffer = [CChar](repeating: 0, count: errorBufferSize)
                            let readStatus = buffer.withUnsafeMutableBytes { rawBuffer in
                                na_archive_read(
                                    reader,
                                    rawBuffer.baseAddress,
                                    rawBuffer.count,
                                    &bytesRead,
                                    &errorBuffer,
                                    errorBuffer.count
                                )
                            }
                            guard readStatus == 0 else {
                                throw NativeArchiveError.archiveRead(Self.message(from: errorBuffer))
                            }
                            if bytesRead == 0 {
                                break
                            }
                            entryBytes += Int64(bytesRead)
                            totalBytes += Int64(bytesRead)
                            guard entryBytes <= limits.maximumEntryBytes,
                                  totalBytes <= limits.maximumTotalBytes else {
                                throw NativeArchiveError.resourceLimit("The uncompressed data is too large.")
                            }
                            do {
                                try fileHandle.write(contentsOf: Data(buffer.prefix(bytesRead)))
                            } catch {
                                throw NativeArchiveError.fileSystem(error.localizedDescription)
                            }
                        }
                        guard entryBytes == declaredSize else {
                            throw NativeArchiveError.malformed("The extracted size for \(rawPath) did not match its header.")
                        }
                    }
                    extractedNames.append(rawPath)
                case 3:
                    throw NativeArchiveError.unsupportedEntry(rawPath)
                default:
                    throw NativeArchiveError.unsupportedEntry(rawPath)
                }
            }
        } catch {
            cleanup(
                root: directory,
                rootWasCreated: rootWasCreated,
                createdPaths: createdPaths,
                fileManager: fileManager
            )
            throw error
        }

        return extractedNames
    }

    private static func prepareRoot(
        _ root: URL,
        fileManager: FileManager
    ) throws -> Bool {
        if fileManager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw NativeArchiveError.fileSystem("The extraction folder is not a safe directory.")
            }
            return false
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return true
        } catch {
            throw NativeArchiveError.fileSystem(error.localizedDescription)
        }
    }

    private static func prepareParentDirectory(
        for file: URL,
        root: URL,
        fileManager: FileManager,
        createdPaths: inout [URL],
        createdDirectories: inout Set<String>
    ) throws {
        try prepareDirectory(
            file.deletingLastPathComponent(),
            relativePath: file.path,
            root: root,
            fileManager: fileManager,
            createdPaths: &createdPaths,
            createdDirectories: &createdDirectories
        )
    }

    private static func prepareDirectory(
        _ directory: URL,
        relativePath: String,
        root: URL,
        fileManager: FileManager,
        createdPaths: inout [URL],
        createdDirectories: inout Set<String>
    ) throws {
        // Keep both paths in the same spelling. `standardizedFileURL` can
        // resolve an existing `/private` component on macOS while leaving a
        // not-yet-created child untouched, which would make a safe descendant
        // look outside the root during this lexical check.
        let directoryPath = directory.path
        let normalizedRootPath = root.path.count > 1 && root.path.hasSuffix("/")
            ? String(root.path.dropLast())
            : root.path
        let rootPath = normalizedRootPath == "/" ? "/" : normalizedRootPath + "/"
        guard directoryPath == normalizedRootPath || directoryPath.hasPrefix(rootPath) else {
            throw NativeArchiveError.unsafeEntryPath(relativePath)
        }

        let relative = String(directoryPath.dropFirst(normalizedRootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var current = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component), isDirectory: true)
            if createdDirectories.contains(current.path) {
                continue
            }
            if fileManager.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw NativeArchiveError.fileSystem("A path component is not a safe directory.")
                }
                continue
            }
            do {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                createdPaths.append(current)
                createdDirectories.insert(current.path)
            } catch {
                throw NativeArchiveError.fileSystem(error.localizedDescription)
            }
        }
    }

    private static func safeComponents(
        _ path: String,
        maximumLength: Int
    ) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= maximumLength,
              !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains(":"), !path.contains("\\") else {
            throw NativeArchiveError.unsafeEntryPath(path)
        }

        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else {
            throw NativeArchiveError.unsafeEntryPath(path)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw NativeArchiveError.unsafeEntryPath(path)
        }
        return parts.map(String.init)
    }

    private static func skipCurrentEntry(
        _ reader: OpaquePointer,
        errorBuffer: inout [CChar]
    ) throws {
        let status = na_archive_skip(reader, &errorBuffer, errorBuffer.count)
        guard status == 0 else {
            throw NativeArchiveError.archiveRead(Self.message(from: errorBuffer))
        }
    }

    private static func createExclusiveFile(
        at url: URL,
        path: String,
        fileManager: FileManager
    ) throws -> FileHandle {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw NativeArchiveError.destinationExists(path)
        }
        let descriptor = url.path.withCString { pathPointer in
            open(
                pathPointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST || errno == ELOOP {
                throw NativeArchiveError.destinationExists(path)
            }
            throw NativeArchiveError.fileSystem(String(cString: strerror(errno)))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func cleanup(
        root: URL,
        rootWasCreated: Bool,
        createdPaths: [URL],
        fileManager: FileManager
    ) {
        if rootWasCreated {
            try? fileManager.removeItem(at: root)
            return
        }
        for path in createdPaths.sorted(by: { $0.path.count > $1.path.count }) {
            try? fileManager.removeItem(at: path)
        }
    }

    private static func message(from buffer: [CChar]) -> String {
        let message = String(cString: buffer)
        return message.isEmpty ? "Unknown archive error." : message
    }
}
