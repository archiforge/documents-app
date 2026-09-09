import SwiftData
import SwiftUI
import Translation
import UIKit

private struct AIRunSnapshot: Sendable, Equatable {
    let id: UUID
    let translationOptions: AITranslationOptions
}

private struct AIPendingTranslation: Sendable {
    let run: AIRunSnapshot
    let input: AIInput
}

struct AIFlowView: View {
    let kind: AIToolKind
    let service: AIService

    @Environment(DocumentStore.self) private var store
    @Environment(DeviceLibraryService.self) private var library

    @Query(
        filter: #Predicate<DocumentRecord> { !$0.isTrashed },
        sort: \DocumentRecord.lastOpenedAt,
        order: .reverse
    )
    private var records: [DocumentRecord]

    @State private var review: AIReviewArtifact?
    @State private var activeTask: Task<Void, Never>?
    @State private var activeTranslationTask: Task<Void, Never>?
    @State private var activeRunID: UUID?
    @State private var working = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var presentedDocument: PresentedDocument?
    @State private var showDownloadConfirmation = false
    @State private var pendingTranslation: AIPendingTranslation?
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var availabilityRefresh = 0
    @State private var sourceLanguageCode = "en"
    @State private var targetLanguageCode = "es"

    init(kind: AIToolKind, service: AIService = .live) {
        self.kind = kind
        self.service = service
    }

    private var languageChoices: [(String, String)] {
        [
            ("English", "en"),
            ("Arabic", "ar"),
            ("Chinese (Simplified)", "zh-Hans"),
            ("French", "fr"),
            ("German", "de"),
            ("Spanish", "es"),
        ]
    }

    private var supportedRecords: [DocumentRecord] {
        records.filter { AIInputSupport.supports(kind, documentKind: $0.kind) }
    }

    var body: some View {
        Group {
            if let review {
                AIReviewEditor(
                    artifact: Binding(
                        get: { review },
                        set: { self.review = $0 }
                    ),
                    onSave: saveReview,
                    onCancel: { self.review = nil }
                )
            } else {
                sourcePicker
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if working {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Analyzing on this device…")
                    Button("Cancel", role: .cancel, action: cancelWork)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 12)
                .accessibilityElement(children: .contain)
            }
        }
        .alert("Local analysis failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            "Download language assets?",
            isPresented: $showDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Download") { beginTranslationDownload() }
            Button("Cancel", role: .cancel) { cancelWork() }
        } message: {
            Text("The system will download the selected language pair. Document text stays in this app and is processed by the on-device translator.")
        }
        .translationTask(translationConfiguration) { session in
            guard let pending = pendingTranslation else { return }
            let expectedSource = Locale.Language(identifier: pending.run.translationOptions.sourceLanguageCode)
            let expectedTarget = Locale.Language(identifier: pending.run.translationOptions.targetLanguageCode)
            guard session.sourceLanguage == Optional(expectedSource),
                  session.targetLanguage == Optional(expectedTarget) else { return }
            let work = Task { @MainActor in
                await process(
                    input: pending.input,
                    run: pending.run,
                    translationSession: AITranslationSessionBridge(session: session)
                )
            }
            activeTranslationTask = work
            await withTaskCancellationHandler(operation: {
                await work.value
            }, onCancel: {
                work.cancel()
            })
            if isCurrentRun(pending.run.id) {
                activeTranslationTask = nil
            }
        }
        .documentViewer(item: $presentedDocument)
        .onDisappear {
            cancelWork()
        }
    }

    private var sourcePicker: some View {
        List {
            Section {
                Text(kind.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("The original file stays unchanged. Results are editable and require review before saving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let reason = service.availability(for: kind).reason {
                Section {
                    Label(reason.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Check again") {
                        availabilityRefresh &+= 1
                    }
                }
            }

            if kind == .translation {
                Section("Language pair") {
                    Picker("From", selection: $sourceLanguageCode) {
                        ForEach(languageChoices, id: \.1) { name, code in
                            Text(name).tag(code)
                        }
                    }
                    Picker("To", selection: $targetLanguageCode) {
                        ForEach(languageChoices, id: \.1) { name, code in
                            Text(name).tag(code)
                        }
                    }
                }
            }

            Section("Choose a document") {
                if records.isEmpty {
                    Text("No documents in the store yet. Import or scan a document first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        let supported = AIInputSupport.supports(kind, documentKind: record.kind)
                        DocumentRow(record: record) {
                            start(record)
                        }
                        .disabled(working || !supported)
                        .accessibilityValue(supported ? "Available" : "Input format unavailable")
                        .accessibilityHint(
                            supported
                                ? "Runs on this device and opens a review screen"
                                : "This file type is not supported by this tool"
                        )
                    }
                }
            }

            if !supportedRecords.isEmpty {
                Section {
                    Text("Supported inputs: text, Markdown, HTML, PDF, and images.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .id(availabilityRefresh)
    }

    private func start(_ record: DocumentRecord) {
        guard !working else { return }
        cancelWork()
        let sourceID = record.id
        let sourceName = record.displayName
        let sourceKind = record.kind
        let run = AIRunSnapshot(
            id: UUID(),
            translationOptions: AITranslationOptions(
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        )
        // Every asynchronous callback carries this identity. A later source
        // selection or language download cannot publish into this run.
        activeRunID = run.id
        working = true
        errorMessage = ""
        showError = false
        activeTask = Task { @MainActor in
            do {
                let input = try await DocumentSourceAccess.withSource(
                    record: record,
                    store: store,
                    grantService: library.grantService
                ) { url in
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else {
                        throw AIError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    try Task.checkCancellation()
                    return AIInput(
                        id: sourceID,
                        displayName: sourceName,
                        kind: sourceKind,
                        data: data
                    )
                }
                try Task.checkCancellation()
                guard isCurrentRun(run.id) else { return }

                if kind == .translation {
                    let status = await service.translationAvailability(
                        sourceLanguageCode: run.translationOptions.sourceLanguageCode,
                        targetLanguageCode: run.translationOptions.targetLanguageCode
                    )
                    guard isCurrentRun(run.id) else { return }
                    switch status {
                    case .installed:
                        await process(input: input, run: run, translationSession: nil)
                    case .downloadRequired:
                        guard isCurrentRun(run.id) else { return }
                        pendingTranslation = AIPendingTranslation(run: run, input: input)
                        working = false
                        showDownloadConfirmation = true
                    case .unsupported:
                        throw AIError.translationUnavailable
                    }
                } else {
                    await process(input: input, run: run, translationSession: nil)
                }
                if isCurrentRun(run.id) {
                    activeTask = nil
                }
            } catch is CancellationError {
                guard isCurrentRun(run.id) else { return }
                working = false
            } catch {
                guard isCurrentRun(run.id) else { return }
                working = false
                present(error: error, runID: run.id)
            }
        }
    }

    @MainActor
    private func process(
        input: AIInput,
        run: AIRunSnapshot,
        translationSession: AITranslationSessionBridge?
    ) async {
        guard isCurrentRun(run.id) else { return }
        if translationSession != nil {
            working = true
        }
        do {
            let artifact = try await service.run(
                tool: kind,
                input: input,
                translationOptions: run.translationOptions,
                allowLanguageDownload: translationSession != nil,
                translationSession: translationSession
            )
            try Task.checkCancellation()
            guard isCurrentRun(run.id) else { return }
            review = artifact
            working = false
            pendingTranslation = nil
            translationConfiguration = nil
        } catch is CancellationError {
            guard isCurrentRun(run.id) else { return }
            working = false
            pendingTranslation = nil
            translationConfiguration = nil
        } catch {
            guard isCurrentRun(run.id) else { return }
            working = false
            pendingTranslation = nil
            translationConfiguration = nil
            present(error: error, runID: run.id)
        }
    }

    private func beginTranslationDownload() {
        guard let pending = pendingTranslation, isCurrentRun(pending.run.id) else { return }
        translationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: pending.run.translationOptions.sourceLanguageCode),
            target: Locale.Language(identifier: pending.run.translationOptions.targetLanguageCode)
        )
        working = true
    }

    private func cancelWork() {
        activeRunID = nil
        activeTask?.cancel()
        activeTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        translationConfiguration = nil
        pendingTranslation = nil
        showDownloadConfirmation = false
        working = false
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    private func present(error: Error, runID: UUID? = nil) {
        if let runID, !isCurrentRun(runID) { return }
        if let aiError = error as? AIError {
            errorMessage = aiError.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
        showError = true
    }

    private func saveReview() {
        guard let review else { return }
        let payload = AIArtifactExporter.payload(for: review)
        do {
            let record = try store.saveGeneratedFile(
                name: payload.name,
                data: payload.data,
                provenance: .created
            )
            self.review = nil
            presentedDocument = PresentedDocument(record: record)
        } catch {
            present(error: error)
        }
    }
}

private struct AIReviewEditor: View {
    @Binding var artifact: AIReviewArtifact
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var selectedPreviewPageIndex: Int?

    var body: some View {
        Form {
            Section {
                TextField("Output name", text: $artifact.title)
                    .textInputAutocapitalization(.sentences)
                Label(artifact.reviewNotice, systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch artifact.kind {
            case .smartExtraction:
                extractionEditor
            case .chart:
                textEditorSection(title: "Editable table candidate", placeholder: "Detected cells")
            case .formula:
                textEditorSection(title: "Editable OCR / LaTeX candidate", placeholder: "Detected formula")
            case .summary:
                textEditorSection(title: "Summary", placeholder: "Review the generated summary")
            case .translation:
                textEditorSection(title: "Translation", placeholder: "Review the translated text")
            }

            Section("Source evidence") {
                Text(artifact.sourceName)
                    .font(.headline)
                if let selectedPreviewPage {
                    if artifact.previewPages.count > 1 {
                        Picker("Source page", selection: Binding(
                            get: { selectedPreviewPageIndex ?? selectedPreviewPage.pageIndex },
                            set: { selectedPreviewPageIndex = $0 }
                        )) {
                            ForEach(artifact.previewPages) { page in
                                Text("Page \(page.pageIndex + 1)").tag(page.pageIndex)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if let image = UIImage(data: selectedPreviewPage.data) {
                        sourcePreview(image: image, pageIndex: selectedPreviewPage.pageIndex)
                        if artifact.kind == .chart || artifact.kind == .formula || artifact.kind == .smartExtraction {
                            Text("Detected source regions are highlighted for review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !artifact.sourceRegions.isEmpty {
                    Text("A bounded preview is unavailable for the detected source page. Review the page evidence below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let confidence = artifact.confidence {
                    Text("Local confidence: \(confidence, format: .percent.precision(.fractionLength(0)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if artifact.sourceRegions.isEmpty {
                    Text("No page regions were returned by the local reader.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(artifact.sourceRegions.prefix(12)) { region in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(region.pageIndex + 1)")
                                .font(.caption.weight(.semibold))
                            Text(region.transcript)
                                .font(.caption)
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard", role: .cancel, action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .accessibilityIdentifier("Save AI Result")
            }
        }
        .accessibilityIdentifier("AI Review")
    }

    private var extractionEditor: some View {
        Section("Review fields") {
            if artifact.fields.isEmpty {
                Text("No fields were recognized.")
                    .foregroundStyle(.secondary)
            }
            ForEach($artifact.fields) { $field in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Label", text: $field.label)
                    TextField("Value", text: $field.value, axis: .vertical)
                    if let confidence = field.confidence {
                        Text("Page \((field.sourceRegion?.pageIndex ?? 0) + 1) · \(confidence, format: .percent.precision(.fractionLength(0)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func textEditorSection(title: String, placeholder: String) -> some View {
        Section(title) {
            if artifact.body.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $artifact.body)
                .frame(minHeight: 220)
                .font(.body.monospaced())
        }
    }

    private var selectedPreviewPage: AIPreviewPage? {
        guard !artifact.previewPages.isEmpty else { return nil }
        if let selectedPreviewPageIndex,
           let selected = artifact.previewPages.first(where: { $0.pageIndex == selectedPreviewPageIndex }) {
            return selected
        }
        if let evidencePage = artifact.preferredEvidencePageIndex,
           let matching = artifact.previewPages.first(where: { $0.pageIndex == evidencePage }) {
            return matching
        }
        if artifact.preferredEvidencePageIndex != nil {
            // Never fall back to page 0 when the candidate points at a later
            // page whose bounded render was evicted by the preview cap.
            return nil
        }
        // Summary/translation artifacts have no Vision page regions, so their
        // first bounded source page is the correct default evidence.
        return artifact.previewPages.first
    }

    private func sourcePreview(image: UIImage, pageIndex: Int) -> some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(imageSize: image.size, in: proxy.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                ForEach(Array(artifact.sourceRegions.filter { $0.pageIndex == pageIndex }.prefix(32))) { region in
                    let x = bounded(region.x)
                    let y = bounded(region.y)
                    let width = bounded(region.width)
                    let height = bounded(region.height)
                    let rect = CGRect(
                        x: imageRect.minX + CGFloat(x) * imageRect.width,
                        y: imageRect.minY + CGFloat(1 - y - height) * imageRect.height,
                        width: CGFloat(width) * imageRect.width,
                        height: CGFloat(height) * imageRect.height
                    )
                    Rectangle()
                        .stroke(.red, lineWidth: 2)
                        .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(height: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source page preview with detected regions")
    }

    private func fittedImageRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func bounded(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
