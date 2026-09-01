import SwiftUI

/// The five-tab home shell: Recent, Favorites, Tools, Cloud, Browse. Holds
/// the tab selection so app-icon quick actions can switch tabs.
struct HomeView: View {
    @Environment(QuickActionRouter.self) private var quickActions
    @Environment(\.scenePhase) private var scenePhase

    enum HomeTab: Hashable {
        case recent
        case favorites
        case tools
        case cloud
        case browse
    }

    @State private var selection: HomeTab = .recent

    var body: some View {
        TabView(selection: $selection) {
            Tab("Recent", systemImage: "clock", value: HomeTab.recent) {
                RecentTab()
            }
            Tab("Favorites", systemImage: "star", value: HomeTab.favorites) {
                FavoritesTab()
            }
            Tab("Tools", systemImage: "square.grid.2x2", value: HomeTab.tools) {
                ToolsTab()
            }
            Tab("Cloud", systemImage: "cloud", value: HomeTab.cloud) {
                CloudTab()
            }
            Tab("Browse", systemImage: "folder", value: HomeTab.browse) {
                BrowseTab()
            }
        }
        .onAppear(perform: routeStagedShortcut)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                routeStagedShortcut()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickActionShortcutReceived)) { _ in
            routeStagedShortcut()
        }
        .onChange(of: quickActions.pending) { _, _ in
            selectTabForPendingAction()
        }
    }

    /// Routes a shortcut UIKit delivered while the UI was not yet listening
    /// (cold launch) or live (foreground tap): consume it into `pending`,
    /// then switch to the fulfilling tab.
    private func routeStagedShortcut() {
        quickActions.consumeStagedShortcut()
        selectTabForPendingAction()
    }

    /// Switches to the tab that fulfills the pending quick action; the tab
    /// itself consumes `pending` once it is on screen.
    private func selectTabForPendingAction() {
        guard let pending = quickActions.pending else { return }
        selection = Self.tab(for: pending)
    }

    /// The tab each quick-action destination opens.
    static func tab(for destination: QuickActionRouter.Destination) -> HomeTab {
        switch destination {
        case .scan, .newDocument: .tools
        case .importFiles: .recent
        }
    }
}
