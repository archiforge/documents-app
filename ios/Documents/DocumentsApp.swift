import OSLog
import SwiftData
import SwiftUI

private let launchLog = Logger(subsystem: "com.docdeck.app", category: "launch")

@main
struct DocumentsApp: App {
    private let container: ModelContainer
    @State private var store: DocumentStore

    init() {
        do {
            container = try ModelContainer(
                for: Schema(versionedSchema: SchemaV2.self),
                migrationPlan: DocumentsSchemaMigrationPlan.self
            )
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

                    // Enforce the 30-day trash retention window. A failure
                    // here must never block launch; the purge retries next run.
                    do {
                        try store.purgeExpiredTrash()
                    } catch {
                        launchLog.error("Trash purge failed at launch: \(error.localizedDescription)")
                    }
                }
        }
        .modelContainer(container)
    }
}
