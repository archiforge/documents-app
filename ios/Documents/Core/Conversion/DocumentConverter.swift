import Foundation
import UIKit

/// One on-device conversion engine. Implementations read the record's stored
/// file and write the converted bytes to a temp URL, which the caller
/// (usually `ConversionCoordinator`) records in the store.
protocol DocumentConverter: Sendable {
    /// Main-actor bound: `DocumentRecord` (a SwiftData model) is not
    /// Sendable, and HTML rendering needs the main actor anyway.
    @MainActor
    func convert(
        displayName: String,
        to target: ConversionTarget,
        sourceURL: URL
    ) async throws -> URL
}

/// Maps source kinds to the on-device engines that currently exist.
/// Anything unmapped throws `ConversionServiceUnavailableError`.
enum ConversionRegistry {
    static func converter(for kind: DocumentKind, target: ConversionTarget) -> (any DocumentConverter)? {
        guard target == .pdf, ConversionTarget.localPDFSourceKinds.contains(kind) else { return nil }
        switch kind {
        case .text: return TextToPDFConverter()
        case .markdown: return MarkdownToPDFConverter()
        case .html: return HTMLToPDFConverter()
        case .image: return ImageToPDFConverter()
        default: return nil
        }
    }

    @MainActor
    static func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL {
        let kind = record.kind
        let displayName = record.displayName
        return try await convert(kind: kind, displayName: displayName, to: target, sourceURL: record.fileURL)
    }

    @MainActor
    static func convert(
        _ record: DocumentRecord,
        to target: ConversionTarget,
        sourceURL: URL?
    ) async throws -> URL {
        let kind = record.kind
        let displayName = record.displayName
        return try await convert(kind: kind, displayName: displayName, to: target, sourceURL: sourceURL)
    }

    @MainActor
    static func convert(
        kind: DocumentKind,
        displayName: String,
        to target: ConversionTarget,
        sourceURL: URL?
    ) async throws -> URL {
        guard let converter = converter(for: kind, target: target) else {
            throw ConversionServiceUnavailableError(sourceKind: kind, target: target)
        }
        return try await converter.convert(
            displayName: displayName,
            to: target,
            sourceURL: sourceURL ?? FileBridge().absoluteURL(forRelativePath: displayName)
        )
    }
}

/// Converts a stored record and saves the result back into the store.
@MainActor
enum ConversionCoordinator {
    @discardableResult
    static func convert(
        _ record: DocumentRecord,
        to target: ConversionTarget,
        store: DocumentStore,
        grantService: FolderGrantService? = nil,
        officeClient: any OfficeConversionServicing = OfficeConversionClient()
    )
        async throws -> DocumentRecord {
        let displayName = record.displayName
        let sourceKind = record.kind
        if OfficeConversionMatrix.targets(for: record.kind).contains(target) {
            let sourceExtension = (displayName as NSString).pathExtension.lowercased()
            guard OfficeConversionMatrix.supports(sourceExtension: sourceExtension, target: target) else {
                throw ConversionServiceUnavailableError(
                    sourceKind: record.kind,
                    target: target,
                    sourceExtension: sourceExtension
                )
            }
            let result = try await DocumentSourceAccess.withSource(
                record: record,
                store: store,
                grantService: grantService
            ) { url in
                try await ConversionSourceReader.read(url, maximumBytes: 50 * 1024 * 1024)
            }
            try Task.checkCancellation()
            let converted = try await officeClient.convert(
                data: result,
                filename: displayName,
                sourceExtension: sourceExtension,
                target: target
            )
            try Task.checkCancellation()
            return try store.saveGeneratedFile(name: converted.filename, data: converted.data)
        }
        let outputURL = try await DocumentSourceAccess.withSource(
            record: record,
            store: store,
            grantService: grantService
        ) { sourceURL in
            try await ConversionRegistry.convert(
                kind: sourceKind,
                displayName: displayName,
                to: target,
                sourceURL: sourceURL
            )
        }
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        try Task.checkCancellation()
        let data = try await ConversionSourceReader.read(outputURL, maximumBytes: 100 * 1024 * 1024)
        try Task.checkCancellation()
        let saved = try store.saveGeneratedFile(name: outputURL.lastPathComponent, data: data)
        return saved
    }
}

// MARK: - Shared temp-file helper

extension DocumentConverter {
    func writeToTempDirectory(name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func convertedName(for displayName: String, target: ConversionTarget) -> String {
        let base = (displayName as NSString).deletingPathExtension
        return "\(base).\(target.fileExtension)"
    }

    func readText(from url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConversionError.unreadableSource }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConversionError.unreadableSource
        }
        return text
    }
}

// MARK: - On-device converters

struct TextToPDFConverter: DocumentConverter {
    func convert(displayName: String, to target: ConversionTarget, sourceURL: URL) async throws -> URL {
        let text = try readText(from: sourceURL)
        let data = TextToPDF.pdf(from: text)
        return try writeToTempDirectory(name: convertedName(for: displayName, target: target), data: data)
    }
}

struct MarkdownToPDFConverter: DocumentConverter {
    func convert(displayName: String, to target: ConversionTarget, sourceURL: URL) async throws -> URL {
        let text = try readText(from: sourceURL)
        let data = MarkdownToPDF.pdf(fromMarkdown: text)
        return try writeToTempDirectory(name: convertedName(for: displayName, target: target), data: data)
    }
}

struct HTMLToPDFConverter: DocumentConverter {
    func convert(displayName: String, to target: ConversionTarget, sourceURL: URL) async throws -> URL {
        let html = try readText(from: sourceURL)
        let data = HTMLToPDF.pdf(fromHTML: html)
        return try writeToTempDirectory(name: convertedName(for: displayName, target: target), data: data)
    }
}

struct ImageToPDFConverter: DocumentConverter {
    func convert(displayName: String, to target: ConversionTarget, sourceURL: URL) async throws -> URL {
        let data = try await ConversionSourceReader.read(sourceURL, maximumBytes: 50 * 1024 * 1024)
        guard let image = UIImage(data: data) else {
            throw ConversionError.unreadableSource
        }
        let pdf = try PDFAssembler.pdfData(from: [image])
        return try writeToTempDirectory(name: convertedName(for: displayName, target: target), data: pdf)
    }
}

private enum ConversionSourceReader {
    static func read(_ url: URL, maximumBytes: Int64) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConversionError.unreadableSource
            }
            if let fileSize = values.fileSize, fileSize > maximumBytes {
                throw ConversionError.sourceTooLarge
            }
            guard let stream = InputStream(url: url) else {
                throw ConversionError.unreadableSource
            }
            stream.open()
            defer { stream.close() }
            var data = Data()
            if let fileSize = values.fileSize, fileSize > 0, let capacity = Int(exactly: fileSize) {
                data.reserveCapacity(min(capacity, Int(maximumBytes)))
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read < 0 { throw ConversionError.unreadableSource }
                if read == 0 { break }
                guard Int64(data.count) <= maximumBytes - Int64(read) else {
                    throw ConversionError.sourceTooLarge
                }
                data.append(contentsOf: buffer.prefix(read))
            }
            return data
        }.value
    }
}
