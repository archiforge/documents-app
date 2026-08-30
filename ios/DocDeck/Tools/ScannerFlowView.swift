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
/// 1. the camera opens immediately (no landing page),
/// 2. confirming a capture (the checkmark) hands the pages back and a save
///    chooser offers Save as PDF / Save as Image (test papers add
///    Save as Text); the choice stores the scan and shows the saved screen,
/// 3. cancelling the chooser keeps the captured pages in the preview
///    (retake / scan-more / continue → confirm screen with
///    preview · share · delete · rename · more),
/// 4. "more" offers Save as PDF / Save as Image / Save as Long Image
///    (plus Save as Text for test papers),
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

    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var session = ScanSession()
    @State private var showScanner = false
    @State private var pages: [UIImage] = []
    @State private var frontPages: [UIImage] = []
    @State private var stage = Stage.camera
    @State private var savedDocuments: [PresentedDocument] = []
    @State private var busy = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showCameraUnavailable = false
    @State private var ocrResult: OCRResult?
    @State private var showMoreSheet = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renamedBase: String?
    @State private var previewFile: PreviewFile?
    @State private var lastPreviewURL: URL?
    @State private var artifacts = TempArtifactTracker()
    /// Set when a capture delivered pages; consumed on scanner close.
    @State private var pendingSaveChoice = false
    /// Set by any VisionKit callback; lets the close handler tell a
    /// deliberate cancel from a scanner that vanished without delivering.
    @State private var scanDelivered = false
    @State private var showNoPages = false
    @State private var showSaveChooser = false

    let onResult: (PresentedDocument) -> Void

    enum Stage: Equatable {
        case camera
        case preview
        case confirm
        case saved([String])
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(mode.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
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
            if mode == .testPaper {
                Button("Save as Text") { saveAsText() }
            }
        } message: {
            Text(pages.count == 1 ? "Store the scanned page." : "Store the \(pages.count) scanned pages.")
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
        .fullScreenCover(item: $previewFile, onDismiss: {
            if let url = lastPreviewURL {
                artifacts.remove(url)
                lastPreviewURL = nil
            }
        }) { file in
            DocumentViewerScreen(title: file.url.lastPathComponent, url: file.url)
        }
        .alert("Rename scan", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renamedBase = trimmed.isEmpty ? nil : trimmed
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Camera unavailable", isPresented: $showCameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The document scanner needs a physical camera. Run Documents on an iPhone or iPad to scan.")
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
        .onAppear {
            session.onPages = { handle(pages: $0) }
            session.onCancel = { handleCancel() }
            session.onError = { error in
                showScanner = false
                fail(error.localizedDescription)
            }
            openCamera()
        }
        .onDisappear {
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
        Color.black.ignoresSafeArea()
    }

    /// Post-capture preview: the latest page large, a thumbnail strip,
    /// a page-count badge, retake / scan-more / continue controls.
    private var previewView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let latest = pages.last {
                Image(uiImage: latest)
                    .resizable()
                    .scaledToFit()
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
                                Image(uiImage: pages[index])
                                    .resizable()
                                    .scaledToFill()
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
                            openCamera()
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
        Image(uiImage: pages[index])
            .resizable()
            .scaledToFill()
            .frame(width: 100, height: 136)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button {
                    removePage(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(4)
            }
            .accessibilityLabel("Page \(index + 1)")
    }

    private var bottomBar: some View {
        HStack {
            ToolBarButton(label: "Preview", systemImage: "doc.richtext") { previewPDF() }
            ToolBarButton(label: "Share", systemImage: "square.and.arrow.up") { sharePDF() }
            ToolBarButton(label: "Delete", systemImage: "trash", role: .destructive) { discardScan() }
            ToolBarButton(label: "Rename", systemImage: "pencil") {
                renameText = renamedBase ?? defaultBaseName
                showRename = true
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
                if mode == .testPaper {
                    Button {
                        showMoreSheet = false
                        saveAsText()
                    } label: {
                        Label("Save as Text", systemImage: "doc.plaintext")
                    }
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

    private func savedView(names: [String]) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
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

    private func openCamera() {
        stage = .camera
        scanDelivered = false
        pendingSaveChoice = false
        guard ScanningService.isCameraAvailable else {
            showCameraUnavailable = true
            return
        }
        scanTrace("presenting scanner")
        showScanner = true
    }

    private var defaultBaseName: String {
        ScanningService.baseName(for: mode, renamed: renamedBase)
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
        guard !scanned.isEmpty else {
            scanTrace("didScan delivered no pages; recovering on scanner close")
            return
        }
        scanDelivered = true
        // ID cards capture front, then the back side right away.
        if mode == .idCard, frontPages.isEmpty, pages.isEmpty {
            frontPages = scanned
            scanTrace("id-card front captured; reopening camera for back on scanner close")
            return
        }
        pages += frontPages + scanned
        frontPages = []
        stage = .preview
        pendingSaveChoice = true
        scanTrace("captured \(pages.count) page(s) total; offering save choice")
    }

    @MainActor
    private func handleCancel() {
        scanDelivered = true
        scanTrace("didCancel received")
        showScanner = false
        if !frontPages.isEmpty {
            // Back-side capture skipped: keep the front only.
            pages = frontPages
            frontPages = []
            stage = .preview
        } else if pages.isEmpty {
            // Deliberate cancel with nothing captured: `scannerClosed` ends
            // the flow once the cover is fully gone.
            stage = .camera
        } else {
            stage = .preview
        }
    }

    /// Runs when the scanner cover is fully gone — the only safe point to
    /// present the save chooser, reopen the camera, or end the flow.
    @MainActor
    private func scannerClosed() {
        session.detach()
        if !frontPages.isEmpty {
            scanTrace("scanner closed: reopening camera for ID-card back side")
            openCamera() // ID-card back side still pending.
            return
        }
        if !pages.isEmpty {
            if stage == .camera {
                stage = .preview // recovered from a dropped re-capture
            }
            if pendingSaveChoice {
                pendingSaveChoice = false
                scanTrace("scanner closed: offering save choice")
                showSaveChooser = true
            }
            return
        }
        if scanDelivered {
            // Deliberate cancel with nothing captured.
            scanTrace("scanner closed: deliberate cancel, ending flow")
            dismiss()
        } else {
            // The scanner closed without delivering any callback: offer a
            // retry instead of stranding the flow on the black backdrop.
            scanTrace("scanner closed WITHOUT any callback (pages: \(pages.count), front: \(frontPages.count))")
            showNoPages = true
        }
    }

    private func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        _ = withAnimation { pages.remove(at: index) }
        if pages.isEmpty {
            openCamera()
        }
    }

    private func discardScan() {
        pages = []
        frontPages = []
        artifacts.removeAll()
        dismiss()
    }

    /// Assembles the current pages into a PDF written to a tracked temp file
    /// so the Quick Look preview and the share sheet can use it. The tracker
    /// removes the file when the preview/share ends, the flow fails, or the
    /// flow leaves.
    private func makeTempPDF() async throws -> URL {
        let pages = pages
        let name = fileName(for: "pdf")
        let data = try await Task.detached(priority: .userInitiated) {
            try PDFAssembler.pdfData(from: pages)
        }.value
        return try artifacts.makeFile(named: name, data: data)
    }

    private func previewPDF() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await makeTempPDF()
                lastPreviewURL = url
                previewFile = PreviewFile(url: url)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func sharePDF() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await makeTempPDF()
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    artifacts.remove(url)
                }
                if let scene = UIApplication.shared.connectedScenes.first(
                    where: { $0.activationState == .foregroundActive }
                ) as? UIWindowScene,
                    let root = scene.keyWindow?.rootViewController {
                    var top = root
                    while let presented = top.presentedViewController { top = presented }
                    top.present(activityVC, animated: true)
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Save paths

    @MainActor
    private func saveAsPDF() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let name = fileName(for: "pdf")
                let pages = pages
                let data = try await Task.detached(priority: .userInitiated) {
                    try PDFAssembler.pdfData(from: pages)
                }.value
                let record = try store.saveGeneratedFile(name: name, data: data, provenance: .scanned)
                try store.recordOpen(record)
                scanTrace("saved scan as PDF: \(record.displayName)")
                finishSave([record])
            } catch {
                scanTrace("PDF save failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func saveAsImages() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let base = defaultBaseName
                let pages = pages
                let encoded = try await Task.detached(priority: .userInitiated) { () -> [(name: String, data: Data)] in
                    var encoded: [(name: String, data: Data)] = []
                    for (index, image) in pages.enumerated() {
                        guard let png = image.pngData() else {
                            throw ScanSaveError.imageEncodingFailed
                        }
                        let name = pages.count > 1 ? "\(base) Page \(index + 1).png" : "\(base).png"
                        encoded.append((name: name, data: png))
                    }
                    return encoded
                }.value
                var records: [DocumentRecord] = []
                for page in encoded {
                    records.append(try store.saveGeneratedFile(name: page.name, data: page.data, provenance: .scanned))
                }
                for record in records { try store.recordOpen(record) }
                scanTrace("saved scan as \(records.count) image(s)")
                finishSave(records)
            } catch {
                scanTrace("image save failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func saveAsLongImage() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let name = fileName(for: "png")
                let pages = pages
                let data = try await Task.detached(priority: .userInitiated) {
                    try LongImageAssembler.pngData(from: pages)
                }.value
                let record = try store.saveGeneratedFile(name: name, data: data, provenance: .scanned)
                try store.recordOpen(record)
                scanTrace("saved scan as long image: \(record.displayName)")
                finishSave([record])
            } catch {
                scanTrace("long image save failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func saveAsText() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let pages = pages
                let sections = try await Task.detached(priority: .userInitiated) { () -> [String] in
                    var sections: [String] = []
                    for (index, image) in pages.enumerated() {
                        guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
                            throw ScanSaveError.imageEncodingFailed
                        }
                        let pageText = (try? await TextRecognition.recognizeText(in: jpeg)) ?? ""
                        sections.append("Page \(index + 1)\n\(pageText.isEmpty ? "No text recognized." : pageText)")
                    }
                    return sections
                }.value
                let text = sections.joined(separator: "\n\n")
                let record = try store.saveGeneratedFile(
                    name: fileName(for: "txt"),
                    data: Data(text.utf8),
                    provenance: .scanned
                )
                try store.recordOpen(record)
                scanTrace("saved test paper OCR: \(record.displayName)")
                ocrResult = OCRResult(
                    text: text,
                    savedName: record.displayName,
                    document: PresentedDocument(record: record)
                )
            } catch {
                scanTrace("test paper OCR save failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func finishSave(_ records: [DocumentRecord]) {
        savedDocuments = records.map { PresentedDocument(record: $0) }
        stage = .saved(records.map(\.displayName))
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
