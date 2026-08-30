import Foundation
import UIKit

/// One on-device conversion engine. Implementations read the record's stored
/// file and write the converted bytes to a temp URL, which the caller
/// (usually `ConversionCoordinator`) records in the store.
protocol DocumentConverter: Sendable {
    /// Main-actor bound: `DocumentRecord` (a SwiftData model) is not
    /// Sendable, and HTML rendering needs the main actor anyway.
    @MainActor
    func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL
}

/// Maps source kinds to the on-device engines that exist in Phase 2.
/// Anything unmapped throws `ConversionServiceUnavailableError` (Phase 2b).
enum ConversionRegistry {
    static func converter(for kind: DocumentKind, target: ConversionTarget) -> (any DocumentConverter)? {
        guard target == .pdf else { return nil }
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
        guard let converter = converter(for: record.kind, target: target) else {
            throw ConversionServiceUnavailableError(sourceKind: record.kind, target: target)
        }
        return try await converter.convert(record, to: target)
    }
}

/// Converts a stored record and saves the result back into the store.
@MainActor
enum ConversionCoordinator {
    @discardableResult
    static func convert(_ record: DocumentRecord, to target: ConversionTarget, store: DocumentStore)
        async throws -> DocumentRecord {
        let outputURL = try await ConversionRegistry.convert(record, to: target)
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let data = try Data(contentsOf: outputURL)
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

    func convertedName(for record: DocumentRecord, target: ConversionTarget) -> String {
        let base = (record.displayName as NSString).deletingPathExtension
        return "\(base).\(target.fileExtension)"
    }

    func readText(_ record: DocumentRecord) throws -> String {
        let url = record.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConversionError.unreadableSource }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConversionError.unreadableSource
        }
        return text
    }
}

// MARK: - On-device converters

struct TextToPDFConverter: DocumentConverter {
    func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL {
        let text = try readText(record)
        let data = TextToPDF.pdf(from: text)
        return try writeToTempDirectory(name: convertedName(for: record, target: target), data: data)
    }
}

struct MarkdownToPDFConverter: DocumentConverter {
    func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL {
        let text = try readText(record)
        let data = MarkdownToPDF.pdf(fromMarkdown: text)
        return try writeToTempDirectory(name: convertedName(for: record, target: target), data: data)
    }
}

struct HTMLToPDFConverter: DocumentConverter {
    func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL {
        let html = try readText(record)
        let data = await HTMLToPDF.pdf(fromHTML: html)
        return try writeToTempDirectory(name: convertedName(for: record, target: target), data: data)
    }
}

struct ImageToPDFConverter: DocumentConverter {
    func convert(_ record: DocumentRecord, to target: ConversionTarget) async throws -> URL {
        let url = record.fileURL
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw ConversionError.unreadableSource
        }
        let pdf = try PDFAssembler.pdfData(from: [image])
        return try writeToTempDirectory(name: convertedName(for: record, target: target), data: pdf)
    }
}
