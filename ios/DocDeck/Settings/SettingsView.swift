import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings: granted folders, storage, and about text.
struct SettingsView: View {
    var grantService: FolderGrantService?

    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FolderGrant.addedAt)
    private var folderGrants: [FolderGrant]

    @Query(filter: #Predicate<DocumentRecord> { $0.isTrashed })
    private var trashedDocuments: [DocumentRecord]

    @State private var isPickingFolder = false
    @State private var confirmEmptyTrash = false
    @State private var failureText: String?

    var body: some View {
        NavigationStack {
            List {
                indexedFoldersSection
                storageSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        _ = try grantService?.addGrant(from: url)
                    } catch {
                        failureText = error.localizedDescription
                    }
                case .failure(let error):
                    failureText = error.localizedDescription
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

    // MARK: - Indexed folders

    /// Folders the user granted through the Files interface; their documents
    /// are indexed in place instead of being copied into the app container.
    private var indexedFoldersSection: some View {
        Section {
            if let grantService {
                let externalRecords = ((try? store.fetchRecent()) ?? [])
                    .filter { $0.absolutePath != nil }
                ForEach(folderGrants) { grant in
                    grantedFolderRow(
                        grant,
                        available: !grantService.unavailableIDs.contains(grant.id),
                        fileCount: externalRecords.filter {
                            $0.absolutePath?.hasPrefix(grant.resolvedPath + "/") == true
                        }.count
                    )
                }
                .onDelete { indexes in
                    for index in indexes {
                        do {
                            try grantService.removeGrant(folderGrants[index])
                        } catch {
                            failureText = error.localizedDescription
                        }
                    }
                }
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Text("Documents in granted folders are listed in place without being copied. iOS grants access to each folder once, through the Files interface.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Folder indexing is unavailable because the document library has not started.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Indexed Folders")
        }
    }

    private func grantedFolderRow(_ grant: FolderGrant, available: Bool, fileCount: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName)
                Text(available ? grant.resolvedPath : "Not available — the folder could not be opened")
                    .font(.caption)
                    .foregroundStyle(available ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if available {
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Folder unavailable")
            }
        }
    }

    // MARK: - Storage & about

    private var storageSection: some View {
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
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Text("Documents is an original SwiftUI implementation of a document hub. All code, assets, and wording are original and share nothing with any third-party application.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
