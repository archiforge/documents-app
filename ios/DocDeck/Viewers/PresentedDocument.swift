import SwiftUI

/// Lightweight, Sendable value driving the document viewer presentation.
struct PresentedDocument: Identifiable, Hashable {
    let id: UUID
    let title: String
    let url: URL

    init(record: DocumentRecord) {
        self.id = record.id
        self.title = record.displayName
        self.url = record.fileURL
    }

    init(url: URL) {
        self.id = UUID()
        self.title = url.lastPathComponent
        self.url = url
    }
}

/// Presents the Quick Look viewer full-screen whenever `document` is set.
struct DocumentViewerPresenter: ViewModifier {
    @Binding var document: PresentedDocument?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $document) { doc in
            DocumentViewerScreen(title: doc.title, url: doc.url)
        }
    }
}

extension View {
    func documentViewer(item document: Binding<PresentedDocument?>) -> some View {
        modifier(DocumentViewerPresenter(document: document))
    }
}
