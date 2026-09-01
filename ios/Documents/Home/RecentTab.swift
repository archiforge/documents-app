import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Recents list with format filter chips
/// (All / Scanned / PDF / DOC / EPUB / XLS / TXT), a search bar scoped
/// to the active chip, day grouping ("Today · 4 files"), and per-row origin
/// captions.
struct RecentTab: View {
    @Environment(DocumentStore.self) private var store
    /// App-scoped library owned by `DocumentsApp`; indexing survives tab
    /// switches because this view no longer starts or stops it.
    @Environment(DeviceLibraryService.self) private var library
    /// App-icon quick actions: "Import Files" lands here.
    @Environment(QuickActionRouter.self) private var quickActions

    @Query(
        filter: #Predicate<DocumentRecord> { !$0.isTrashed },
        sort: \DocumentRecord.importedAt,
        order: .reverse
    )
    private var documents: [DocumentRecord]

    @State private var filter: FormatFilter = .all
    @State private var sort = DocumentSort.defaultSort
    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var selection = BulkSelection()

    @State private var isImporting = false
    @State private var presentedDocument: PresentedDocument?
    @State private var showSettings = false
    @State private var importErrorText = ""
    @State private var showImportError = false
    @State private var pdfToolsSource: DocumentRecord?
    @State private var failureText: String?

    private var filtered: [DocumentRecord] {
        sort.sorted(documents.filter {
            filter.matches($0) && DocumentSearch.matches(searchText, name: $0.displayName)
        })
    }

    /// Whether the user typed anything, so an empty result set can be
    /// attributed to the search rather than the format chip.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FormatFilterRow(selection: $filter)
                if documents.isEmpty {
                    emptyState
                } else {
                    // Attached to the stable Group, not the List: the field
                    // must survive the list↔empty-state swap or it dismisses
                    // mid-typing whenever the last match disappears.
                    Group {
                        if filtered.isEmpty {
                            resultsEmptyState
                        } else {
                            documentList
                        }
                    }
                    .searchable(text: $searchText, prompt: searchPrompt)
                    .bulkSelectionActions(selection: $selection, selectedRecords: chosen)
                }
            }
            .navigationTitle(selectionTitle)
            .navigationBarTitleDisplayMode(selection.isActive ? .inline : .automatic)
            // iOS 26 merges a bottom bar into the floating tab bar's glass
            // and the two fight for touches; selection mode claims the zone,
            // like Files/Photos do.
            .toolbar(selection.isActive ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selection.isActive {
                        Button("Cancel") {
                            selection.exit()
                        }
                    } else if library.isIndexing {
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
                    if selection.isActive {
                        selectAllButton
                    } else {
                        sortMenu
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selection.isActive {
                        Button("Select", systemImage: "checkmark.circle") {
                            selection.enter()
                        }
                        .disabled(documents.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selection.isActive {
                        Button("Import", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
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
                SettingsView()
            }
            .documentViewer(item: $presentedDocument)
            .onAppear(perform: consumeQuickAction)
            .onChange(of: quickActions.pending) { _, _ in
                consumeQuickAction()
            }
        }
    }

    /// Fulfills the "Import Files" app-icon quick action when this tab is on
    /// screen; other destinations are left for their own tabs.
    private func consumeQuickAction() {
        guard quickActions.pending == .importFiles else { return }
        quickActions.pending = nil
        isImporting = true
    }

    // MARK: - List

    /// Sort/order-by menu (board R3.2/R3.12). Date keeps the day-grouped
    /// layout; other fields render a flat list.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort.field) {
                ForEach(DocumentSort.Field.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            Picker("Order", selection: $sort.isDescending) {
                Text("Descending").tag(true)
                Text("Ascending").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }

    private var documentList: some View {
        let records = filtered
        return List {
            Section {
                Text("\(records.count) in total")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if sort.field == .date {
                dateSections(records)
            } else {
                Section {
                    ForEach(records) { document in
                        row(for: document)
                    }
                }
            }
        }
        .listStyle(.plain)
        .fullScreenCover(item: $pdfToolsSource) { record in
            PDFToolsScreen(source: record)
        }
    }

    @ViewBuilder
    private func dateSections(_ records: [DocumentRecord]) -> some View {
        let groups = DateGrouping.groups(for: records.map(\.creationDate))
        ForEach(groups) { group in
            Section {
                if !collapsedGroups.contains(group.key) {
                    ForEach(records.filter { sameGroup($0.creationDate, as: group) }) { document in
                        row(for: document)
                    }
                }
            } header: {
                groupHeader(group, records: records)
            }
        }
    }

    private func groupHeader(_ group: DateGrouping.Group, records: [DocumentRecord]) -> some View {
        let count = records.filter { sameGroup($0.creationDate, as: group) }.count
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

    @ViewBuilder
    private func row(for document: DocumentRecord) -> some View {
        if selection.isActive {
            DocumentRow(
                record: document,
                isSelecting: true,
                isSelected: selection.contains(document.id)
            ) {
                selection.toggle(document.id)
            }
        } else {
            DocumentRow(record: document) {
                open(document)
            }
            .documentActions(
                record: document,
                onOpen: { open(document) },
                onPDFTools: document.kind == .pdf ? { pdfToolsSource = document } : nil
            )
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

    /// Empty result set: blame the search query when one is active,
    /// otherwise the format chip.
    @ViewBuilder
    private var resultsEmptyState: some View {
        if isSearching {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No documents matching \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\".")
            }
        } else {
            ContentUnavailableView {
                Label("No Documents", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Nothing under \(filter.title) yet.")
            }
        }
    }

    // MARK: - Helpers

    /// Large "Recent" normally; selection mode shows an inline count
    /// instead (board R3.8). Rows selected under a narrower chip/search
    /// stay selected, so the count resolves against the whole library —
    /// it always matches what the bulk bar would act on.
    private var selectionTitle: String {
        guard selection.isActive else { return "Recent" }
        return selection.count == 0 ? "Select Items" : "\(selection.count) Selected"
    }

    /// Select-all is scoped to what the chip + search currently show.
    private var selectAllButton: some View {
        let ids = filtered.map(\.id)
        let allSelected = selection.allSelected(in: ids)
        return Button(allSelected ? "Deselect All" : "Select All") {
            if allSelected {
                selection.deselectAll()
            } else {
                selection.selectAll(ids)
            }
        }
    }

    /// Records the bulk bar acts on: every selected row still in the
    /// library, including ones hidden by the current chip/search.
    private var chosen: [DocumentRecord] {
        documents.filter { selection.contains($0.id) }
    }

    /// Reflects the active chip so the scoping is visible in the field
    /// itself ("Search in PDF").
    private var searchPrompt: Text {
        filter == .all ? Text("Search") : Text("Search in \(filter.title)")
    }

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
