import Foundation
import ImageIO
import PDFKit
import UIKit

/// Disk-backed thumbnail cache for document rows.
///
/// Entry filenames embed both the record id and the source file's
/// modification time (`{id}-{mtime}.png`), so an edited or regenerated file
/// invalidates its cached thumbnail for free, and the startup sweep can
/// delete entries no current record references anymore.
///
/// Rendering happens off the main actor: PDFs render their first page
/// through PDFKit, image kinds downsample through `CGImageSource`, both
/// capped at `maxPixelSize`. Non-renderable kinds return nil so rows keep
/// their SF Symbol glyph. The cache is bounded by `maxCacheBytes` and evicts
/// oldest-mtime entries first when a write pushes it over the cap.
actor ThumbnailStore {
    /// Longest side of a generated thumbnail, in pixels.
    static let maxPixelSize = 400
    /// Default cap for the whole cache: 32 MB.
    static let defaultMaxCacheBytes: Int64 = 32 * 1024 * 1024

    /// Process-wide cache used by the app UI. Tests build isolated instances
    /// with a temporary directory (and usually a tiny byte cap).
    static let shared = ThumbnailStore()

    /// The default cache location: `Caches/DocumentThumbnails/`.
    nonisolated static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocumentThumbnails", isDirectory: true)
    }

    private let cacheDirectory: URL
    private let maxCacheBytes: Int64
    /// Page counts computed during generation, keyed by record id. Consumed
    /// on read so the caller persists each one exactly once.
    private var generatedPageCounts: [UUID: Int] = [:]

    init(
        cacheDirectory: URL = ThumbnailStore.defaultCacheDirectory,
        maxCacheBytes: Int64 = ThumbnailStore.defaultMaxCacheBytes
    ) {
        self.cacheDirectory = cacheDirectory
        self.maxCacheBytes = maxCacheBytes
    }

    /// Cache entry name for a record at a given source mtime. Exposed so
    /// startup recovery can compute which entries are still current.
    nonisolated static func entryName(recordID: UUID, mtime: Date) -> String {
        "\(recordID.uuidString)-\(Int(mtime.timeIntervalSince1970)).png"
    }

    /// Modification date of the file at `url`, if the file exists.
    nonisolated static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    // MARK: - Lookup & generation

    /// Returns the cached or freshly generated thumbnail for `record`, or nil
    /// when the file is missing or the kind is not renderable (rows then
    /// keep the SF Symbol glyph — honest scope).
    ///
    /// Runs on the main actor only while reading the (non-Sendable) SwiftData
    /// record; the expensive render is a nonisolated async hop off main.
    @MainActor
    func image(for record: DocumentRecord, documentsDirectory: URL) async -> UIImage? {
        let fileURL = Self.fileURL(for: record, documentsDirectory: documentsDirectory)
        guard let mtime = Self.modificationDate(at: fileURL) else { return nil }
        let key = Self.entryName(recordID: record.id, mtime: mtime)

        if let cached = await cachedImage(named: key) {
            return cached
        }

        let kind = record.kind
        guard kind == .pdf || kind == .image else { return nil }
        guard let generated = await Self.generate(at: fileURL, kind: kind) else {
            return nil
        }

        if record.pageCount == nil, let pageCount = generated.pageCount {
            await noteGeneratedPageCount(pageCount, for: record.id)
        }
        await storeEntry(named: key, image: generated.image)
        return generated.image
    }

    /// Page count computed during the most recent generation for `recordID`,
    /// consumed on read so callers persist it exactly once.
    func generatedPageCount(for recordID: UUID) -> Int? {
        generatedPageCounts.removeValue(forKey: recordID)
    }

    private func noteGeneratedPageCount(_ pageCount: Int, for recordID: UUID) {
        generatedPageCounts[recordID] = pageCount
    }

    /// Deletes cache entries whose filename is not in `keys`. Called from
    /// startup recovery after records and disk have been reconciled.
    func sweep(keeping keys: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where !keys.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Cache internals

    private func cachedImage(named key: String) -> UIImage? {
        let url = cacheDirectory.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func storeEntry(named key: String, image: UIImage) {
        guard let data = image.pngData() else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: cacheDirectory.appendingPathComponent(key), options: .atomic)
        } catch {
            // A failed write only costs a regeneration next time.
            return
        }
        enforceByteCap()
    }

    /// Brings the cache back under `maxCacheBytes` by removing entries with
    /// the oldest modification time first.
    private func enforceByteCap() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var items: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for entry in entries {
            guard
                let values = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ),
                let size = values.fileSize,
                let mtime = values.contentModificationDate
            else { continue }
            items.append((entry, Int64(size), mtime))
            total += Int64(size)
        }
        guard total > maxCacheBytes else { return }

        for item in items.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > maxCacheBytes else { break }
            do {
                try fileManager.removeItem(at: item.url)
                total -= item.size
            } catch {
                // An undeletable entry is retried on the next write.
            }
        }
    }

    // MARK: - Generation

    private struct Generated: Sendable {
        let image: UIImage
        let pageCount: Int?
    }

    /// Renders the thumbnail off the main actor. PDFs also report their page
    /// count so it can be persisted once on the record.
    nonisolated private static func generate(at fileURL: URL, kind: DocumentKind) async -> Generated? {
        switch kind {
        case .pdf:
            guard
                let document = PDFDocument(url: fileURL),
                let page = document.page(at: 0)
            else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let longestSide = max(bounds.width, bounds.height)
            let scale = longestSide > 0 ? min(1, CGFloat(maxPixelSize) / longestSide) : 1
            let size = CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            )
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            return Generated(image: thumbnail, pageCount: document.pageCount)
        case .image:
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard
                let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return Generated(image: UIImage(cgImage: cgImage), pageCount: nil)
        default:
            return nil
        }
    }

    /// Resolves the record's file against the given documents directory so
    /// tests (and any future container relocation) stay correct. External
    /// records resolve through their absolute path.
    nonisolated private static func fileURL(for record: DocumentRecord, documentsDirectory: URL) -> URL {
        if let absolutePath = record.absolutePath {
            URL(fileURLWithPath: absolutePath)
        } else {
            documentsDirectory.appendingPathComponent(record.relativePath)
        }
    }
}
