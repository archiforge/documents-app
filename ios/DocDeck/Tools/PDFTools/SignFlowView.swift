import PencilKit
import SwiftUI

/// Sign flow: pick a PDF + page, draw an ink signature, and stamp it
/// bottom-right on the chosen page of a NEW flattened PDF.
struct SignFlowView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var source: DocumentRecord?
    @State private var pageCount = 0
    @State private var pageNumber = 1
    @State private var ink: UIImage?
    @State private var showSignaturePad = false
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
                        ink = nil
                    }
                    .font(.footnote)
                }
                Section {
                    Button("Draw Signature") {
                        showSignaturePad = true
                    }
                    if let ink {
                        HStack {
                            Image(uiImage: ink)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 64)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                self.ink = nil
                            }
                            .font(.footnote)
                        }
                    }
                } header: {
                    Text("Signature")
                } footer: {
                    Text("The signature is stamped bottom-right at about 30% of the page width and flattened into a new PDF.")
                }
                if pageCount > 1 {
                    Section {
                        Stepper("Stamp on page \(pageNumber) of \(pageCount)", value: $pageNumber, in: 1...pageCount)
                    }
                }
            } else {
                PDFSourcePicker { pdf in
                    adopt(pdf)
                }
            }
        }
        .navigationTitle("Sign")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if source != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(working || ink == nil)
                }
            }
        }
        .sheet(isPresented: $showSignaturePad) {
            SignatureSheet { captured in
                ink = captured
            }
        }
        .alert("Signing failed", isPresented: $errorState.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorState.message)
        }
        .onAppear {
            if let source {
                adopt(source)
            }
        }
    }

    private func adopt(_ pdf: DocumentRecord) {
        source = pdf
        if let data = try? Data(contentsOf: pdf.fileURL),
           let count = try? PDFToolbox.pageCount(of: data) {
            pageCount = count
        } else {
            pageCount = 0
        }
        pageNumber = 1
    }

    private func apply() {
        guard let source, let ink else { return }
        working = true
        defer { working = false }
        do {
            let payload = try Data(contentsOf: source.fileURL)
            let signed = try PDFToolbox.sign(payload, ink: ink, pageIndex: pageNumber - 1)
            let base = (source.displayName as NSString).deletingPathExtension
            let record = try store.saveGeneratedFile(name: "Signed_\(base).pdf", data: signed)
            try store.recordOpen(record)
            dismiss()
            onDone(
                ToolMessage(title: "Sign", body: "Saved as \(record.displayName)."),
                PresentedDocument(record: record)
            )
        } catch {
            errorState.message = error.localizedDescription
            errorState.isPresented = true
        }
    }
}

/// Freehand signature pad backed by PencilKit.
struct SignatureSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var canvasView: PKCanvasView?

    let onCapture: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            SignatureCanvas { canvas in
                canvasView = canvas
            }
            .background(Color(.systemBackground))
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear") {
                        canvasView?.drawing = PKDrawing()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        guard let canvasView else { return }
                        let bounds = canvasView.drawing.bounds.insetBy(dx: -16, dy: -16)
                        let image = canvasView.drawing.image(from: bounds, scale: 3)
                        dismiss()
                        onCapture(image)
                    }
                    .disabled((canvasView?.drawing.strokes.isEmpty ?? true))
                }
            }
        }
    }
}

/// Creates and hands back the PKCanvasView (main-actor safe: the view is
/// built inside `makeUIView`).
struct SignatureCanvas: UIViewRepresentable {
    let onReady: (PKCanvasView) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        onReady(canvas)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
