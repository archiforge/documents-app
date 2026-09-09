import PDFKit
import SwiftUI
import UIKit

/// The local Private Safe entry surface. The locked state deliberately shows
/// no item names, counts, or thumbnails until user presence succeeds.
struct PrivateSafeView: View {
    @Environment(PrivateSafeSession.self) private var session
    @State private var export: PrivateSafeExport?
    @State private var preview: PrivateSafePreview?
    @State private var pendingDelete: PrivateSafeItem?
    @State private var resetRequested = false
    @State private var errorMessage: String?
    @State private var unlockTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch session.state {
            case .locked, .unlocking, .unavailable:
                lockedContent
            case .unlocked:
                unlockedContent
            }
        }
        .navigationTitle("Private Safe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.isUnlocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await session.lock() }
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("Lock Private Safe")
                }
            }
        }
        .overlay {
            if session.isPrivacyCovered {
                PrivateSafePrivacyCover()
            }
        }
        .sheet(item: $export) { export in
            PrivateSafeExportSheet(url: export.url)
        }
        .sheet(item: $preview) { preview in
            PrivateSafePreviewSheet(url: preview.url)
        }
        .alert("Private Safe", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this Private Safe copy?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    do {
                        try await session.delete(itemID: item.id)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog(
            "Delete the unavailable Private Safe?",
            isPresented: $resetRequested,
            titleVisibility: .visible
        ) {
            Button("Delete Encrypted Safe", role: .destructive) {
                Task {
                    do {
                        try await session.resetUnavailableVault()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every encrypted copy and its device-only key. There is no recovery code or cloud backup.")
        }
        .onDisappear {
            unlockTask?.cancel()
            exportTask?.cancel()
            previewTask?.cancel()
            unlockTask = nil
            exportTask = nil
            previewTask = nil
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 18) {
            Image(systemName: session.isUnlocked ? "lock.open" : "lock.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Private Safe")
                .font(.title2.weight(.semibold))
            Text(lockedMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if case .unlocking = session.state {
                ProgressView("Unlocking…")
                    .accessibilityIdentifier("private-safe-unlocking")
            } else {
                Button("Unlock") {
                    unlockTask?.cancel()
                    unlockTask = Task { await session.unlock() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Unlock Private Safe")
            }
            if case .unavailable = session.state {
                Button("Delete Unavailable Safe", role: .destructive) {
                    resetRequested = true
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityIdentifier("private-safe-lock-screen")
    }

    private var unlockedContent: some View {
        Group {
            if session.items.isEmpty {
                ContentUnavailableView {
                    Label("Private Safe Is Empty", systemImage: "lock.doc")
                } description: {
                    Text("Save a copy from a document's actions to keep an encrypted local copy.")
                }
            } else {
                List(session.items) { item in
                    PrivateSafeItemRow(item: item) {
                        previewItem(item)
                    } onExport: {
                        exportItem(item)
                    } onDelete: {
                        pendingDelete = item
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var lockedMessage: String {
        switch session.state {
        case .unavailable(let message):
            message
        case .unlocking:
            "Authenticate with Face ID or your device passcode."
        default:
            "Authenticate with Face ID or your device passcode to view encrypted copies."
        }
    }

    private func exportItem(_ item: PrivateSafeItem) {
        exportTask?.cancel()
        exportTask = Task {
            do {
                let url = try await session.export(itemID: item.id)
                guard !Task.isCancelled, session.isUnlocked else {
                    await session.releaseTemporaryFile(url)
                    return
                }
                export = PrivateSafeExport(url: url)
            } catch {
                guard !Task.isCancelled, session.isUnlocked else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func previewItem(_ item: PrivateSafeItem) {
        previewTask?.cancel()
        previewTask = Task {
            do {
                let url = try await session.preview(itemID: item.id)
                guard !Task.isCancelled, session.isUnlocked else {
                    await session.releaseTemporaryFile(url)
                    return
                }
                preview = PrivateSafePreview(url: url)
            } catch {
                guard !Task.isCancelled, session.isUnlocked else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PrivateSafeItemRow: View {
    let item: PrivateSafeItem
    let onPreview: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.doc.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button {
                    onPreview()
                } label: {
                    Label("Open Preview", systemImage: "eye")
                }
                Button {
                    onExport()
                } label: {
                    Label("Export Copy", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Copy", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(item.displayName)")
        }
        .padding(.vertical, 4)
    }
}

private struct PrivateSafePreviewSheet: View {
    @Environment(PrivateSafeSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let url: URL

    var body: some View {
        NavigationStack {
            Group {
                if session.isPrivacyCovered || !session.isUnlocked {
                    PrivateSafePrivacyCover()
                } else {
                    previewContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(
                session.isPrivacyCovered || !session.isUnlocked
                    ? "Private Safe"
                    : url.deletingPathExtension().lastPathComponent
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear {
            Task { await session.releaseTemporaryFile(url) }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { dismiss() }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: url) {
            PrivateSafePDFPreview(document: document)
        } else if ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(ext),
                  let image = UIImage(contentsOfFile: url.path) {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
        } else if ["txt", "md", "markdown", "json", "csv", "rtf", "log"].contains(ext),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= 2 * 1_024 * 1_024,
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            ContentUnavailableView {
                Label("Preview Unavailable", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Use Export Copy to share this file after reviewing the plaintext warning.")
            }
        }
    }
}

private struct PrivateSafePDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}

/// A controlled export surface keeps the warning and cleanup lease visible;
/// callers cannot accidentally use a Quick Look share toolbar that bypasses
/// the app's temporary-file lifecycle.
private struct PrivateSafeExportSheet: View {
    @Environment(PrivateSafeSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let url: URL
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            Group {
                if session.isPrivacyCovered || !session.isUnlocked {
                    PrivateSafePrivacyCover()
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.doc")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Export a plaintext copy")
                            .font(.title3.weight(.semibold))
                        Text("The recipient may keep the exported file after Documents removes its temporary copy.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            isSharing = true
                        } label: {
                            Label("Share Copy", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            PrivateSafeActivityView(url: url) {
                isSharing = false
                Task {
                    await session.releaseTemporaryFile(url)
                    dismiss()
                }
            }
        }
        .onDisappear {
            Task { await session.releaseTemporaryFile(url) }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked {
                isSharing = false
                dismiss()
            }
        }
    }
}

struct PrivateSafePrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title)
                Text("Private Safe is protected")
                    .font(.headline)
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("private-safe-privacy-cover")
    }
}

/// Copy action sheet used by DocumentActions. The source is resolved only for
/// the duration of the operation and is never copied into a plaintext cache.
struct PrivateSafeCopySheet: View {
    let record: DocumentRecord

    @Environment(PrivateSafeSession.self) private var session
    @Environment(DocumentStore.self) private var store
    @Environment(DeviceLibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var copyTask: Task<Void, Never>?
    @State private var unlockTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(record.displayName, systemImage: "doc")
                        .lineLimit(2)
                } header: {
                    Text("Source")
                }
                Section {
                    if session.isUnlocked {
                        Button {
                            saveCopy()
                        } label: {
                            Label("Save Encrypted Copy", systemImage: "lock.doc")
                        }
                        .disabled(isWorking)
                    } else {
                        Button("Unlock Private Safe") {
                            unlockTask?.cancel()
                            unlockTask = Task { @MainActor in
                                await session.unlock()
                                guard !Task.isCancelled else { return }
                                if case .unavailable(let message) = session.state {
                                    errorMessage = message
                                }
                            }
                        }
                        .disabled(isWorking)
                    }
                    if isWorking {
                        ProgressView("Saving…")
                    }
                } footer: {
                    Text("The original stays where it is. Private Safe stores a separate encrypted copy in this device's app storage. The device-only key has no recovery code or cloud backup; removing the device passcode removes access to the key.")
                }
            }
            .navigationTitle("Private Safe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelAndDismiss() }
                }
            }
            .accessibilityIdentifier("private-safe-copy-sheet")
            .overlay {
                if session.isPrivacyCovered {
                    PrivateSafePrivacyCover()
                }
            }
        }
        .alert("Private Safe", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            let copy = copyTask
            let unlock = unlockTask
            copyTask = nil
            unlockTask = nil
            copy?.cancel()
            unlock?.cancel()
            Task {
                _ = await copy?.value
                _ = await unlock?.value
            }
        }
    }

    private func saveCopy() {
        guard session.isUnlocked, !isWorking else { return }
        isWorking = true
        let recordID = record.id
        let displayName = record.displayName
        copyTask = Task {
            defer { isWorking = false }
            do {
                _ = try await DocumentSourceAccess.withSource(
                    record: record,
                    store: store,
                    grantService: library.grantService
                ) { sourceURL in
                    try await session.addCopy(
                        from: sourceURL,
                        displayName: displayName,
                        sourceRecordID: recordID
                    )
                }
                try Task.checkCancellation()
                guard session.isUnlocked else { return }
                dismiss()
            } catch {
                guard !Task.isCancelled, session.isUnlocked else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelAndDismiss() {
        let copy = copyTask
        let unlock = unlockTask
        copyTask = nil
        unlockTask = nil
        copy?.cancel()
        unlock?.cancel()
        Task {
            _ = await copy?.value
            _ = await unlock?.value
            dismiss()
        }
    }
}

/// Uses the public activity controller so completion and cancellation both
/// release the temporary plaintext lease. A bare ShareLink has no completion
/// callback for this lifecycle boundary.
private struct PrivateSafeActivityView: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

private struct PrivateSafeExport: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct PrivateSafePreview: Identifiable {
    let url: URL
    var id: URL { url }
}
