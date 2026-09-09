import SwiftUI

/// Chooses an app-owned folder for a Move action. The same picker is used
/// from single and bulk selection flows, and never exposes hidden journals.
struct FolderDestinationPicker: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderDestinationList(relativePath: "", onSelect: onSelect)
                .navigationDestination(for: String.self) { path in
                    FolderDestinationList(relativePath: path, onSelect: onSelect)
                }
                .navigationTitle("Move to…")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct FolderDestinationList: View {
    let relativePath: String
    let onSelect: (String) -> Void

    @Environment(DocumentStore.self) private var store
    @State private var folders: [FileBridge.FolderEntry] = []
    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var failureText: String?

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(relativePath)
                } label: {
                    Label("Choose this folder", systemImage: "checkmark.circle")
                }
            }

            Section("Folders") {
                if folders.isEmpty {
                    Text("No subfolders")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        NavigationLink(value: folder.relativePath) {
                            Label(folder.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(relativePath.isEmpty ? "Documents" : (relativePath as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderName = ""
                    showCreateFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("Create folder")
            }
        }
        .alert("New Folder", isPresented: $showCreateFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder inside \(relativePath.isEmpty ? "Documents" : (relativePath as NSString).lastPathComponent).")
        }
        .storeFailureAlert(message: $failureText)
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            folders = try store.fileBridge.folderContents(relativePath: relativePath)
                .filter(\.isDirectory)
        } catch {
            folders = []
            failureText = error.localizedDescription
        }
    }

    private func createFolder() {
        do {
            _ = try store.createFolder(named: newFolderName, inRelativePath: relativePath)
            reload()
        } catch {
            failureText = error.localizedDescription
        }
    }
}
