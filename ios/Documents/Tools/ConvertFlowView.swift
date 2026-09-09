import SwiftData
import SwiftUI

/// Source picker + conversion runner. `fixedTarget` is set for the
/// To PDF/Word/Excel/PPT grid items; nil means "Format Convert" and adds a
/// target-selection step.
struct ConvertFlowView: View {
    let fixedTarget: ConversionTarget?
    var onClose: (() -> Void)?

    @Environment(DocumentStore.self) private var store
    @Environment(DeviceLibraryService.self) private var library

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
    @State private var conversionTask: Task<Void, Never>?

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
                    let sourceExtension = (record.displayName as NSString).pathExtension.lowercased()
                    let availability = fixedTarget.map {
                        $0.availability(for: record.kind, sourceExtension: sourceExtension)
                    }
                    DocumentRow(record: record) {
                        tapped(record)
                    }
                    .disabled(working || availability?.isAvailable == false)
                    .accessibilityValue(
                        availability?.isAvailable == false ? "Unavailable" : ""
                    )
                    .accessibilityHint(
                        availability?.message(sourceKind: record.kind, target: fixedTarget ?? .pdf)
                            ?? ""
                    )
                }
            }
        }
        .navigationTitle(fixedTarget.map { "To \($0.label)" } ?? "Format Convert")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onClose != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
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
            ConversionTargetSheet(
                sourceKind: source.kind,
                sourceExtension: (source.displayName as NSString).pathExtension.lowercased()
            ) { target in
                targetForSource = nil
                convert(source, to: target)
            }
        }
        .alert("Conversion failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .documentViewer(item: $presentedDocument)
        .onDisappear {
            conversionTask?.cancel()
            conversionTask = nil
        }
    }

    private var scopeDescription: String {
        if fixedTarget == .pdf || fixedTarget == nil {
            "Text, Markdown, HTML, and images convert to PDF on this device. Office files use the configured conversion service."
        } else {
            "Producing \(fixedTarget?.label ?? "") files uses the configured conversion service."
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
        let sourceExtension = (record.displayName as NSString).pathExtension.lowercased()
        let availability = target.availability(for: record.kind, sourceExtension: sourceExtension)
        guard availability.isAvailable else {
            errorMessage = availability.message(sourceKind: record.kind, target: target)
                ?? "The requested conversion is unavailable."
            showError = true
            return
        }
        working = true
        conversionTask?.cancel()
        conversionTask = Task { @MainActor in
            defer { working = false }
            do {
                let saved = try await ConversionCoordinator.convert(
                    record,
                    to: target,
                    store: store,
                    grantService: library.grantService
                )
                try Task.checkCancellation()
                presentedDocument = PresentedDocument(record: saved)
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func close() {
        conversionTask?.cancel()
        conversionTask = nil
        onClose?()
    }
}

/// Target selection for the free-form "Format Convert" entry.
struct ConversionTargetSheet: View {
    let sourceKind: DocumentKind
    let sourceExtension: String
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ConversionTarget) -> Void

    var body: some View {
        NavigationStack {
            List(ConversionTarget.allCases, id: \.self) { target in
                let availability = target.availability(for: sourceKind, sourceExtension: sourceExtension)
                Button {
                    onSelect(target)
                } label: {
                    Label("To \(target.label)", systemImage: target.symbolName)
                }
                .disabled(!availability.isAvailable)
                .accessibilityValue(availability.isAvailable ? "Available" : "Unavailable")
                .accessibilityHint(
                    availability.message(sourceKind: sourceKind, target: target)
                        ?? "Available on this device"
                )
            }
            .navigationTitle("Convert To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
