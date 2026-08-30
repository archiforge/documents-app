import SwiftData
import SwiftUI

/// Trash management: restore or permanently delete individual documents,
/// or empty the whole trash.
struct TrashView: View {
    @Environment(DocumentStore.self) private var store

    @Query(
        filter: #Predicate<DocumentRecord> { $0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var trashedDocuments: [DocumentRecord]

    @State private var confirmEmptyTrash = false
    @State private var failureText: String?

    var body: some View {
        List {
            ForEach(trashedDocuments) { document in
                HStack(spacing: 12) {
                    Image(systemName: document.kind.symbolName)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.displayName)
                            .lineLimit(1)
                        Text(retentionLabel(for: document))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        do {
                            try store.restore(document)
                        } catch {
                            failureText = error.localizedDescription
                        }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        do {
                            try store.delete(document)
                        } catch {
                            failureText = error.localizedDescription
                        }
                    } label: {
                        Label("Delete", systemImage: "trash.slash")
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .overlay {
            if trashedDocuments.isEmpty {
                ContentUnavailableView {
                    Label("Trash is Empty", systemImage: "trash")
                } description: {
                    Text("Documents you delete will appear here until you empty the trash.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Empty Trash", role: .destructive) {
                    confirmEmptyTrash = true
                }
                .disabled(trashedDocuments.isEmpty)
            }
        }
        .confirmationDialog(
            "Empty the trash?",
            isPresented: $confirmEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                do {
                    try store.emptyTrash()
                } catch {
                    failureText = error.localizedDescription
                }
            }
        } message: {
            Text("Items in the trash will be permanently deleted. This cannot be undone.")
        }
        .storeFailureAlert(message: $failureText)
    }

    // MARK: - Labels

    /// Days-remaining caption under the row name. Legacy rows without a
    /// trashed date are purged on launch, so they only flash briefly.
    private func retentionLabel(for document: DocumentRecord) -> String {
        guard let trashedAt = document.trashedAt else { return "Deletes today" }
        let days = TrashPolicy.remainingDays(trashedAt: trashedAt, now: Date())
        if days <= 0 { return "Deletes today" }
        if days == 1 { return "Deletes in 1 day" }
        return "Deletes in \(days) days"
    }
}
