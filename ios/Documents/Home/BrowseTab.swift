import SwiftUI
import UniformTypeIdentifiers

/// Folder browser over either the app container or a granted folder.
/// Granted folders are deliberately read-only; app-owned Documents supports
/// importing and creating folders.
struct BrowseTab: View {
    let rootURL: URL
    let rootTitle: String
    let appOwned: Bool

    @State private var presentedDocument: PresentedDocument?

    init(
        rootURL: URL = FileBridge.defaultDocumentsDirectory,
        rootTitle: String = "Documents",
        appOwned: Bool = true
    ) {
        self.rootURL = rootURL
        self.rootTitle = rootTitle
        self.appOwned = appOwned
    }

    var body: some View {
        DirectoryContentsView(
            directoryURL: rootURL,
            directoryRelativePath: appOwned ? "" : nil,
            presentedDocument: $presentedDocument,
            rootTitle: rootTitle,
            isRoot: true,
            appOwned: appOwned
        )
        .navigationDestination(for: DirectoryContentsView.Route.self) { route in
            DirectoryContentsView(
                directoryURL: route.url,
                directoryRelativePath: route.relativePath,
                presentedDocument: $presentedDocument,
                rootTitle: rootTitle,
                isRoot: false,
                appOwned: appOwned
            )
        }
        .documentViewer(item: $presentedDocument)
    }
}

/// Contents of one directory: folders push deeper, files open in the viewer.
struct DirectoryContentsView: View {
    let directoryURL: URL
    let directoryRelativePath: String?
    @Binding var presentedDocument: PresentedDocument?
    let rootTitle: String
    let isRoot: Bool
    let appOwned: Bool

    @Environment(DocumentStore.self) private var store
    @State private var entries: [Entry] = []
    @State private var isImporting = false
    @State private var showImportError = false
    @State private var importErrorText = ""
    @State private var pdfToolsSource: DocumentRecord?
    @State private var failureText: String?
    @State private var showCreateFolder = false
    @State private var newFolderName = ""

    struct Route: Hashable {
        let url: URL
        let relativePath: String?
    }

    struct Entry: Identifiable {
        let name: String
        let url: URL
        let relativePath: String?
        let isDirectory: Bool
        var id: String { url.path }
    }

    private var canEdit: Bool {
        appOwned && directoryRelativePath != nil
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(value: Route(url: entry.url, relativePath: entry.relativePath)) {
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
        .navigationTitle(isRoot ? rootTitle : directoryURL.lastPathComponent)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "folder")
                } description: {
                    Text(canEdit
                        ? "This folder is empty. Import files or create a folder to get started."
                        : "This folder is empty.")
                } actions: {
                    if canEdit {
                        Button("Import") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showCreateFolder = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add to folder")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            if let message = importPickerResultIntoCurrentFolder(result) {
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
        .alert("New Folder", isPresented: $showCreateFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder inside \(directoryURL.lastPathComponent).")
        }
        .storeFailureAlert(message: $failureText)
        .onAppear { reload() }
    }

    private func importPickerResultIntoCurrentFolder(_ result: Result<[URL], any Error>) -> String? {
        guard let destinationPath = directoryRelativePath else {
            return "Files can only be imported into the app's Documents folder."
        }
        switch result {
        case .success(let urls):
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try store.importFile(from: url, intoRelativeFolder: destinationPath)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return failures.isEmpty ? nil : failures.joined(separator: "\n")
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private func reload() {
        if canEdit, let relativePath = directoryRelativePath {
            do {
                entries = try store.fileBridge.folderContents(relativePath: relativePath).map {
                    Entry(
                        name: $0.name,
                        url: $0.url,
                        relativePath: $0.relativePath,
                        isDirectory: $0.isDirectory
                    )
                }
            } catch {
                entries = []
                failureText = error.localizedDescription
            }
            return
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        entries = contents.compactMap { url in
            guard
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                values.isDirectory == true || values.isRegularFile == true
            else { return nil }
            return Entry(
                name: url.lastPathComponent,
                url: url,
                relativePath: nil,
                isDirectory: values.isDirectory == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func createFolder() {
        guard let directoryRelativePath else { return }
        do {
            _ = try store.createFolder(named: newFolderName, inRelativePath: directoryRelativePath)
            reload()
        } catch {
            failureText = error.localizedDescription
        }
    }

    private func openFile(at url: URL) {
        if let relativePath = directoryRelativePath.map({ path in
            path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
        }), let record = try? store.record(forRelativePath: relativePath) {
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
    /// is not already tracked. This records metadata only; granted source
    /// bytes remain in their original folder.
    private func openPDFTools(for url: URL) {
        do {
            let record: DocumentRecord
            if let relativePath = directoryRelativePath.map({ path in
                path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
            }), let existing = try store.record(forRelativePath: relativePath) {
                record = existing
            } else if !appOwned,
                      let existing = try store.record(forAbsolutePath: url.standardizedFileURL.path) {
                record = existing
            } else {
                record = try store.adoptFile(
                    at: url,
                    absolutePath: appOwned ? nil : url.standardizedFileURL.path
                )
            }
            pdfToolsSource = record
        } catch {
            failureText = error.localizedDescription
        }
    }
}
