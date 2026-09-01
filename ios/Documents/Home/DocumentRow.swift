import SwiftUI

/// Shared list row: kind glyph, name, creation date, and size. In
/// selection mode (board R3.8) the favorite star is replaced by a trailing
/// checkmark and the tap toggles selection instead of opening.
struct DocumentRow: View {
    let record: DocumentRecord
    var isSelecting = false
    var isSelected = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ThumbnailView(record: record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(record.creationDate, format: .relative(presentation: .named))
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

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                } else if record.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.displayName)
        .accessibilityValue(isSelecting ? (isSelected ? "Selected" : "Not selected") : "")
    }
}
