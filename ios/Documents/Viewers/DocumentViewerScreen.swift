import SwiftUI

/// Full-screen viewer host: Quick Look preview with a title bar, a Done
/// action, and a ShareLink for the underlying file.
struct DocumentViewerScreen: View {
    let title: String
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickLookPreview(url: url)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url)
                    }
                }
        }
    }
}
