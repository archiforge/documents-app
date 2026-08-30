import SwiftUI
import UniformTypeIdentifiers

/// Compress: pick files from the Files picker and bundle them into
/// `Archive_<date>.zip` stored in the library.
struct CompressSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isPicking = false
    @State private var working = false
    @State private var errorMessage = ""
    @State private var showError = false

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Compress")
                    .font(.title2.bold())
                Text("Pick one or more files and Documents bundles them into a ZIP that is saved to your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if working {
                    ProgressView("Compressing…")
                        .padding(.top, 8)
                } else {
                    Button("Choose Files") {
                        isPicking = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .navigationTitle("Compress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handlePicker(result)
            }
        }
        .alert("Compression failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func handlePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            working = true
            Task { @MainActor in
                defer { working = false }
                do {
                    let data = try ArchiveService.zipData(fromFiles: urls)
                    let record = try store.saveGeneratedFile(name: "Archive_\(DateStamp.day()).zip", data: data)
                    try store.recordOpen(record)
                    dismiss()
                    onDone(
                        ToolMessage(title: "Compressed", body: "Saved as \(record.displayName)."),
                        PresentedDocument(record: record)
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// Extract: pick a .zip, unpack it into Documents/Extracted/<name>/, and
/// list the extracted files. Non-zip archives report pending support.
struct ExtractSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isPicking = false
    @State private var working = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var extractedNames: [String]?
    @State private var extractedFolder = ""

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.zip]
        for extensionName in ["7z", "rar"] {
            if let type = UTType(filenameExtension: extensionName) {
                types.append(type)
            }
        }
        return types
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "shippingbox.open")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Extract")
                    .font(.title2.bold())
                Text("Pick a ZIP archive and Documents unpacks it into a folder you can browse inside the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if working {
                    ProgressView("Extracting…")
                        .padding(.top, 8)
                } else {
                    Button("Choose Archive") {
                        isPicking = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .navigationTitle("Extract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePicker(result)
            }
        }
        .alert("Extraction failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(item: Binding(
            get: { extractedNames.map { ExtractedFiles(names: $0, folder: extractedFolder) } },
            set: { _ in extractedNames = nil }
        )) { payload in
            ExtractedFilesSheet(names: payload.names, folder: payload.folder) {
                extractedNames = nil
            }
        }
    }

    private struct ExtractedFiles: Identifiable {
        let id = UUID()
        let names: [String]
        let folder: String
    }

    private func handlePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.pathExtension.lowercased() == "zip" else {
                errorMessage = "Only ZIP archives can be extracted for now. Support for 7z and RAR arrives with libarchive in a later phase."
                showError = true
                return
            }
            extract(zipURL: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func extract(zipURL: URL) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let scoped = zipURL.startAccessingSecurityScopedResource()
                defer {
                    if scoped { zipURL.stopAccessingSecurityScopedResource() }
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("zip")
                try FileManager.default.copyItem(at: zipURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let folderName = zipURL.deletingPathExtension().lastPathComponent
                let destination = store.fileBridge.documentsDirectory
                    .appendingPathComponent("Extracted", isDirectory: true)
                    .appendingPathComponent(folderName, isDirectory: true)
                let files = try ArchiveService.extract(zipAt: tempURL, into: destination)
                extractedFolder = "Extracted/\(folderName)"
                extractedNames = files
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

/// Result sheet listing what an extraction produced.
struct ExtractedFilesSheet: View {
    let names: [String]
    let folder: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if names.isEmpty {
                    Text("The archive was empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(names, id: \.self) { name in
                        Label(name, systemImage: "doc")
                    }
                }
            }
            .navigationTitle("Extracted \(names.count) File(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Find them in Browse → \(folder).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
