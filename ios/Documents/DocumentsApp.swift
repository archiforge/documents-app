import OSLog
import SwiftData
import SwiftUI

private let launchLog = Logger(subsystem: "com.docdeck.app", category: "launch")

@main
struct DocumentsApp: App {
    private let container: ModelContainer
    @State private var store: DocumentStore
    /// App-scoped device library: created once, injected via the environment,
    /// so indexing survives tab switches and view churn.
    @State private var library = DeviceLibraryService()
    /// App-icon quick actions (Scan / Import / New Text), routed to tabs.
    @State private var quickActions = QuickActionRouter()
    /// Bridges UIKit's shortcut delivery to `QuickActionRouter`.
    @UIApplicationDelegateAdaptor(QuickActionDelegate.self) private var quickActionDelegate

    init() {
        do {
            container = try ModelContainer(
                for: Schema(versionedSchema: SchemaV3.self),
                migrationPlan: DocumentsSchemaMigrationPlan.self
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        _store = State(initialValue: DocumentStore(context: container.mainContext))
        QuickActionRouter.installShortcutItems()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(library)
                .environment(quickActions)
                .task {
                    // Remove temp artifacts left behind by previous runs
                    // (crash, force quit) that the in-registry cleanup missed.
                    TempArtifactTracker.sweepAtLaunch()

                    // Reconcile records against the disk before the library
                    // adopts anything. Failures are logged, never fatal.
                    await StartupRecovery.run(store: store)

                    // Enforce the 30-day trash retention window. A failure
                    // here must never block launch; the purge retries next run.
                    do {
                        try store.purgeExpiredTrash()
                    } catch {
                        launchLog.error("Trash purge failed at launch: \(error.localizedDescription)")
                    }

                    library.start(store: store)
                }
        }
        .modelContainer(container)
    }
}
