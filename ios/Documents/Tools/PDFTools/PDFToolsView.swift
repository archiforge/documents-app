import SwiftUI

/// Result payload for toolbox flows: an alert message plus (optionally) a
/// document the user can open right away.
struct ToolMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

/// The toolbox operations surfaced on the PDF Tools screen.
enum PDFToolFlow: String, Identifiable, CaseIterable {
    case merge
    case split
    case watermark
    case sign
    case extractImages
    case print
    case encrypt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: "Merge"
        case .split: "Split"
        case .watermark: "Watermark"
        case .sign: "Sign"
        case .extractImages: "Extract Images"
        case .print: "Print"
        case .encrypt: "Protect PDF"
        }
    }

    var subtitle: String {
        switch self {
        case .merge: "Combine several PDFs into one"
        case .split: "Extract a page range or split every N pages"
        case .watermark: "Stamp diagonal text onto every page"
        case .sign: "Draw a signature and stamp it onto a page"
        case .extractImages: "Pull embedded images out of a PDF"
        case .print: "Send a PDF to AirPrint"
        case .encrypt: "Create a password-protected copy"
        }
    }

    var symbolName: String {
        switch self {
        case .merge: "doc.on.doc"
        case .split: "scissors"
        case .watermark: "seal"
        case .sign: "signature"
        case .extractImages: "photo.on.rectangle"
        case .print: "printer"
        case .encrypt: "lock"
        }
    }
}

/// The PDF toolbox screen. Reachable from the Tools grid and from the
/// context menu on PDF rows (which presets `initialSource`).
struct PDFToolsView: View {
    @Environment(DocumentStore.self) private var store

    let initialSource: DocumentRecord?
    var onClose: (() -> Void)?

    @State private var activeFlow: PDFToolFlow?
    @State private var message: ToolMessage?
    @State private var showMessage = false
    @State private var pendingDocument: PresentedDocument?
    @State private var presentedDocument: PresentedDocument?

    var body: some View {
        List {
            Section("Source") {
                if let source = initialSource {
                    Label(source.displayName, systemImage: source.kind.symbolName)
                } else {
                    Text("No PDF selected. Pick one inside each tool below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Tools") {
                ForEach(PDFToolFlow.allCases) { flow in
                    Button {
                        activeFlow = flow
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flow.title)
                                Text(flow.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: flow.symbolName)
                        }
                    }
                }
            }
        }
        .navigationTitle("PDF Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .sheet(item: $activeFlow) { flow in
            NavigationStack {
                flowSheet(for: flow)
            }
        }
        .alert(
            message?.title ?? "Done",
            isPresented: $showMessage,
            presenting: message
        ) { _ in
            if pendingDocument != nil {
                Button("Open") {
                    if let document = pendingDocument {
                        presentedDocument = document
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.body)
        }
        .documentViewer(item: $presentedDocument)
    }

    @ViewBuilder
    private func flowSheet(for flow: PDFToolFlow) -> some View {
        switch flow {
        case .merge:
            MergeFlowView(onDone: finish)
        case .split:
            SplitFlowView(source: initialSource, onDone: finish)
        case .watermark:
            WatermarkFlowView(source: initialSource, onDone: finish)
        case .sign:
            SignFlowView(source: initialSource, onDone: finish)
        case .extractImages:
            ExtractImagesFlowView(source: initialSource, onDone: finish)
        case .print:
            PrintFlowView(source: initialSource, onDone: finish)
        case .encrypt:
            PDFPasswordProtectionFlowView(source: initialSource, onDone: finish)
        }
    }

    private func finish(message: ToolMessage, document: PresentedDocument?) {
        activeFlow = nil
        pendingDocument = document
        self.message = message
        showMessage = true
    }
}

/// Modal wrapper used when the toolbox is presented from a context menu.
struct PDFToolsScreen: View {
    let source: DocumentRecord?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFToolsView(initialSource: source, onClose: { dismiss() })
        }
    }
}
