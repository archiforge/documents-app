import SwiftData
import SwiftUI

/// Shared "pick one of the store's PDFs" list, used by flows that need a
/// source when none was preset.
struct PDFSourcePicker: View {
    @Query(
        filter: #Predicate<DocumentRecord> { $0.kindRaw == "pdf" && !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var pdfs: [DocumentRecord]

    let onSelect: (DocumentRecord) -> Void

    var body: some View {
        Section("Pick a PDF") {
            if pdfs.isEmpty {
                Text("No PDFs in the store yet. Import one from the Recent tab first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pdfs) { pdf in
                    Button {
                        onSelect(pdf)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.tint)
                            Text(pdf.displayName)
                                .lineLimit(1)
                            Spacer()
                            Text(pdf.sizeBytes, format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Shared error alert plumbing for flows.
struct FlowErrorState {
    var message = ""
    var isPresented = false
}

// MARK: - Merge

struct MergeFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<DocumentRecord> { $0.kindRaw == "pdf" && !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var pdfs: [DocumentRecord]

    @State private var selected: Set<UUID> = []
    @State private var working = false
    @State private var errorState = FlowErrorState()

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        List {
            Section("Pick at least two PDFs") {
                if pdfs.isEmpty {
                    Text("No PDFs in the store yet. Import one from the Recent tab first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(pdfs) { pdf in
                    Button {
                        toggle(pdf.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(pdf.id) ? Color.accentColor : Color.secondary)
                            Text(pdf.displayName)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Merge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Merge") { merge() }
                    .disabled(selected.count < 2 || working)
            }
        }
        .alert("Merge failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func merge() {
        let picked = pdfs.filter { selected.contains($0.id) }
        working = true
        defer { working = false }
        do {
            let payloads = try picked.map { try Data(contentsOf: $0.fileURL) }
            let merged = try PDFToolbox.merge(payloads)
            let record = try store.saveGeneratedFile(name: "Merged_\(DateStamp.day()).pdf", data: merged)
            try store.recordOpen(record)
            dismiss()
            onDone(ToolMessage(title: "Merged", body: "Saved as \(record.displayName)."), PresentedDocument(record: record))
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}

// MARK: - Split

struct SplitFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case range = "Page Range"
        case everyN = "Every N Pages"

        var id: String { rawValue }
    }

    @State var source: DocumentRecord?
    @State private var mode: Mode = .range
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var chunkSize = 1
    @State private var pageCount = 0
    @State private var working = false
    @State private var errorState = FlowErrorState()

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        Form {
            if let source {
                Section("Source") {
                    Label(source.displayName, systemImage: "doc.richtext")
                    Button("Choose a different PDF") {
                        self.source = nil
                    }
                    .font(.footnote)
                }
                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if mode == .range {
                    Section {
                        Stepper("First page: \(firstPage)", value: $firstPage, in: 1...max(pageCount, 1))
                        Stepper("Last page: \(lastPage)", value: $lastPage, in: firstPage...max(pageCount, 1))
                    } footer: {
                        Text("The document has \(pageCount) page(s).")
                    }
                } else {
                    Section {
                        Stepper("Pages per file: \(chunkSize)", value: $chunkSize, in: 1...max(pageCount, 1))
                    } footer: {
                        let files = pageCount == 0 ? 0 : Int(ceil(Double(pageCount) / Double(max(chunkSize, 1))))
                        Text("Produces \(files) file(s) from \(pageCount) page(s).")
                    }
                }
            } else {
                PDFSourcePicker { pdf in
                    adopt(pdf)
                }
            }
        }
        .navigationTitle("Split")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if source != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") { split() }
                        .disabled(working || pageCount == 0)
                }
            }
        }
        .alert("Split failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
        .onAppear {
            if let source {
                loadPageCount(for: source)
            }
        }
    }

    private func adopt(_ pdf: DocumentRecord) {
        source = pdf
        loadPageCount(for: pdf)
    }

    private func loadPageCount(for pdf: DocumentRecord) {
        guard let data = try? Data(contentsOf: pdf.fileURL),
              let count = try? PDFToolbox.pageCount(of: data)
        else {
            pageCount = 0
            return
        }
        pageCount = count
        firstPage = 1
        lastPage = max(count, 1)
        chunkSize = 1
    }

    private func split() {
        guard let source else { return }
        working = true
        defer { working = false }
        do {
            let payload = try Data(contentsOf: source.fileURL)
            let outputs: [Data]
            switch mode {
            case .range:
                outputs = [try PDFToolbox.extractRange(payload, pages: firstPage...lastPage)]
            case .everyN:
                outputs = try PDFToolbox.splitEvery(payload, chunkSize: chunkSize)
            }
            let day = DateStamp.day()
            var firstRecord: DocumentRecord?
            for (index, output) in outputs.enumerated() {
                let name = outputs.count == 1
                    ? "Split_\(day).pdf"
                    : "Split_\(day)_\(index + 1).pdf"
                let record = try store.saveGeneratedFile(name: name, data: output)
                if firstRecord == nil { firstRecord = record }
            }
            if let firstRecord { try store.recordOpen(firstRecord) }
            dismiss()
            let message = outputs.count == 1
                ? "Saved as \(firstRecord?.displayName ?? "the split file")."
                : "Saved \(outputs.count) files."
            onDone(
                ToolMessage(title: "Split", body: message),
                firstRecord.map { PresentedDocument(record: $0) }
            )
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}

// MARK: - Watermark

struct WatermarkFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var source: DocumentRecord?
    @State private var text = ""
    @State private var working = false
    @State private var errorState = FlowErrorState()

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        Form {
            if let source {
                Section("Source") {
                    Label(source.displayName, systemImage: "doc.richtext")
                    Button("Choose a different PDF") {
                        self.source = nil
                    }
                    .font(.footnote)
                }
                Section {
                    TextField("For example: Confidential", text: $text)
                } header: {
                    Text("Watermark text")
                } footer: {
                    Text("The watermark is stamped diagonally onto every page of a new PDF. The original file is left untouched.")
                }
            } else {
                PDFSourcePicker { source = $0 }
            }
        }
        .navigationTitle("Watermark")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if source != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .alert("Watermark failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
    }

    private func apply() {
        guard let source else { return }
        working = true
        defer { working = false }
        do {
            let payload = try Data(contentsOf: source.fileURL)
            let watermarked = try PDFToolbox.watermark(payload, text: text)
            let base = (source.displayName as NSString).deletingPathExtension
            let record = try store.saveGeneratedFile(name: "Watermarked_\(base).pdf", data: watermarked)
            try store.recordOpen(record)
            dismiss()
            onDone(
                ToolMessage(title: "Watermark", body: "Saved as \(record.displayName)."),
                PresentedDocument(record: record)
            )
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}

// MARK: - Extract images

struct ExtractImagesFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var source: DocumentRecord?
    @State private var working = false
    @State private var errorState = FlowErrorState()

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        Form {
            if let source {
                Section("Source") {
                    Label(source.displayName, systemImage: "doc.richtext")
                    Button("Choose a different PDF") {
                        self.source = nil
                    }
                    .font(.footnote)
                }
                Section {
                    Button("Extract Images") { extract() }
                        .disabled(working)
                } footer: {
                    Text("Embedded JPEG images are copied out as-is. If the PDF carries none, each page is rendered to PNG instead. Images land in a folder visible in Browse.")
                }
            } else {
                PDFSourcePicker { source = $0 }
            }
        }
        .navigationTitle("Extract Images")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .alert("Extraction failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
    }

    private func extract() {
        guard let source else { return }
        working = true
        defer { working = false }
        do {
            let payload = try Data(contentsOf: source.fileURL)
            let base = (source.displayName as NSString).deletingPathExtension
            let folder = "Images_\(base)"

            var jpegs = PDFToolbox.extractJPEGImages(from: payload)
            var usedFallback = false
            var extensionName = "jpg"
            if jpegs.isEmpty {
                jpegs = try PDFToolbox.renderPagesAsPNG(from: payload)
                usedFallback = true
                extensionName = "png"
            }

            for (index, image) in jpegs.enumerated() {
                try store.saveGeneratedFile(name: "\(folder)/\(base) \(index + 1).\(extensionName)", data: image)
            }
            dismiss()
            var body = "Saved \(jpegs.count) image(s) to \(folder)."
            if usedFallback {
                body += " No embedded images were found, so each page was rendered to PNG instead."
            }
            onDone(ToolMessage(title: "Extract Images", body: body), nil)
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}

// MARK: - Print

struct PrintFlowView: View {
    @Environment(\.dismiss) private var dismiss

    @State var source: DocumentRecord?
    @State private var errorState = FlowErrorState()

    let onDone: (ToolMessage, PresentedDocument?) -> Void

    var body: some View {
        Form {
            if let source {
                Section("Source") {
                    Label(source.displayName, systemImage: "doc.richtext")
                    Button("Choose a different PDF") {
                        self.source = nil
                    }
                    .font(.footnote)
                }
                Section {
                    Button("Print") { printNow() }
                } footer: {
                    Text("Opens the system print sheet with this file name as the job name.")
                }
            } else {
                PDFSourcePicker { source = $0 }
            }
        }
        .navigationTitle("Print")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .alert("Print failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
    }

    private func printNow() {
        guard let source else { return }
        do {
            let payload = try Data(contentsOf: source.fileURL)
            PDFPrinter.print(data: payload, jobName: source.displayName)
            dismiss()
            onDone(ToolMessage(title: "Print", body: "The print sheet is open."), nil)
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}
