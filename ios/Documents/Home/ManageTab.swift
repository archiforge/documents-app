import SwiftData
import SwiftUI

/// The document hub's management surface: app-created documents, source
/// browsing, recently deleted items, and the existing Settings flow.
struct ManageTab: View {
    @Environment(DeviceLibraryService.self) private var library

    @Query(
        filter: #Predicate<DocumentRecord> { $0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var trashedDocuments: [DocumentRecord]

    @Query(sort: \FolderGrant.addedAt)
    private var folderGrants: [FolderGrant]

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                createdSection
                privateSafeSection
                sourcesSection
                recentlyDeletedSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Manage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var createdSection: some View {
        Section {
            NavigationLink {
                CreatedDocumentsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Created by me")
                        Text("Documents made in Documents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private var sourcesSection: some View {
        Section("Sources") {
            NavigationLink {
                BrowseTab(rootTitle: "Documents")
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Files imports")
                        Text("Documents stored in this app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                }
            }

            ForEach(folderGrants) { grant in
                let available = library.grantService?.resolvedFolders.contains {
                    $0.standardizedFileURL.path == grant.resolvedPath
                } == true
                if available {
                    NavigationLink {
                        BrowseTab(
                            rootURL: URL(fileURLWithPath: grant.resolvedPath),
                            rootTitle: grant.displayName,
                            appOwned: false
                        )
                    } label: {
                        sourceRow(grant, available: true)
                    }
                } else {
                    sourceRow(grant, available: false)
                }
            }
        }
    }

    private var privateSafeSection: some View {
        Section {
            NavigationLink {
                PrivateSafeView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private Safe")
                        Text("Encrypted copies stored on this device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.tint)
                }
            }
            .accessibilityIdentifier("private-safe-entry")
        }
    }

    private func sourceRow(_ grant: FolderGrant, available: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName)
                Text(available ? "Indexed folder" : "Folder unavailable")
                    .font(.caption)
                    .foregroundStyle(available ? Color.secondary : Color.orange)
                }
            } icon: {
                Image(systemName: available ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(available ? Color.green : Color.orange)
            }
    }

    private var recentlyDeletedSection: some View {
        Section {
            NavigationLink {
                TrashView()
            } label: {
                HStack {
                    Label("Recently deleted", systemImage: "trash")
                    Spacer()
                    Text("\(trashedDocuments.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A focused list of records produced inside the app.
struct CreatedDocumentsView: View {
    @Environment(DocumentStore.self) private var store

    @Query(
        filter: #Predicate<DocumentRecord> { !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var documents: [DocumentRecord]

    @State private var presentedDocument: PresentedDocument?
    @State private var failureText: String?

    private var createdDocuments: [DocumentRecord] {
        documents.filter {
            switch $0.provenance {
            case .created, .scanned, .converted:
                true
            case .imported, .device, .cloud:
                false
            }
        }
    }

    var body: some View {
        Group {
            if createdDocuments.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Created Yet", systemImage: "doc.badge.plus")
                } description: {
                    Text("Documents you create, scan, or convert will appear here.")
                }
            } else {
                List(createdDocuments) { record in
                    DocumentRow(record: record) {
                        open(record)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Created by me")
        .documentViewer(item: $presentedDocument)
        .storeFailureAlert(message: $failureText)
    }

    private func open(_ record: DocumentRecord) {
        do {
            try store.recordOpen(record)
        } catch {
            failureText = error.localizedDescription
        }
        presentedDocument = PresentedDocument(record: record)
    }
}
