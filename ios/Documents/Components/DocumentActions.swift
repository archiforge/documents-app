import SwiftUI

// MARK: - Rename form rules

/// Pure rules of the shared rename dialog (board R3.9): base name only, a
/// 50-character recorded cap, and Confirm requiring a non-blank name. Kept
/// free of UI so the rules are unit-testable.
enum RenameForm {
    static let nameLimit = 50

    static func clamped(_ name: String) -> String {
        String(name.prefix(nameLimit))
    }

    static func canConfirm(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The editable part of a filename — the extension is preserved by
    /// `DocumentStore.rename` and never shown in the field.
    static func baseName(of filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}

// MARK: - Rename dialog

/// The shared rename dialog (board R3.9): 50-character cap with a live
/// counter, clear button, Cancel / Confirm. Confirms with the base name —
/// the extension is not editable and `DocumentStore.rename` re-appends it.
struct RenameSheet: View {
    private let startingName: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    init(record: DocumentRecord, onConfirm: @escaping (String) -> Void) {
        self.startingName = RenameForm.baseName(of: record.displayName)
        self.onConfirm = onConfirm
    }

    /// Drafts such as unfinished scans do not have a DocumentRecord yet, but
    /// use the same validated 50-character rename surface and counter.
    init(initialName: String, onConfirm: @escaping (String) -> Void) {
        self.startingName = RenameForm.clamped(initialName)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Name", text: $name)
                            .focused($focused)
                            .onChange(of: name) { _, newValue in
                                name = RenameForm.clamped(newValue)
                            }
                            .accessibilityLabel("Document name")
                            .accessibilityValue(name.isEmpty ? "Empty" : name)
                        if !name.isEmpty {
                            Button {
                                name = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Clear name")
                            .accessibilityHint("Clears the document name")
                        }
                    }
                } footer: {
                    Text("\(name.count)/\(RenameForm.nameLimit)")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .accessibilityIdentifier("rename-sheet")
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        onConfirm(name)
                        dismiss()
                    }
                    .disabled(!RenameForm.canConfirm(name))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            name = RenameForm.clamped(startingName)
            focused = true
        }
    }
}

// MARK: - Get Info sheet

/// "Get Info" details for one document: identity, size and dates, origin,
/// and where the file lives.
struct DocumentInfoSheet: View {
    let record: DocumentRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: record.kind.symbolName)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                                .font(.headline)
                            Text(record.kind.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Details") {
                    LabeledContent("Size", value: record.sizeBytes, format: .byteCount(style: .file))
                    if record.kind == .pdf, let pageCount = record.pageCount {
                        LabeledContent("Pages", value: "\(pageCount)")
                    }
                    LabeledContent("Created", value: record.importedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last opened", value: record.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
                    if let caption = record.provenance.caption {
                        LabeledContent("Origin", value: caption)
                    }
                }
                Section("Location") {
                    Text(locationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var locationText: String {
        if let absolutePath = record.absolutePath {
            "Indexed from \(absolutePath)"
        } else {
            record.relativePath
        }
    }
}

// MARK: - Context menu

/// The common long-press action menu for document rows, modeled on the iOS
/// Files context menu: Share · Quick Look · Get Info · Rename · Compress ·
/// Duplicate, plus Favorite, PDF Tools (PDF rows), and Delete. Attached to
/// rows in Recent and Favorites so every file type gets the same menu.
private struct DocumentActions: ViewModifier {
    @Environment(DocumentStore.self) private var store

    let record: DocumentRecord
    let onOpen: () -> Void
    var onPDFTools: (() -> Void)?

    @State private var showRename = false
    @State private var showInfo = false
    @State private var showPrivateSafeCopy = false
    @State private var failureText: String?
    @State private var showFailure = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .sheet(isPresented: $showRename) {
                RenameSheet(record: record) { newName in
                    rename(to: newName)
                }
            }
            .sheet(isPresented: $showInfo) {
                DocumentInfoSheet(record: record)
            }
            .sheet(isPresented: $showPrivateSafeCopy) {
                PrivateSafeCopySheet(record: record)
            }
            .alert("Action failed", isPresented: $showFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureText ?? "")
            }
    }

    @ViewBuilder
    private var menu: some View {
        ShareLink(
            item: record.fileURL,
            preview: SharePreview(
                record.displayName,
                image: Image(systemName: record.kind.symbolName)
            )
        )
        Button {
            onOpen()
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        Button {
            showInfo = true
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        Button {
            showRename = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            compress()
        } label: {
            Label("Compress", systemImage: "doc.zipper")
        }
        Button {
            duplicate()
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            showPrivateSafeCopy = true
        } label: {
            Label("Copy to Private Safe", systemImage: "lock.shield")
        }
        Divider()
        Button {
            run { try store.toggleFavorite(record) }
        } label: {
            Label(
                record.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: record.isFavorite ? "star.slash" : "star"
            )
        }
        if let onPDFTools, record.kind == .pdf {
            Button(action: onPDFTools) {
                Label("PDF Tools", systemImage: "wrench.and.screwdriver")
            }
        }
        Divider()
        Button(role: .destructive) {
            run { try store.trash(record) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func rename(to newName: String) {
        run { try store.rename(record, to: newName) }
    }

    private func duplicate() {
        run { try store.duplicate(record) }
    }

    /// Compresses just this file into `<base name>.zip` in the library.
    private func compress() {
        Task { @MainActor in
            let zipName = RenameForm.baseName(of: record.displayName) + ".zip"
            do {
                let data = try ArchiveService.zipData(fromFiles: [record.fileURL])
                _ = try store.saveGeneratedFile(name: zipName, data: data)
            } catch {
                fail(error)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        failureText = error.localizedDescription
        showFailure = true
    }
}

// MARK: - View extension

extension View {
    /// Attaches the shared long-press action menu to a document row.
    /// `onPDFTools` adds the toolbox entry for rows that support it.
    func documentActions(
        record: DocumentRecord,
        onOpen: @escaping () -> Void,
        onPDFTools: (() -> Void)? = nil
    ) -> some View {
        modifier(DocumentActions(record: record, onOpen: onOpen, onPDFTools: onPDFTools))
    }
}
