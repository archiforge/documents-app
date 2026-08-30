import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Recents list with the Android app's format filter chips
/// (All / Scanned / DOC / XLS / PPT / PDF / OFD / TXT), day grouping
/// ("Today · 4 files"), and per-row origin captions.
struct RecentTab: View {
    @Environment(DocumentStore.self) private var store

    @Query(
        filter: #Predicate<DocumentRecord> { !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var documents: [DocumentRecord]

    @State private var filter: FormatFilter = .all
    @State private var collapsedGroups: Set<String> = []
    @State private var library = DeviceLibraryService()

    @State private var isImporting = false
    @State private var presentedDocument: PresentedDocument?
    @State private var showSettings = false
    @State private var importErrorText = ""
    @State private var showImportError = false
    @State private var pdfToolsSource: DocumentRecord?
    @State private var failureText: String?

    private var filtered: [DocumentRecord] {
        documents.filter { filter.matches($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FormatFilterRow(selection: $filter)
                if documents.isEmpty {
                    emptyState
                } else if filtered.isEmpty {
                    filterEmptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Recent")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if library.isIndexing {
                        ProgressView()
                            .accessibilityLabel("Indexing device documents")
                    } else {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if let message = importPickerResult(result, store: store) {
                    importErrorText = message
                    showImportError = true
                }
            }
            .alert("Import failed", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorText)
            }
            .storeFailureAlert(message: $failureText)
            .sheet(isPresented: $showSettings) {
                SettingsView(grantService: library.grantService)
            }
            .documentViewer(item: $presentedDocument)
        }
        .task {
            library.start(store: store)
        }
        .onDisappear {
            library.stop()
        }
    }

    // MARK: - List

    private var documentList: some View {
        let records = filtered
        let groups = DateGrouping.groups(for: records.map(\.lastOpenedAt))
        return List {
            Section {
                Text("\(records.count) in total")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    if !collapsedGroups.contains(group.key) {
                        ForEach(records.filter { sameGroup($0.lastOpenedAt, as: group) }) { document in
                            row(for: document)
                        }
                    }
                } header: {
                    groupHeader(group, records: records)
                }
            }
        }
        .listStyle(.plain)
        .fullScreenCover(item: $pdfToolsSource) { record in
            PDFToolsScreen(source: record)
        }
    }

    private func groupHeader(_ group: DateGrouping.Group, records: [DocumentRecord]) -> some View {
        let count = records.filter { sameGroup($0.lastOpenedAt, as: group) }.count
        let isCollapsed = collapsedGroups.contains(group.key)
        return Button {
            toggleGroup(group.key)
        } label: {
            HStack {
                Text("\(group.title) · \(count) file\(count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .textCase(nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(count) files\(isCollapsed ? ", collapsed" : "")")
    }

    private func row(for document: DocumentRecord) -> some View {
        DocumentRow(record: document) {
            open(document)
        }
        .contextMenu {
            if document.kind == .pdf {
                Button {
                    pdfToolsSource = document
                } label: {
                    Label("PDF Tools", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                do {
                    try store.trash(document)
                } catch {
                    failureText = error.localizedDescription
                }
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                do {
                    try store.toggleFavorite(document)
                } catch {
                    failureText = error.localizedDescription
                }
            } label: {
                Label(
                    document.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: document.isFavorite ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Documents", systemImage: "doc.text")
        } description: {
            Text("Import files from the Files app to see them here.")
        } actions: {
            Button("Import") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("No Documents", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Nothing under \(filter.title) yet.")
        }
    }

    // MARK: - Helpers

    private func sameGroup(_ date: Date, as group: DateGrouping.Group) -> Bool {
        DateGrouping.group(for: date).key == group.key
    }

    private func toggleGroup(_ key: String) {
        withAnimation(.snappy) {
            if !collapsedGroups.insert(key).inserted {
                collapsedGroups.remove(key)
            }
        }
    }

    private func open(_ document: DocumentRecord) {
        do {
            try store.recordOpen(document)
        } catch {
            failureText = error.localizedDescription
        }
        presentedDocument = PresentedDocument(record: document)
    }
}
