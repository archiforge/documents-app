import SwiftUI

/// Shared list row: kind glyph, name, relative date, and size.
struct DocumentRow: View {
    let record: DocumentRecord
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ThumbnailView(record: record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(record.lastOpenedAt, format: .relative(presentation: .named))
                        Text("·")
                        Text(record.sizeBytes, format: .byteCount(style: .file))
                        if record.kind == .pdf, let pageCount = record.pageCount {
                            Text("·")
                            Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let caption = record.provenance.caption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if record.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.displayName)
    }
}
