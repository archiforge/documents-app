import SwiftUI

/// The five-tab home shell: Recent, Favorites, Tools, Cloud, Browse.
struct HomeView: View {
    var body: some View {
        TabView {
            Tab("Recent", systemImage: "clock") {
                RecentTab()
            }
            Tab("Favorites", systemImage: "star") {
                FavoritesTab()
            }
            Tab("Tools", systemImage: "square.grid.2x2") {
                ToolsTab()
            }
            Tab("Cloud", systemImage: "cloud") {
                CloudTab()
            }
            Tab("Browse", systemImage: "folder") {
                BrowseTab()
            }
        }
    }
}
