import PhotosUI
import SwiftUI
import os

/// Recognized-text result shown after ID-card and test-paper scans.
struct OCRResult: Identifiable {
    let id = UUID()
    let text: String
    let savedName: String?
    let document: PresentedDocument?
}

/// Drives one scanner session:
///
/// 1. the Tools tab opens the camera directly; this flow then takes over
///    with the captured pages (seeded via `initialPages`), or opens the
///    camera itself for later re-entry (retake, scan more, ID-card back),
/// 2. a save chooser offers Save as PDF / Save as Image (test papers and
///    ID-card scans add Save as Text); the choice stores the scan and shows
///    the saved screen,
/// 3. cancelling the chooser keeps the captured pages in the preview
///    (retake / scan-more / continue → confirm screen with
///    preview · share · delete · rename · more),
/// 4. "more" offers Save as PDF / Save as Image / Save as Long Image
///    (plus Save as Text and ID-card recognition where applicable),
/// 5. a success screen confirms what was saved.
///
/// VisionKit hands the scan to the delegate and expects the app to dismiss
/// the camera in every callback (VisionKit header contract), so the
/// callbacks set `showScanner = false` and the cover's `onDismiss` is the
/// single safe place to present the chooser, reopen the camera, or end the
/// flow — presenting or dismissing at any other moment races the cover
/// teardown and strands the flow on the black camera backdrop.
struct ScannerFlowView: View {
    let mode: ScanMode
    /// Pages captured by the Tools tab's direct camera pass. When present
    /// the flow starts at the preview stage (or reopens the camera for an
    /// ID-card back side) instead of presenting its own camera first.
    var initialPages: [UIImage] = []
    var initialFrontPages: [UIImage] = []

    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var session = ScanSession()
    @State private var showScanner = false
    @State private var pages: [ScanPageBuffer] = []
    @State private var frontPages: [ScanPageBuffer] = []
    @State private var stage = Stage.camera
    @State private var savedDocuments: [PresentedDocument] = []
    @State private var busy = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var ocrResult: OCRResult?
    @State private var showMoreSheet = false
    @State private var renameRequest: RenameRequest?
    @State private var renamedBase: String?
    @State private var previewFile: PreviewFile?
    @State private var lastPreviewURL: URL?
    @State private var artifacts = TempArtifactTracker()
    /// Set when a capture delivered pages; consumed on scanner close.
    @State private var pendingSaveChoice = false
    /// Explicitly records the current camera pass before VisionKit dismisses
    /// its controller. This prevents an error or dropped callback from being
    /// mistaken for a successful ID-card front capture.
    @State private var cameraOutcome: ScanCameraOutcome?
    @State private var showNoPages = false
    @State private var showSaveChooser = false
    @State private var draftStore = ScanDraftStore.shared
    @State private var draftID = UUID()
    @State private var draftCreatedAt = Date()
    @State private var draftRevision = 0
    @State private var isFinalizingDraft = false
    @State private var activeTask: Task<Void, Never>?
    @State private var draftWriteTasks: [Task<Void, Never>] = []
    @State private var showEditor = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var recoverySnapshot: ScanDraftSnapshot?
    @State private var showDraftRecovery = false
    @State private var draftLoadFailed = false
    @State private var draftGeneration: UUID?
    @State private var didInitialize = false
    @State private var activeMode: ScanMode?

    let onResult: (PresentedDocument) -> Void

    enum Stage: Equatable {
        case camera
        case preview
        case confirm
        case saved([String])
    }

    private var currentMode: ScanMode {
        activeMode ?? mode
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(currentMode.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("scanner-flow-cancel")
                    }
                }
        }
        .fullScreenCover(isPresented: $showScanner, onDismiss: { scannerClosed() }) {
            DocumentScannerView(session: session)
        }
        .confirmationDialog(
            "Save Scan",
            isPresented: $showSaveChooser,
            titleVisibility: .visible
        ) {
            Button("Save as PDF") { saveAsPDF() }
            Button("Save as Image") { saveAsImages() }
            if currentMode == .testPaper || currentMode == .idCard {
                Button("Save as Text") { saveAsText() }
            }
        } message: {
            Text(pages.count == 1 ? "Store the scanned page." : "Store the \(pages.count) scanned pages.")
        }
        .confirmationDialog(
            "Unfinished Scan",
            isPresented: $showDraftRecovery,
            titleVisibility: .visible
        ) {
            if recoverySnapshot != nil {
                Button("Resume Draft") { resumeDraft() }
            }
            Button(recoverySnapshot == nil ? "Discard Draft" : "Start New Scan", role: .destructive) {
                discardDraftAndContinue()
            }
            Button("Leave Draft", role: .cancel) { dismiss() }
        } message: {
            Text(
                draftLoadFailed
                    ? "The unfinished scan could not be restored. It is still on disk; discard it to start a new scan."
                    : "An unfinished scan is available. Resume it or start a new scan."
            )
        }
        .sheet(item: $ocrResult) { result in
            OCRResultSheet(result: result) { document in
                ocrResult = nil
                dismiss()
                onResult(document)
            }
        }
        .sheet(isPresented: $showMoreSheet) {
            moreSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showEditor) {
            ScanEditorView(pages: $pages) {
                persistDraft()
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 20,
            matching: .images
        )
        .fullScreenCover(item: $previewFile, onDismiss: {
            if let url = lastPreviewURL {
                artifacts.remove(url)
                lastPreviewURL = nil
            }
        }) { file in
            DocumentViewerScreen(title: file.url.lastPathComponent, url: file.url)
        }
        .sheet(item: $renameRequest) { request in
            RenameSheet(initialName: request.initialName) { newName in
                renamedBase = newName
                persistDraft()
            }
        }
        .alert("Scan Not Saved", isPresented: $showNoPages) {
            Button("Try Again") { openCamera() }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("The scanner closed without delivering a page, so nothing was stored. Try the scan again.")
        }
        .alert("Scan failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            importPhotos(newItems)
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            session.onPages = { handle(pages: $0) }
            session.onCancel = { handleCancel() }
            session.onError = { error in
                cameraOutcome = .failed
                showScanner = false
                fail(error.localizedDescription)
            }
            initializeFlow()
        }
        .onDisappear {
            // Draft writes intentionally continue after a normal flow
            // disappearance so the latest captured/edit snapshot remains
            // recoverable. Explicit discard and save paths await these tasks
            // before invalidating their generation.
            activeTask?.cancel()
            // Backstop: whatever preview/share artifacts are still tracked
            // go away when the whole flow leaves.
            artifacts.removeAll()
        }
    }

    // MARK: - Stages

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .camera:
            cameraBackdrop
        case .preview:
            previewView
        case .confirm:
            confirmView
        case .saved(let names):
            savedView(names: names)
        }
    }

    /// The scanner cover opens on appear; this is only its backdrop.
    private var cameraBackdrop: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Scan or import a page")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scanner-gallery-import")
            }
        }
    }

    /// Post-capture preview: the latest page large, a thumbnail strip,
    /// a page-count badge, retake / scan-more / continue controls.
    private var previewView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let latest = pages.last {
                ScanPagePreview(page: latest, maxDimension: 1_200)
            }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Import photos")
                    Text("\(pages.count)")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("\(pages.count) pages captured")
                }
                .padding()
                Spacer()
                VStack(spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pages.indices, id: \.self) { index in
                                ScanPagePreview(page: pages[index], maxDimension: 240)
                                    .frame(width: 52, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal)
                    }
                    HStack(spacing: 48) {
                        // Retake: drop everything and go back to the camera.
                        Button {
                            pages = []
                            frontPages = []
                            discardDraftKeepingFlow()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                        }
                        .accessibilityLabel("Retake")
                        // Scan more: keep the pages, reopen the camera.
                        Button {
                            openCamera()
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2)
                        }
                        .accessibilityLabel("Scan another page")
                        // Continue to the confirm screen.
                        Button {
                            stage = .confirm
                            persistDraft()
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.title2.weight(.semibold))
                        }
                        .accessibilityLabel("Continue")
                    }
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// Confirm screen: page thumbnails with per-page delete, plus the
    /// Android-style bottom bar (preview · share · delete · rename · more).
    private var confirmView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageThumb(index)
                    }
                }
                .padding()
            }
            bottomBar
        }
        .background(Color(.systemGroupedBackground))
    }

    private func pageThumb(_ index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            ScanPagePreview(page: pages[index], maxDimension: 320)
            Button {
                removePage(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(4)
        }
        .frame(width: 100, height: 136)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Page \(index + 1)")
    }

    private var bottomBar: some View {
        HStack {
            ToolBarButton(label: "Add", systemImage: "plus") { openCamera() }
            ToolBarButton(label: "Edit", systemImage: "slider.horizontal.3") { showEditor = true }
            ToolBarButton(label: "Preview", systemImage: "doc.richtext") { previewPDF() }
            ToolBarButton(label: "Share", systemImage: "square.and.arrow.up") { sharePDF() }
            ToolBarButton(label: "Rename", systemImage: "pencil") {
                renameRequest = RenameRequest(initialName: renamedBase ?? defaultBaseName)
            }
            ToolBarButton(label: "More", systemImage: "ellipsis") { showMoreSheet = true }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var moreSheet: some View {
        NavigationStack {
            List {
                Button {
                    showMoreSheet = false
                    saveAsPDF()
                } label: {
                    Label("Save as PDF", systemImage: "doc.richtext")
                }
                Button {
                    showMoreSheet = false
                    saveAsImages()
                } label: {
                    Label("Save as Image", systemImage: "photo")
                }
                Button {
                    showMoreSheet = false
                    saveAsLongImage()
                } label: {
                    Label("Save as Long Image", systemImage: "rectangle.portrait.bottomthird.inset.filled")
                }
                if currentMode == .testPaper || currentMode == .idCard {
                    Button {
                        showMoreSheet = false
                        saveAsText()
                    } label: {
                        Label("Save as Text", systemImage: "doc.plaintext")
                    }
                }
                if currentMode == .idCard {
                    Button {
                        showMoreSheet = false
                        recognizeIDCardText()
                    } label: {
                        Label("Recognize Text", systemImage: "text.viewfinder")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    showMoreSheet = false
                    discardScan()
                } label: {
                    Label("Discard Scan", systemImage: "trash")
                }
            }
            .navigationTitle("Save Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoreSheet = false }
                }
            }
        }
    }

    private struct RenameRequest: Identifiable {
        let id = UUID()
        let initialName: String
    }

    private func savedView(names: [String]) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Label("Saved to Documents", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
            Text("Saved")
                .font(.title2.bold())
            VStack(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                dismiss()
                if let first = savedDocuments.first {
                    onResult(first)
                }
            } label: {
                Label("Open", systemImage: "doc")
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
                .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Flow

    private func initializeFlow() {
        activeMode = mode
        pages = makePageBuffers(from: initialPages)
        frontPages = makePageBuffers(from: initialFrontPages)
        let task = Task { @MainActor in
            do {
                let generation = await draftStore.currentGeneration()
                try Task.checkCancellation()
                draftGeneration = generation
                if let snapshot = try await draftStore.load() {
                    try Task.checkCancellation()
                    recoverySnapshot = snapshot
                    draftID = snapshot.draft.id
                    draftCreatedAt = snapshot.draft.createdAt
                    showDraftRecovery = true
                    return
                }
            } catch {
                if error is CancellationError { return }
                // Keep the draft on disk and let the user decide whether to
                // discard it. A malformed draft must never silently vanish.
                fail(error.localizedDescription)
                draftLoadFailed = true
                showDraftRecovery = true
                return
            }
            continueWithIncomingPages()
        }
        activeTask = task
    }

    private func continueWithIncomingPages() {
        if !pages.isEmpty {
            stage = .preview
            pendingSaveChoice = true
            persistDraft()
            scanTrace("seeded with \(pages.count) captured page(s); offering save choice")
            showSaveChooser = true
        } else if !frontPages.isEmpty {
            // ID card: the front was captured by the Tools tab's direct pass;
            // reopen the camera for the back.
            persistDraft()
            openCamera()
        } else {
            openCamera()
        }
    }

    private func makePageBuffers(from images: [UIImage]) -> [ScanPageBuffer] {
        images.compactMap { image in
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                return nil
            }
            return ScanPageBuffer(data: data)
        }
    }

    private func makeDraft() -> (draft: ScanDraft, data: [UUID: Data])? {
        let allPages = pages + frontPages
        guard !allPages.isEmpty else { return nil }
        let pageManifests = pages.map { ScanDraftPage(id: $0.id, fileName: "page-\($0.id.uuidString).jpg", edit: $0.edit) }
        let frontManifests = frontPages.map { ScanDraftPage(id: $0.id, fileName: "page-\($0.id.uuidString).jpg", edit: $0.edit) }
        let now = Date()
        let draft = ScanDraft(
            id: draftID,
            mode: currentMode,
            pages: pageManifests,
            frontPages: frontManifests,
            renamedBase: renamedBase,
            revision: draftRevision,
            createdAt: draftCreatedAt,
            updatedAt: now
        )
        var data: [UUID: Data] = [:]
        for page in allPages {
            data[page.id] = page.data
        }
        return (draft, data)
    }

    /// Captures a complete Sendable snapshot before handing disk work to the
    /// persistence actor. A failed write leaves both the in-memory pages and
    /// the previous on-disk manifest intact.
    private func persistDraft() {
        guard !isFinalizingDraft else { return }
        guard let current = makeDraft() else {
            // Removing the final page is an explicit user discard of the
            // unfinished bundle; clean it up only after that action.
            isFinalizingDraft = true
            let task = Task { @MainActor in
                do {
                    await awaitDraftWrites()
                    try Task.checkCancellation()
                    try await draftStore.discard()
                    await resetDraftSession(resetMode: true)
                    isFinalizingDraft = false
                    openCamera()
                } catch is CancellationError {
                    isFinalizingDraft = false
                    return
                } catch {
                    isFinalizingDraft = false
                    fail(error.localizedDescription)
                }
            }
            activeTask = task
            return
        }
        guard let generation = draftGeneration else {
            let task = Task { @MainActor in
                do {
                    let generation = await draftStore.currentGeneration()
                    try Task.checkCancellation()
                    draftGeneration = generation
                    persistDraft()
                } catch is CancellationError {
                    return
                } catch {
                    fail(error.localizedDescription)
                }
            }
            activeTask = task
            return
        }
        draftRevision += 1
        var nextDraft = current.draft
        nextDraft.revision = draftRevision
        let draft = nextDraft
        let data = current.data
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await draftStore.save(draft, pageData: data, generation: generation)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
        draftWriteTasks.append(task)
    }

    private func resumeDraft() {
        guard let snapshot = recoverySnapshot else {
            return
        }
        let restoredPages = snapshot.pages
        let restoredFrontPages = snapshot.frontPages
        activeMode = ScanEntryRouting.modeForResume(
            requested: mode,
            draftMode: snapshot.draft.mode
        )
        draftID = snapshot.draft.id
        pages = restoredPages + pages
        frontPages = restoredFrontPages + frontPages
        renamedBase = snapshot.draft.renamedBase
        draftRevision = snapshot.draft.revision
        recoverySnapshot = nil
        draftLoadFailed = false
        stage = pages.isEmpty ? .camera : .preview
        persistDraft()
        if pages.isEmpty {
            openCamera()
        }
    }

    private func discardDraftAndContinue() {
        activeTask?.cancel()
        isFinalizingDraft = true
        let task = Task { @MainActor in
            do {
                await awaitDraftWrites()
                try Task.checkCancellation()
                try await draftStore.discard()
                await resetDraftSession(resetMode: true)
                recoverySnapshot = nil
                draftLoadFailed = false
                isFinalizingDraft = false
                continueWithIncomingPages()
            } catch is CancellationError {
                isFinalizingDraft = false
                return
            } catch {
                isFinalizingDraft = false
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    private func discardDraftKeepingFlow() {
        activeTask?.cancel()
        isFinalizingDraft = true
        let task = Task { @MainActor in
            do {
                await awaitDraftWrites()
                try Task.checkCancellation()
                try await draftStore.discard()
                await resetDraftSession(resetMode: true)
                isFinalizingDraft = false
                openCamera()
            } catch is CancellationError {
                isFinalizingDraft = false
                return
            } catch {
                isFinalizingDraft = false
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !isFinalizingDraft else { return }
        activeTask?.cancel()
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var imported: [ScanPageBuffer] = []
            var failedCount = 0
            for item in selection {
                do {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failedCount += 1
                        continue
                    }
                    let validImage = try await runCancellableDetached(priority: .utility) {
                        UIImage(data: data) != nil
                    }
                    guard validImage else {
                        failedCount += 1
                        continue
                    }
                    try Task.checkCancellation()
                    imported.append(ScanPageBuffer(data: data))
                } catch is CancellationError {
                    return
                } catch {
                    failedCount += 1
                }
            }
            guard !Task.isCancelled else { return }
            if !frontPages.isEmpty {
                pages = frontPages + imported
                frontPages = []
            } else {
                pages.append(contentsOf: imported)
            }
            photoItems = []
            if !pages.isEmpty {
                stage = .preview
                persistDraft()
            }
            if failedCount > 0 {
                fail("\(failedCount) selected photo\(failedCount == 1 ? " was" : "s were") unavailable. The imported pages were kept.")
            }
        }
        activeTask = task
    }

    private func openCamera() {
        guard !isFinalizingDraft else { return }
        stage = .camera
        cameraOutcome = nil
        pendingSaveChoice = false
        guard ScanningService.isCameraAvailable else {
            return
        }
        scanTrace("presenting scanner")
        showScanner = true
    }

    private var defaultBaseName: String {
        ScanningService.baseName(for: currentMode, renamed: renamedBase)
    }

    private func fileName(for fileExtension: String) -> String {
        ScanningService.fileName(base: defaultBaseName, fileExtension: fileExtension)
    }

    @MainActor
    private func handle(pages scanned: [UIImage]) {
        // VisionKit hands the scan to the delegate and expects the app to
        // dismiss the camera (see the VisionKit header contract). The cover
        // close then reaches `scannerClosed`, the only safe point for the
        // chooser / camera reopen / retry handoff.
        showScanner = false
        guard !isFinalizingDraft else { return }
        guard !scanned.isEmpty else {
            cameraOutcome = .emptyDelivery
            scanTrace("didScan delivered no pages; recovering on scanner close")
            return
        }
        let captured = makePageBuffers(from: scanned)
        guard !captured.isEmpty else {
            cameraOutcome = .failed
            fail(ScanSaveError.imageEncodingFailed.localizedDescription)
            return
        }
        cameraOutcome = .pages
        // ID cards capture front, then the back side right away.
        if currentMode == .idCard, frontPages.isEmpty, pages.isEmpty {
            frontPages = captured
            persistDraft()
            scanTrace("id-card front captured; reopening camera for back on scanner close")
            return
        }
        pages += frontPages + captured
        frontPages = []
        stage = .preview
        pendingSaveChoice = true
        persistDraft()
        scanTrace("captured \(pages.count) page(s) total; offering save choice")
    }

    @MainActor
    private func handleCancel() {
        cameraOutcome = .cancelled
        scanTrace("didCancel received")
        showScanner = false
        guard !isFinalizingDraft else { return }
    }

    /// Runs when the scanner cover is fully gone — the only safe point to
    /// present the save chooser, reopen the camera, or end the flow.
    @MainActor
    private func scannerClosed() {
        session.detach()
        guard !isFinalizingDraft else {
            cameraOutcome = nil
            return
        }
        let action = ScanFlowCameraRouting.closeAction(
            outcome: cameraOutcome,
            frontPageCount: frontPages.count,
            pageCount: pages.count
        )
        let outcome = cameraOutcome
        cameraOutcome = nil

        switch action {
        case .openBackCamera:
            scanTrace("scanner closed after front delivery; reopening camera for ID-card back side")
            openCamera()
        case .showPreview:
            if !frontPages.isEmpty {
                // A cancelled, failed, or dropped back pass keeps the front
                // as an editable page and never presents another camera.
                pages = frontPages + pages
                frontPages = []
                persistDraft()
            }
            guard !pages.isEmpty else { return }
            stage = .preview
            if pendingSaveChoice {
                pendingSaveChoice = false
                scanTrace("scanner closed: offering save choice")
                showSaveChooser = true
            }
        case .showNoPages:
            scanTrace("scanner closed without usable pages (outcome: \(String(describing: outcome)))")
            showNoPages = true
        case .dismiss:
            scanTrace("scanner closed after deliberate cancel, ending flow")
            dismiss()
        case .stayForError:
            // `fail` already presents the specific VisionKit error. Keep the
            // camera stage available for the gallery button without showing
            // the generic no-pages retry alert as a second presentation.
            stage = .camera
        }
    }

    private func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        _ = withAnimation { pages.remove(at: index) }
        persistDraft()
    }

    private func discardScan() {
        activeTask?.cancel()
        isFinalizingDraft = true
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            do {
                await awaitDraftWrites()
                try Task.checkCancellation()
                try await draftStore.discard()
                await resetDraftSession()
                pages = []
                frontPages = []
                artifacts.removeAll()
                dismiss()
            } catch is CancellationError {
                isFinalizingDraft = false
                return
            } catch {
                isFinalizingDraft = false
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    /// Assembles the current pages into a PDF written to a tracked temp file
    /// so the Quick Look preview and the share sheet can use it. The tracker
    /// removes the file when the preview/share ends, the flow fails, or the
    /// flow leaves.
    private func makeTempPDF() async throws -> URL {
        let pages = pages
        let name = fileName(for: "pdf")
        let data = try await ScanRenderPipeline.pdfData(from: pages)
        try Task.checkCancellation()
        let url = try artifacts.makeFile(named: name, data: data)
        do {
            try Task.checkCancellation()
            return url
        } catch {
            artifacts.remove(url)
            throw error
        }
    }

    private func previewPDF() {
        guard !busy else { return }
        activeTask?.cancel()
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var url: URL?
            do {
                url = try await makeTempPDF()
                try Task.checkCancellation()
                if let url {
                    lastPreviewURL = url
                    previewFile = PreviewFile(url: url)
                }
            } catch is CancellationError {
                if let url { artifacts.remove(url) }
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    private func sharePDF() {
        guard !busy else { return }
        activeTask?.cancel()
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var url: URL?
            do {
                url = try await makeTempPDF()
                try Task.checkCancellation()
                guard let url else { return }
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    artifacts.remove(url)
                }
                guard let scene = UIApplication.shared.connectedScenes.first(
                    where: { $0.activationState == .foregroundActive }
                ) as? UIWindowScene,
                    let root = scene.keyWindow?.rootViewController else {
                    artifacts.remove(url)
                    fail("The share sheet could not be presented.")
                    return
                }
                var top = root
                while let presented = top.presentedViewController { top = presented }
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = top.view
                    popover.sourceRect = CGRect(
                        x: top.view.bounds.midX,
                        y: top.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }
                top.present(activityVC, animated: true)
            } catch is CancellationError {
                if let url { artifacts.remove(url) }
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    // MARK: - Save paths

    @MainActor
    private func saveAsPDF() {
        guard !busy else { return }
        activeTask?.cancel()
        isFinalizingDraft = true
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var records: [DocumentRecord] = []
            do {
                try Task.checkCancellation()
                let name = fileName(for: "pdf")
                let pages = pages
                let data = try await ScanRenderPipeline.pdfData(from: pages)
                try Task.checkCancellation()
                let record = try store.saveGeneratedFile(name: name, data: data, provenance: .scanned)
                records = [record]
                try Task.checkCancellation()
                scanTrace("saved scan as PDF: \(record.displayName)")
                try await finishSave(records)
            } catch is CancellationError {
                if let rollbackFailure = rollbackGeneratedRecords(records) {
                    fail(rollbackFailure)
                }
                isFinalizingDraft = false
            } catch {
                let rollbackFailure = rollbackGeneratedRecords(records)
                isFinalizingDraft = false
                scanTrace("PDF save failed: \(error.localizedDescription)")
                fail(rollbackFailure.map { "\(error.localizedDescription) \($0)" } ?? error.localizedDescription)
            }
        }
        activeTask = task
    }

    @MainActor
    private func saveAsImages() {
        guard !busy else { return }
        activeTask?.cancel()
        isFinalizingDraft = true
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var records: [DocumentRecord] = []
            do {
                try Task.checkCancellation()
                let base = defaultBaseName
                let pages = pages
                let imageData = try await ScanRenderPipeline.imageData(from: pages)
                try Task.checkCancellation()
                let encoded = imageData.enumerated().map { index, data in
                    let name = pages.count > 1 ? "\(base) Page \(index + 1).png" : "\(base).png"
                    return (name: name, data: data)
                }
                for page in encoded {
                    try Task.checkCancellation()
                    records.append(try store.saveGeneratedFile(name: page.name, data: page.data, provenance: .scanned))
                }
                try Task.checkCancellation()
                scanTrace("saved scan as \(records.count) image(s)")
                try await finishSave(records)
            } catch is CancellationError {
                if let rollbackFailure = rollbackGeneratedRecords(records) {
                    fail(rollbackFailure)
                }
                isFinalizingDraft = false
            } catch {
                let rollbackFailure = rollbackGeneratedRecords(records)
                isFinalizingDraft = false
                scanTrace("image save failed: \(error.localizedDescription)")
                fail(rollbackFailure.map { "\(error.localizedDescription) \($0)" } ?? error.localizedDescription)
            }
        }
        activeTask = task
    }

    @MainActor
    private func saveAsLongImage() {
        guard !busy else { return }
        activeTask?.cancel()
        isFinalizingDraft = true
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var records: [DocumentRecord] = []
            do {
                try Task.checkCancellation()
                let name = fileName(for: "png")
                let pages = pages
                let data = try await ScanRenderPipeline.longImageData(from: pages)
                try Task.checkCancellation()
                let record = try store.saveGeneratedFile(name: name, data: data, provenance: .scanned)
                records = [record]
                try Task.checkCancellation()
                scanTrace("saved scan as long image: \(record.displayName)")
                try await finishSave(records)
            } catch is CancellationError {
                if let rollbackFailure = rollbackGeneratedRecords(records) {
                    fail(rollbackFailure)
                }
                isFinalizingDraft = false
            } catch {
                let rollbackFailure = rollbackGeneratedRecords(records)
                isFinalizingDraft = false
                scanTrace("long image save failed: \(error.localizedDescription)")
                fail(rollbackFailure.map { "\(error.localizedDescription) \($0)" } ?? error.localizedDescription)
            }
        }
        activeTask = task
    }

    @MainActor
    private func saveAsText() {
        guard !busy else { return }
        activeTask?.cancel()
        isFinalizingDraft = true
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            var records: [DocumentRecord] = []
            do {
                try Task.checkCancellation()
                let pages = pages
                let imageData = try await ScanRenderPipeline.imageData(from: pages)
                try Task.checkCancellation()
                let sections = try await runCancellableDetachedAsync(priority: .userInitiated) {
                    var sections: [String] = []
                    for (index, imageBytes) in imageData.enumerated() {
                        try Task.checkCancellation()
                        let pageText = try await TextRecognition.recognizeText(in: imageBytes)
                        try Task.checkCancellation()
                        sections.append("Page \(index + 1)\n\(pageText.isEmpty ? "No text recognized." : pageText)")
                    }
                    return sections
                }
                try Task.checkCancellation()
                let text = sections.joined(separator: "\n\n")
                let record = try store.saveGeneratedFile(
                    name: fileName(for: "txt"),
                    data: Data(text.utf8),
                    provenance: .scanned
                )
                records = [record]
                try Task.checkCancellation()
                scanTrace("saved test paper OCR: \(record.displayName)")
                try await cleanupDraftAfterSuccessfulSave()
                ocrResult = OCRResult(
                    text: text,
                    savedName: record.displayName,
                    document: PresentedDocument(record: record)
                )
            } catch is CancellationError {
                if let rollbackFailure = rollbackGeneratedRecords(records) {
                    fail(rollbackFailure)
                }
                isFinalizingDraft = false
            } catch {
                let rollbackFailure = rollbackGeneratedRecords(records)
                isFinalizingDraft = false
                scanTrace("test paper OCR save failed: \(error.localizedDescription)")
                fail(rollbackFailure.map { "\(error.localizedDescription) \($0)" } ?? error.localizedDescription)
            }
        }
        activeTask = task
    }

    @MainActor
    private func recognizeIDCardText() {
        guard !busy else { return }
        activeTask?.cancel()
        busy = true
        let task = Task { @MainActor in
            defer { busy = false }
            do {
                try Task.checkCancellation()
                let imageData = try await ScanRenderPipeline.imageData(from: pages)
                try Task.checkCancellation()
                let text = try await runCancellableDetachedAsync(priority: .userInitiated) {
                    var sections: [String] = []
                    for (index, bytes) in imageData.enumerated() {
                        try Task.checkCancellation()
                        let recognized = try await TextRecognition.recognizeText(in: bytes)
                        try Task.checkCancellation()
                        sections.append("Side \(index + 1)\n\(recognized.isEmpty ? "No text recognized." : recognized)")
                    }
                    return sections.joined(separator: "\n\n")
                }
                try Task.checkCancellation()
                ocrResult = OCRResult(text: text, savedName: nil, document: nil)
            } catch is CancellationError {
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
        activeTask = task
    }

    @MainActor
    private func finishSave(_ records: [DocumentRecord]) async throws {
        try await cleanupDraftAfterSuccessfulSave()
        // `discard` above invalidates the old generation. Do not throw after
        // that point: the generated document and draft cleanup are committed,
        // even if the caller's task was cancelled while the actor was busy.
        savedDocuments = records.map { PresentedDocument(record: $0) }
        stage = .saved(records.map(\.displayName))
    }

    @MainActor
    private func cleanupDraftAfterSuccessfulSave() async throws {
        await awaitDraftWrites()
        try Task.checkCancellation()
        try await draftStore.discard()
        await resetDraftSession()
    }

    /// Refreshes all session tokens only after the actor has removed the
    /// previous draft successfully. There is deliberately no cancellation
    /// check between `discard()` and this refresh: discard is a committed
    /// generation transition, and allowing cancellation to strand the old
    /// token lets a later edit silently write into a discarded session.
    @MainActor
    private func resetDraftSession(resetMode: Bool = false) async {
        draftGeneration = await draftStore.currentGeneration()
        if resetMode {
            activeMode = mode
        }
        draftID = UUID()
        draftCreatedAt = Date()
        draftRevision = 0
    }

    @MainActor
    private func awaitDraftWrites() async {
        let writes = draftWriteTasks
        draftWriteTasks.removeAll()
        for write in writes {
            await write.value
        }
    }

    @MainActor
    private func rollbackGeneratedRecords(_ records: [DocumentRecord]) -> String? {
        var failures: [String] = []
        for record in records.reversed() {
            do {
                try store.delete(record)
            } catch {
                failures.append("The generated file \(record.displayName) could not be rolled back: \(error.localizedDescription)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func fail(_ message: String) {
        artifacts.removeAll()
        errorMessage = message
        showError = true
    }
}

/// Wraps a temp-file URL so Quick Look can present it via `.fullScreenCover(item:)`.
private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// One labelled icon in the confirm screen's bottom bar.
private struct ToolBarButton: View {
    let label: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .accessibilityLabel(label)
    }
}

enum ScanSaveError: LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? {
        "One of the scanned pages could not be encoded as an image."
    }
}

/// Shows recognized text with a Copy action.
struct OCRResultSheet: View {
    let result: OCRResult
    let onOpen: (PresentedDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let savedName = result.savedName {
                    Label("Saved as \(savedName)", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                Text(result.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Recognized Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let document = result.document {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Open File") {
                            onOpen(document)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = result.text
                        copied = true
                    }
                }
            }
        }
    }
}
