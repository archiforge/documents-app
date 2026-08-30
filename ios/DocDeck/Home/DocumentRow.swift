import SwiftUI

/// Shared list row: kind glyph, name, relative date, and size.
struct DocumentRow: View {
    let record: DocumentRecord
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: record.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(record.lastOpenedAt, format: .relative(presentation: .named))
                        Text("·")
                        Text(record.sizeBytes, format: .byteCount(style: .file))
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
