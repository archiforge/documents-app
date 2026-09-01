import SwiftData
import SwiftUI

/// Favorites: `isFavorite && !isTrashed`, newest-opened first.
struct FavoritesTab: View {
    @Environment(DocumentStore.self) private var store

    @Query(
        filter: #Predicate<DocumentRecord> { $0.isFavorite && !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var documents: [DocumentRecord]

    @State private var presentedDocument: PresentedDocument?
    @State private var pdfToolsSource: DocumentRecord?
    @State private var failureText: String?
    @State private var selection = BulkSelection()

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("No Favorites", systemImage: "star")
                    } description: {
                        Text("Swipe a document in the Recent tab and tap the star to pin it here.")
                    }
                } else {
                    List {
                        ForEach(documents) { document in
                            row(for: document)
                        }
                    }
                    .listStyle(.plain)
                    .bulkSelectionActions(selection: $selection, selectedRecords: chosen)
                }
            }
            .navigationTitle(selectionTitle)
            .navigationBarTitleDisplayMode(selection.isActive ? .inline : .automatic)
            // iOS 26 merges a bottom bar into the floating tab bar's glass
            // and the two fight for touches; selection mode claims the zone,
            // like Files/Photos do.
            .toolbar(selection.isActive ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selection.isActive {
                        Button("Cancel") {
                            selection.exit()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selection.isActive {
                        selectAllButton
                    } else {
                        Button("Select", systemImage: "checkmark.circle") {
                            selection.enter()
                        }
                        .disabled(documents.isEmpty)
                    }
                }
            }
            .storeFailureAlert(message: $failureText)
            .fullScreenCover(item: $pdfToolsSource) { record in
                PDFToolsScreen(source: record)
            }
            .documentViewer(item: $presentedDocument)
            .onChange(of: documents.map(\.id)) {
                // Bulk Unfavorite makes selected rows leave this tab's
                // query; drop them so the count never shows ghosts.
                guard selection.isActive else { return }
                let visible = Set(documents.map(\.id))
                selection.remove(selection.selectedIDs.subtracting(visible))
            }
        }
    }

    /// Large "Favorites" normally; selection mode shows an inline count
    /// instead (board R3.8).
    private var selectionTitle: String {
        guard selection.isActive else { return "Favorites" }
        return selection.count == 0 ? "Select Items" : "\(selection.count) Selected"
    }

    private var selectAllButton: some View {
        let ids = documents.map(\.id)
        let allSelected = selection.allSelected(in: ids)
        return Button(allSelected ? "Deselect All" : "Select All") {
            if allSelected {
                selection.deselectAll()
            } else {
                selection.selectAll(ids)
            }
        }
    }

    private var chosen: [DocumentRecord] {
        documents.filter { selection.contains($0.id) }
    }

    @ViewBuilder
    private func row(for document: DocumentRecord) -> some View {
        if selection.isActive {
            DocumentRow(
                record: document,
                isSelecting: true,
                isSelected: selection.contains(document.id)
            ) {
                selection.toggle(document.id)
            }
        } else {
            DocumentRow(record: document) {
                open(document)
            }
            .documentActions(
                record: document,
                onOpen: { open(document) },
                onPDFTools: document.kind == .pdf ? { pdfToolsSource = document } : nil
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    do {
                        try store.trash(document)
                    } catch {
                        failureText = error.localizedDescription
                    }
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button {
                    do {
                        try store.toggleFavorite(document)
                    } catch {
                        failureText = error.localizedDescription
                    }
                } label: {
                    Label("Unfavorite", systemImage: "star.slash")
                }
                .tint(.yellow)
            }
        }
    }

    private func open(_ document: DocumentRecord) {
        do {
            try store.recordOpen(document)
        } catch {
            failureText = error.localizedDescription
        }
        presentedDocument = PresentedDocument(record: document)
    }
}
