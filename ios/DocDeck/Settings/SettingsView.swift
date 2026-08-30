import SwiftData
import SwiftUI

/// Placeholder settings: version, trash management, and about text.
struct SettingsView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<DocumentRecord> { $0.isTrashed })
    private var trashedDocuments: [DocumentRecord]

    @State private var confirmEmptyTrash = false
    @State private var failureText: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    NavigationLink {
                        TrashView()
                    } label: {
                        HStack {
                            Label("Trash", systemImage: "trash")
                            Spacer()
                            Text("\(trashedDocuments.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        confirmEmptyTrash = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .disabled(trashedDocuments.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Text("DocDeck is an original SwiftUI implementation of a document hub. All code, assets, and wording are original and share nothing with any third-party application.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Empty the trash?",
                isPresented: $confirmEmptyTrash,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) {
                    do {
                        try store.emptyTrash()
                    } catch {
                        failureText = error.localizedDescription
                    }
                }
            } message: {
                Text("Items in the trash will be permanently deleted. This cannot be undone.")
            }
            .storeFailureAlert(message: $failureText)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
