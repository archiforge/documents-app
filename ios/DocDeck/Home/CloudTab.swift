import SwiftUI

/// Placeholder for cloud documents (iCloud Drive / file providers), Phase 3.
struct CloudTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Cloud documents", systemImage: "cloud")
            } description: {
                Text("Cloud documents — Phase 3\n\nBrowse documents stored in iCloud Drive and other file providers without copying them into the app. This area is intentionally a placeholder until Phase 3 of the roadmap.")
            }
            .navigationTitle("Cloud")
        }
    }
}
