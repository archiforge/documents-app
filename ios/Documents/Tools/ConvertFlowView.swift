import SwiftData
import SwiftUI

/// Source picker + conversion runner. `fixedTarget` is set for the
/// To PDF/Word/Excel/PPT grid items; nil means "Format Convert" and adds a
/// target-selection step.
struct ConvertFlowView: View {
    let fixedTarget: ConversionTarget?
    var onClose: (() -> Void)?

    @Environment(DocumentStore.self) private var store

    @Query(
        filter: #Predicate<DocumentRecord> { !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var records: [DocumentRecord]

    @State private var targetForSource: DocumentRecord?
    @State private var working = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var presentedDocument: PresentedDocument?

    var body: some View {
        List {
            Section {
                Text(scopeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Documents") {
                if records.isEmpty {
                    Text("No documents in the store yet. Import files first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    DocumentRow(record: record) {
                        tapped(record)
                    }
                    .disabled(working)
                }
            }
        }
        .navigationTitle(fixedTarget.map { "To \($0.label)" } ?? "Format Convert")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .overlay {
            if working {
                ProgressView("Converting…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $targetForSource) { source in
            ConversionTargetSheet { target in
                targetForSource = nil
                convert(source, to: target)
            }
        }
        .alert("Conversion pending", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .documentViewer(item: $presentedDocument)
    }

    private var scopeDescription: String {
        if fixedTarget == .pdf || fixedTarget == nil {
            "Text, Markdown, HTML, and images convert to PDF right on this device. Office formats convert once the server service arrives in Phase 2b."
        } else {
            "Producing \(fixedTarget?.label ?? "") files needs the server conversion service, which arrives in Phase 2b."
        }
    }

    private func tapped(_ record: DocumentRecord) {
        if let target = fixedTarget {
            convert(record, to: target)
        } else {
            targetForSource = record
        }
    }

    private func convert(_ record: DocumentRecord, to target: ConversionTarget) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let saved = try await ConversionCoordinator.convert(record, to: target, store: store)
                try store.recordOpen(saved)
                presentedDocument = PresentedDocument(record: saved)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

/// Target selection for the free-form "Format Convert" entry.
struct ConversionTargetSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ConversionTarget) -> Void

    var body: some View {
        NavigationStack {
            List(ConversionTarget.allCases, id: \.self) { target in
                Button {
                    onSelect(target)
                } label: {
                    Label("To \(target.label)", systemImage: target.symbolName)
                }
            }
            .navigationTitle("Convert To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Modal wrapper for the Tools grid destination when a pushed layout is not
/// available (kept symmetric with PDFToolsScreen).
struct ConvertScreen: View {
    let fixedTarget: ConversionTarget?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConvertFlowView(fixedTarget: fixedTarget, onClose: { dismiss() })
        }
    }
}
