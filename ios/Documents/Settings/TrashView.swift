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
                        if let trashedAt = document.trashedAt {
                            Text("Trashed \(trashedAt, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
}
