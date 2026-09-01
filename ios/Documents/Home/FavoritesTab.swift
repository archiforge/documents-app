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
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Favorites")
            .storeFailureAlert(message: $failureText)
            .fullScreenCover(item: $pdfToolsSource) { record in
                PDFToolsScreen(source: record)
            }
            .documentViewer(item: $presentedDocument)
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
