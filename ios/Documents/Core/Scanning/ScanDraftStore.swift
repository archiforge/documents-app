import Foundation
import ImageIO
import UIKit

/// A normalized crop rectangle. Values are expressed in the page's rendered
/// coordinate space after rotation (`0...1`), so the editor and save pipeline
/// select the same pixels on every restore.
struct ScanCrop: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let fullPage = ScanCrop(x: 0, y: 0, width: 1, height: 1)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Keeps a crop usable after a drag gesture or a hand-edited manifest.
    /// Degenerate rectangles are replaced with the full page.
    var clamped: ScanCrop {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let clampedWidth = min(max(width, 0), 1 - clampedX)
        let clampedHeight = min(max(height, 0), 1 - clampedY)
        guard clampedWidth > 0.01, clampedHeight > 0.01 else { return .fullPage }
        return ScanCrop(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }
}

/// The edits applied to one captured page. The source bytes are never
/// rewritten by an edit, which makes restore and rollback safe.
struct ScanPageEdit: Codable, Equatable, Sendable {
    var rotationDegrees: Int = 0
    var crop: ScanCrop = .fullPage

    mutating func rotateClockwise() {
        let currentCrop = crop.clamped
        crop = ScanCrop(
            x: 1 - currentCrop.y - currentCrop.height,
            y: currentCrop.x,
            width: currentCrop.height,
            height: currentCrop.width
        ).clamped
        rotationDegrees = (rotationDegrees + 90).positiveModulo(360)
    }

    mutating func resetCrop() {
        crop = .fullPage
    }
}

private extension Int {
    func positiveModulo(_ divisor: Int) -> Int {
        let result = self % divisor
        return result >= 0 ? result : result + divisor
    }
}

/// A page held by the editor. `Data` is deliberately the concurrency
/// boundary: all expensive PDF, image, and OCR work can operate on these
/// Sendable bytes away from the main actor.
struct ScanPageBuffer: Identifiable, Equatable, Sendable {
    let id: UUID
    var data: Data
    var edit: ScanPageEdit

    init(id: UUID = UUID(), data: Data, edit: ScanPageEdit = .init()) {
        self.id = id
        self.data = data
        self.edit = edit
    }

    init(manifestPage: ScanDraftPage, data: Data) {
        self.id = manifestPage.id
        self.data = data
        self.edit = manifestPage.edit
    }

    /// Stable identity for an async preview task. Edits change the key while
    /// the source bytes remain immutable in the draft.
    var previewKey: String {
        "\(id.uuidString)-\(edit.rotationDegrees)-\(edit.crop.x)-\(edit.crop.y)-\(edit.crop.width)-\(edit.crop.height)"
    }
}

/// The durable, app-private representation of an unfinished scan.
struct ScanDraft: Codable, Equatable, Sendable {
    let id: UUID
    let mode: ScanMode
    var pages: [ScanDraftPage]
    var frontPages: [ScanDraftPage]
    var renamedBase: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        mode: ScanMode,
        pages: [ScanDraftPage],
        frontPages: [ScanDraftPage] = [],
        renamedBase: String? = nil,
        revision: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.mode = mode
        self.pages = pages
        self.frontPages = frontPages
        self.renamedBase = renamedBase
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ScanDraftPage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fileName: String
    var edit: ScanPageEdit

    init(id: UUID, fileName: String, edit: ScanPageEdit = .init()) {
        self.id = id
        self.fileName = fileName
        self.edit = edit
    }
}

/// The loaded manifest plus page bytes. Returning bytes instead of UIImage
/// keeps UIKit out of the persistence actor and makes restored pages safe to
/// pass to background work.
struct ScanDraftSnapshot: Equatable, Sendable {
    let draft: ScanDraft
    let pageData: [UUID: Data]

    var pages: [ScanPageBuffer] {
        draft.pages.compactMap { page in
            guard let data = pageData[page.id] else { return nil }
            return ScanPageBuffer(manifestPage: page, data: data)
        }
    }

    var frontPages: [ScanPageBuffer] {
        draft.frontPages.compactMap { page in
            guard let data = pageData[page.id] else { return nil }
            return ScanPageBuffer(manifestPage: page, data: data)
        }
    }
}

enum ScanDraftError: LocalizedError, Equatable, Sendable {
    case invalidManifest
    case missingPage(UUID)
    case unsafePageName
    case pageEncodingFailed
    case draftIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The unfinished scan draft is invalid and was kept for recovery."
        case .missingPage:
            "A page in the unfinished scan draft is missing. The draft was kept for recovery."
        case .unsafePageName:
            "The unfinished scan draft contains an invalid page path."
        case .pageEncodingFailed:
            "A scanned page could not be stored. The unfinished draft is still available."
        case .draftIdentityMismatch:
            "A different scan session tried to overwrite the unfinished draft. The existing draft was kept."
        }
    }
}

/// Persists scanner drafts under Application Support rather than Documents.
/// DeviceLibraryService therefore never indexes these files as user
/// documents. The actor serializes writes; the manifest is replaced only
/// after every page write succeeds, leaving the previous manifest restorable
/// if a write fails halfway through.
actor ScanDraftStore {
    nonisolated static let shared = ScanDraftStore()
    nonisolated static var defaultDirectory: URL {
        #if DEBUG
        if let fixtureDirectory = ScanDraftUITestFixture.directoryOverride {
            return fixtureDirectory
        }
        #endif
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ScanDraft", isDirectory: true)
    }

    private let directory: URL
    private let manifestURL: URL
    private var persistedRevision = -1
    /// Changes whenever the draft is explicitly discarded. Pending writes
    /// from the discarded session carry the old token and become no-ops.
    private var generationID = UUID()

    init(directory: URL = ScanDraftStore.defaultDirectory) {
        self.directory = directory
        self.manifestURL = directory.appendingPathComponent("manifest.json")
    }

    func currentGeneration() -> UUID {
        generationID
    }

    /// Reads the current draft without deleting it. Corrupt or incomplete
    /// drafts remain on disk so the UI can offer a visible discard action.
    func load() throws -> ScanDraftSnapshot? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ScanDraftError.invalidManifest
        }

        let draft: ScanDraft
        do {
            draft = try JSONDecoder().decode(ScanDraft.self, from: data)
        } catch {
            throw ScanDraftError.invalidManifest
        }
        persistedRevision = max(persistedRevision, draft.revision)

        var pageData: [UUID: Data] = [:]
        var pageIDs = Set<UUID>()
        var pageNames = Set<String>()
        for page in draft.pages + draft.frontPages {
            guard isSafePageFileName(page.fileName) else { throw ScanDraftError.unsafePageName }
            guard pageIDs.insert(page.id).inserted, pageNames.insert(page.fileName).inserted else {
                throw ScanDraftError.invalidManifest
            }
            let pageURL = directory.appendingPathComponent(page.fileName)
            guard FileManager.default.fileExists(atPath: pageURL.path) else {
                throw ScanDraftError.missingPage(page.id)
            }
            do {
                pageData[page.id] = try Data(contentsOf: pageURL)
            } catch {
                throw ScanDraftError.missingPage(page.id)
            }
        }
        return ScanDraftSnapshot(draft: draft, pageData: pageData)
    }

    /// Saves a complete immutable page snapshot. The page files are written
    /// atomically first; only then is the manifest replaced atomically. Old
    /// files are intentionally retained until explicit discard or a
    /// successful document save, so a failed update cannot lose a draft.
    func save(_ draft: ScanDraft, pageData: [UUID: Data], generation: UUID) throws {
        guard generation == generationID else { return }
        var existingDraft: ScanDraft?
        if FileManager.default.fileExists(atPath: manifestURL.path),
           let existingData = try? Data(contentsOf: manifestURL),
           let existing = try? JSONDecoder().decode(ScanDraft.self, from: existingData) {
            existingDraft = existing
            persistedRevision = max(persistedRevision, existing.revision)
        }
        if let existingDraft, existingDraft.id != draft.id {
            throw ScanDraftError.draftIdentityMismatch
        }
        guard draft.revision > persistedRevision else { return }

        // Validate the whole incoming snapshot before touching disk. The
        // manifest is rewritten with fresh names below, so a failed update
        // cannot overwrite a byte file referenced by the previous snapshot.
        var pageIDs = Set<UUID>()
        var pageNames = Set<String>()
        for page in draft.pages + draft.frontPages {
            guard isSafePageFileName(page.fileName) else { throw ScanDraftError.unsafePageName }
            guard pageIDs.insert(page.id).inserted, pageNames.insert(page.fileName).inserted else {
                throw ScanDraftError.invalidManifest
            }
            guard let bytes = pageData[page.id], !bytes.isEmpty else {
                throw ScanDraftError.missingPage(page.id)
            }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Changed or new source bytes get fresh immutable files. Retaining old
        // revisions until explicit discard makes a failed manifest replacement
        // harmless even if the process is interrupted. A metadata-only edit
        // reuses the existing immutable file for each page whose ID and source
        // bytes are unchanged, so crop/reorder/name edits do not grow the
        // draft directory.
        let revisionToken = UUID().uuidString
        var reusableFiles: [UUID: String] = [:]
        if let existingDraft {
            var existingIDs = Set<UUID>()
            var existingNames = Set<String>()
            for page in existingDraft.pages + existingDraft.frontPages {
                guard isSafePageFileName(page.fileName),
                      existingIDs.insert(page.id).inserted,
                      existingNames.insert(page.fileName).inserted,
                      let existingBytes = try? Data(contentsOf: directory.appendingPathComponent(page.fileName)),
                      existingBytes == pageData[page.id]
                else { continue }
                reusableFiles[page.id] = page.fileName
            }
        }
        var committedDraft = draft
        committedDraft.pages = draft.pages.map { page in
            var committed = page
            committed.fileName = reusableFiles[page.id]
                ?? "page-\(page.id.uuidString)-\(draft.revision)-\(revisionToken).bin"
            return committed
        }
        committedDraft.frontPages = draft.frontPages.map { page in
            var committed = page
            committed.fileName = reusableFiles[page.id]
                ?? "page-\(page.id.uuidString)-\(draft.revision)-\(revisionToken).bin"
            return committed
        }

        for page in committedDraft.pages + committedDraft.frontPages {
            guard let bytes = pageData[page.id] else {
                throw ScanDraftError.missingPage(page.id)
            }
            if reusableFiles[page.id] == page.fileName {
                continue
            }
            do {
                try bytes.write(to: directory.appendingPathComponent(page.fileName), options: .atomic)
            } catch {
                throw ScanDraftError.pageEncodingFailed
            }
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(committedDraft)
        } catch {
            throw ScanDraftError.invalidManifest
        }

        let temporaryManifest = directory.appendingPathComponent("manifest.\(UUID().uuidString).tmp")
        do {
            try encoded.write(to: temporaryManifest, options: .atomic)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: manifestURL.path) {
                _ = try fileManager.replaceItemAt(manifestURL, withItemAt: temporaryManifest)
            } else {
                try fileManager.moveItem(at: temporaryManifest, to: manifestURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryManifest)
            throw error
        }
        persistedRevision = committedDraft.revision
    }

    /// Explicit user discard, or cleanup after a saved document has been
    /// recorded. No launch or failed-save path calls this method.
    func discard() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            // Remove first. If cleanup fails, preserve the old generation so
            // the still-visible draft can continue saving and retry discard.
            try FileManager.default.removeItem(at: directory)
        }
        generationID = UUID()
        persistedRevision = -1
    }

    private func isSafePageFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && !fileName.contains("/")
            && !fileName.contains(":")
    }
}

/// Pure page-edit operations shared by the SwiftUI editor and unit tests.
enum ScanPageEditing {
    static func crop(from start: CGPoint, to current: CGPoint, in canvasSize: CGSize) -> ScanCrop {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .fullPage }
        let startX = min(max(start.x / canvasSize.width, 0), 1)
        let startY = min(max(start.y / canvasSize.height, 0), 1)
        let currentX = min(max(current.x / canvasSize.width, 0), 1)
        let currentY = min(max(current.y / canvasSize.height, 0), 1)
        return ScanCrop(
            x: min(startX, currentX),
            y: min(startY, currentY),
            width: abs(currentX - startX),
            height: abs(currentY - startY)
        ).clamped
    }

    static func reorder(_ pages: [ScanPageBuffer], from offsets: IndexSet, to destination: Int) -> [ScanPageBuffer] {
        var result = pages
        let moving = offsets.sorted().compactMap { index in
            pages.indices.contains(index) ? pages[index] : nil
        }
        for index in offsets.sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }
        result.insert(contentsOf: moving, at: min(max(destination, 0), result.count))
        return result
    }

    /// Reorders pages while keeping the selected page's identity. The index
    /// is only a projection for TabView; callers should carry the UUID across
    /// mutations so a later rotate or crop still targets the same page.
    static func reorder(
        _ pages: [ScanPageBuffer],
        from offsets: IndexSet,
        to destination: Int,
        keepingSelectedPageID selectedPageID: UUID?
    ) -> (pages: [ScanPageBuffer], selectedIndex: Int) {
        let reordered = reorder(pages, from: offsets, to: destination)
        let fallback = min(max(destination, 0), max(0, reordered.count - 1))
        let selectedIndex = selectedPageID.flatMap { id in
            reordered.firstIndex { $0.id == id }
        } ?? fallback
        return (reordered, selectedIndex)
    }

    static func removing(_ pages: [ScanPageBuffer], at index: Int) -> [ScanPageBuffer] {
        guard pages.indices.contains(index) else { return pages }
        var result = pages
        result.remove(at: index)
        return result
    }

    /// Removes a page and returns the deterministic selection that should
    /// follow it. Removing the selected page chooses the next page at the
    /// same index, or the previous page when the removed page was last.
    static func removing(
        _ pages: [ScanPageBuffer],
        at index: Int,
        selectedPageID: UUID?
    ) -> (pages: [ScanPageBuffer], selectedPageID: UUID?) {
        guard pages.indices.contains(index) else {
            return (pages, selectedPageID)
        }
        let removedID = pages[index].id
        let remaining = removing(pages, at: index)
        if let selectedPageID,
           selectedPageID != removedID,
           remaining.contains(where: { $0.id == selectedPageID }) {
            return (remaining, selectedPageID)
        }
        guard !remaining.isEmpty else { return (remaining, nil) }
        let nextIndex = min(index, remaining.count - 1)
        return (remaining, remaining[nextIndex].id)
    }

    static func rotating(_ page: ScanPageBuffer) -> ScanPageBuffer {
        var result = page
        result.edit.rotateClockwise()
        return result
    }

    static func cropping(_ page: ScanPageBuffer, to crop: ScanCrop) -> ScanPageBuffer {
        var result = page
        result.edit.crop = crop.clamped
        return result
    }
}

/// Decodes and applies page edits from Sendable bytes. The scanner flow calls
/// these methods from detached tasks for saves, previews, shares, and OCR.
enum ScanPageRenderer {
    static func imageData(for page: ScanPageBuffer) throws -> Data {
        guard let image = decodedImage(from: page.data) else { throw ScanDraftError.pageEncodingFailed }
        let rotated = rotate(image, degrees: page.edit.rotationDegrees)
        let cropped = crop(rotated, to: page.edit.crop)
        guard let encoded = cropped.pngData() else { throw ScanDraftError.pageEncodingFailed }
        return encoded
    }

    static func image(for page: ScanPageBuffer) -> UIImage? {
        guard let image = decodedImage(from: page.data) else { return nil }
        let rotated = rotate(image, degrees: page.edit.rotationDegrees)
        return crop(rotated, to: page.edit.crop)
    }

    /// Produces a bounded preview off the main actor. Full-resolution source
    /// bytes remain available for the eventual save, while SwiftUI bodies only
    /// receive a small decoded image after this task completes.
    static func previewData(for page: ScanPageBuffer, maxDimension: CGFloat = 800) async throws -> Data {
        let boundedDimension = max(1, maxDimension)
        return try await runCancellableDetached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = downsampledImage(from: page.data, maxDimension: boundedDimension) else {
                throw ScanDraftError.pageEncodingFailed
            }
            let rotated = rotate(image, degrees: page.edit.rotationDegrees)
            let cropped = crop(rotated, to: page.edit.crop)
            try Task.checkCancellation()
            let longestSide = max(cropped.size.width, cropped.size.height)
            let scale = min(1, boundedDimension / max(longestSide, 1))
            let size = CGSize(
                width: max(1, cropped.size.width * scale),
                height: max(1, cropped.size.height * scale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                cropped.draw(in: CGRect(origin: .zero, size: size))
            }
            try Task.checkCancellation()
            guard let data = preview.jpegData(compressionQuality: 0.82) else {
                throw ScanDraftError.pageEncodingFailed
            }
            return data
        }
    }

    /// Decodes a source at full pixel size, then renders any EXIF orientation
    /// into an `.up` image before normalized crop coordinates are applied.
    private static func decodedImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let pixelImage = UIImage(cgImage: cgImage, scale: 1, orientation: image.imageOrientation)
        guard pixelImage.imageOrientation != .up else { return pixelImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelImage.size, format: format).image { _ in
            pixelImage.draw(in: CGRect(origin: .zero, size: pixelImage.size))
        }
    }

    /// Uses ImageIO's thumbnail decoder so gallery previews never decode a
    /// camera-sized source merely to shrink it on the main thread later.
    private static func downsampledImage(from data: Data, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maxDimension)),
        ]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func crop(_ image: UIImage, to crop: ScanCrop) -> UIImage {
        let normalized = crop.clamped.rect
        guard normalized != CGRect(x: 0, y: 0, width: 1, height: 1), let cgImage = image.cgImage else {
            return image
        }
        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(cgImage.width),
            y: normalized.minY * CGFloat(cgImage.height),
            width: normalized.width * CGFloat(cgImage.width),
            height: normalized.height * CGFloat(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: pixelRect), !pixelRect.isEmpty else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func rotate(_ image: UIImage, degrees: Int) -> UIImage {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return image }
        let radians = CGFloat(normalized) * .pi / 180
        let size = normalized == 180 ? image.size : CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
}

/// Converts Sendable page buffers into the formats consumed by existing
/// scanner assemblers. The detached closures cross the actor boundary with
/// immutable page metadata and `Data`, rather than SwiftData records.
enum ScanRenderPipeline {
    static func pdfData(from pages: [ScanPageBuffer]) async throws -> Data {
        let bytes = pages
        return try await runCancellableDetached(priority: .userInitiated) {
            var images: [UIImage] = []
            images.reserveCapacity(bytes.count)
            for page in bytes {
                try Task.checkCancellation()
                guard let image = UIImage(data: try ScanPageRenderer.imageData(for: page)) else {
                    throw ScanDraftError.pageEncodingFailed
                }
                images.append(image)
            }
            try Task.checkCancellation()
            let data = try PDFAssembler.pdfData(from: images)
            try Task.checkCancellation()
            return data
        }
    }

    static func imageData(from pages: [ScanPageBuffer]) async throws -> [Data] {
        let bytes = pages
        return try await runCancellableDetached(priority: .userInitiated) {
            var rendered: [Data] = []
            rendered.reserveCapacity(bytes.count)
            for page in bytes {
                try Task.checkCancellation()
                rendered.append(try ScanPageRenderer.imageData(for: page))
            }
            return rendered
        }
    }

    static func longImageData(from pages: [ScanPageBuffer]) async throws -> Data {
        let bytes = pages
        return try await runCancellableDetached(priority: .userInitiated) {
            var images: [UIImage] = []
            images.reserveCapacity(bytes.count)
            for page in bytes {
                try Task.checkCancellation()
                guard let image = UIImage(data: try ScanPageRenderer.imageData(for: page)) else {
                    throw ScanDraftError.pageEncodingFailed
                }
                images.append(image)
            }
            try Task.checkCancellation()
            let data = try LongImageAssembler.pngData(from: images)
            try Task.checkCancellation()
            return data
        }
    }
}

/// Keeps detached image work cancellable when the owning SwiftUI task is
/// dismissed or replaced. `Task.detached` does not inherit cancellation by
/// itself, so the handler explicitly forwards it to the worker.
func runCancellableDetached<T: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let worker = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler(operation: {
        let result = try await worker.value
        try Task.checkCancellation()
        return result
    }, onCancel: {
        worker.cancel()
    })
}

/// Async counterpart for OCR and other framework calls that suspend inside
/// the detached worker. Cancellation is forwarded to the worker and checked
/// again after its value is observed.
func runCancellableDetachedAsync<T: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let worker = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler(operation: {
        let result = try await worker.value
        try Task.checkCancellation()
        return result
    }, onCancel: {
        worker.cancel()
    })
}
