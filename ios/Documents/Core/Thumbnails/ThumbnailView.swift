import OSLog
import SwiftUI

private let thumbnailViewLog = Logger(subsystem: "com.docdeck.app", category: "thumbnails")

/// 48×48 rounded thumbnail for document rows.
///
/// Loads through the shared `ThumbnailStore`: shows the cached or generated
/// preview for PDFs and images, and falls back to the kind's SF Symbol glyph
/// for everything else (and while loading). When a PDF thumbnail is
/// generated, the page count computed along the way is persisted once on the
/// record so rows can badge it without re-parsing the file.
struct ThumbnailView: View {
    let record: DocumentRecord

    @Environment(DocumentStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: record.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 48, height: 48)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard image == nil else { return }
        let thumbnails = ThumbnailStore.shared
        guard let generated = await thumbnails.image(
            for: record,
            documentsDirectory: store.fileBridge.documentsDirectory
        ) else { return }
        image = generated

        // Page counts are computed during generation; persist once. A failed
        // save only means the badge stays hidden until the next generation.
        if record.pageCount == nil, let pageCount = await thumbnails.generatedPageCount(for: record.id) {
            do {
                try store.setPageCount(pageCount, for: record)
            } catch {
                thumbnailViewLog.error(
                    "Failed to persist page count for \(record.displayName): \(error.localizedDescription)"
                )
            }
        }
    }
}
