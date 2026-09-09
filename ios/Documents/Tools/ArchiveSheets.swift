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

/// Extract: pick a ZIP, 7z, or RAR archive, unpack it into
/// Documents/Extracted/<name>/, and list the extracted files.
struct ExtractSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isPicking = false
    @State private var working = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var extractedNames: [String]?
    @State private var extractedFolder = ""
    @State private var extractionTask: Task<Void, Never>?

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
                Image(systemName: "shippingbox")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Extract")
                    .font(.title2.bold())
                Text("Pick a ZIP, 7z, or RAR archive and Documents unpacks it into a folder you can browse inside the app.")
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
                    Button("Cancel") { cancelExtraction() }
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
        .onDisappear {
            extractionTask?.cancel()
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

    private struct ExtractionResult: Sendable {
        let stagingURL: URL
        let folderName: String
        let names: [String]
    }

    private func handlePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            extract(archiveURL: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func extract(archiveURL: URL) {
        extractionTask?.cancel()
        working = true
        let fileBridge = store.fileBridge
        let archiveExtension = archiveURL.pathExtension.lowercased()
        let folderName = archiveURL.deletingPathExtension().lastPathComponent
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        let worker = Task.detached(priority: .userInitiated) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Documents-Archive-\(UUID().uuidString)")
                .appendingPathExtension(archiveExtension)
            let stagingURL = try fileBridge.makeArchiveStagingDirectory()
            var keepStaging = false
            defer {
                try? FileManager.default.removeItem(at: tempURL)
                if !keepStaging {
                    fileBridge.removeArchiveStagingDirectory(stagingURL)
                }
            }

            try Task.checkCancellation()
            try FileManager.default.copyItem(at: archiveURL, to: tempURL)
            try Task.checkCancellation()
            let names = try ArchiveService.extract(
                archiveAt: tempURL,
                into: stagingURL
            )
            try Task.checkCancellation()
            keepStaging = true
            return ExtractionResult(
                stagingURL: stagingURL,
                folderName: folderName,
                names: names
            )
        }

        extractionTask = Task { @MainActor in
            var result: ExtractionResult?
            defer {
                if scoped { archiveURL.stopAccessingSecurityScopedResource() }
                working = false
                extractionTask = nil
            }
            do {
                result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard let result else { return }

                let destination = try fileBridge.makeArchiveExtractionDestination(
                    named: result.folderName
                )
                do {
                    try FileManager.default.moveItem(
                        at: result.stagingURL,
                        to: destination.url
                    )
                } catch {
                    fileBridge.removeArchiveStagingDirectory(result.stagingURL)
                    throw error
                }
                extractedFolder = destination.relativePath
                extractedNames = result.names
            } catch is CancellationError {
                if let stagingURL = result?.stagingURL {
                    fileBridge.removeArchiveStagingDirectory(stagingURL)
                }
            } catch {
                if let stagingURL = result?.stagingURL {
                    fileBridge.removeArchiveStagingDirectory(stagingURL)
                }
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func cancelExtraction() {
        extractionTask?.cancel()
        extractionTask = nil
        working = false
        dismiss()
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
                Text("Find them in Manage → Files imports → \(folder).")
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
