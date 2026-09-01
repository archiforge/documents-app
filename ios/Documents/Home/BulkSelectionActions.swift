import SwiftUI

/// Selection-mode bulk actions (board R3.8), attached to a tab's list.
/// Adds the bottom bulk bar — Share · More (Favorite/Unfavorite ·
/// Compress) · Delete — and owns the delete confirmation and failure
/// alert.
///
/// Presented as a ViewModifier like `documentActions`: the dialogs must
/// hang off the list, not the toolbar content, or they never present.
/// Actions sit disabled while nothing is selected; Delete soft-trashes
/// through `DocumentStore.trashAll`, and a successful bulk trash ends the
/// selection (the selected rows are gone).
struct BulkSelectionActions: ViewModifier {
    @Environment(DocumentStore.self) private var store

    @Binding var selection: BulkSelection
    let selectedRecords: [DocumentRecord]

    @State private var confirmDelete = false
    @State private var failureText: String?
    @State private var showFailure = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if selection.isActive {
                        barButtons
                    }
                }
            }
            .confirmationDialog(
                "Move \(selection.count) document\(selection.count == 1 ? "" : "s") to Recently Deleted?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    run(trashSelection)
                }
            } message: {
                Text("You can restore them from Recently Deleted for 30 days.")
            }
            .alert("Action failed", isPresented: $showFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureText ?? "")
            }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var barButtons: some View {
        HStack(spacing: 12) {
            shareButton
            moreMenu
            deleteButton
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var shareButton: some View {
        // ShareLink can't be disabled, so an empty selection swaps in a
        // disabled placeholder button.
        if selectedRecords.isEmpty {
            Button {} label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
        } else {
            ShareLink(items: selectedRecords.map(\.fileURL)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                run { try store.setFavorite(selectedRecords, to: !allSelectedAreFavorites) }
            } label: {
                Label(
                    allSelectedAreFavorites ? "Unfavorite" : "Favorite",
                    systemImage: allSelectedAreFavorites ? "star.slash" : "star"
                )
            }
            Button {
                compress()
            } label: {
                Label("Compress", systemImage: "doc.zipper")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .disabled(selectedRecords.isEmpty)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(selectedRecords.isEmpty)
    }

    private var allSelectedAreFavorites: Bool {
        !selectedRecords.isEmpty && selectedRecords.allSatisfy(\.isFavorite)
    }

    // MARK: - Bulk operations

    private func trashSelection() throws {
        let records = selectedRecords
        try store.trashAll(records)
        selection.remove(Set(records.map(\.id)))
        if selection.isEmpty {
            selection.exit()
        }
    }

    /// Zips the selection into one `Archive.zip` in the library;
    /// `FileBridge` dedups the name ("Archive (1).zip") on repeats.
    private func compress() {
        Task { @MainActor in
            do {
                let data = try ArchiveService.zipData(fromFiles: selectedRecords.map(\.fileURL))
                _ = try store.saveGeneratedFile(name: "Archive.zip", data: data)
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
    /// Adds the selection-mode bottom bulk bar and its confirmation/failure
    /// presentations. Attach inside the tab's NavigationStack, to the list.
    func bulkSelectionActions(
        selection: Binding<BulkSelection>,
        selectedRecords: [DocumentRecord]
    ) -> some View {
        modifier(BulkSelectionActions(selection: selection, selectedRecords: selectedRecords))
    }
}
