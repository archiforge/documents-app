import SwiftData
import SwiftUI

@main
struct DocDeckApp: App {
    private let container: ModelContainer
    @State private var store: DocumentStore

    init() {
        do {
            container = try ModelContainer(for: DocumentRecord.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        _store = State(initialValue: DocumentStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .task {
                    // Remove temp artifacts left behind by previous runs
                    // (crash, force quit) that the in-registry cleanup missed.
                    TempArtifactTracker.sweepAtLaunch()
                }
        }
        .modelContainer(container)
    }
}
