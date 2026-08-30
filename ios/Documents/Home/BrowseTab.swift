import SwiftUI
import UniformTypeIdentifiers

/// Folder browser over the app container's Documents directory.
struct BrowseTab: View {
    @State private var presentedDocument: PresentedDocument?

    var body: some View {
        NavigationStack {
            DirectoryContentsView(
                directoryURL: FileBridge.defaultDocumentsDirectory,
                presentedDocument: $presentedDocument,
                isRoot: true
            )
            .navigationDestination(for: URL.self) { url in
                DirectoryContentsView(
                    directoryURL: url,
                    presentedDocument: $presentedDocument,
                    isRoot: false
                )
            }
        }
        .documentViewer(item: $presentedDocument)
    }
}

/// Contents of one directory: folders push deeper, files open in the viewer.
struct DirectoryContentsView: View {
    let directoryURL: URL
    @Binding var presentedDocument: PresentedDocument?
    let isRoot: Bool

    @Environment(DocumentStore.self) private var store
    @State private var entries: [Entry] = []
    @State private var isImporting = false
    @State private var showImportError = false
    @State private var importErrorText = ""
    @State private var pdfToolsSource: DocumentRecord?
    @State private var failureText: String?

    struct Entry: Identifiable {
        let name: String
        let url: URL
        let isDirectory: Bool
        var id: String { url.path }
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(value: entry.url) {
                        Label(entry.name, systemImage: "folder.fill")
                    }
                } else {
                    Button {
                        openFile(at: entry.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: DocumentKind(filename: entry.name).symbolName)
                                .foregroundStyle(.tint)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            Text(FileBridge.fileSize(at: entry.url), format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if DocumentKind(filename: entry.name) == .pdf {
                            Button {
                                openPDFTools(for: entry.url)
                            } label: {
                                Label("PDF Tools", systemImage: "wrench.and.screwdriver")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .fullScreenCover(item: $pdfToolsSource) { record in
            PDFToolsScreen(source: record)
        }
        .navigationTitle(isRoot ? "Browse" : directoryURL.lastPathComponent)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "folder")
                } description: {
                    Text("This folder is empty. Import files to get started.")
                } actions: {
                    Button("Import") {
                        isImporting = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
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
            reload()
        }
            .alert("Import failed", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorText)
            }
            .storeFailureAlert(message: $failureText)
        .onAppear { reload() }
    }

    private func reload() {
        var loaded: [Entry] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            loaded = contents.map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return Entry(name: url.lastPathComponent, url: url, isDirectory: isDirectory)
            }
        }
        entries = loaded.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func openFile(at url: URL) {
        let relativePath = store.fileBridge.relativePath(for: url)
        if let record = try? store.record(forRelativePath: relativePath) {
            do {
                try store.recordOpen(record)
            } catch {
                failureText = error.localizedDescription
            }
            presentedDocument = PresentedDocument(record: record)
        } else {
            presentedDocument = PresentedDocument(url: url)
        }
    }

    /// Hands a browsed PDF to the toolbox, adopting it into the store if it
    /// is not already tracked.
    private func openPDFTools(for url: URL) {
        let relativePath = store.fileBridge.relativePath(for: url)
        do {
            if let record = try store.record(forRelativePath: relativePath) {
                pdfToolsSource = record
            } else {
                pdfToolsSource = try store.adoptFile(at: url)
            }
        } catch {
            // A file that cannot be adopted simply gets no toolbox entry.
        }
    }
}
